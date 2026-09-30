import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../infrastructure/http_client_provider.dart';
import '../infrastructure/tailscale/catalog_secret_store.dart';
import '../infrastructure/tailscale/tailscale_api.dart';

/// 为什么这次读取之后没有保存 OAuth client。
enum PersistRefusal {
  /// 用户没开「持续刷新」。默认就是这样：导入完就丢掉 secret（docs/05）。
  notRequested,

  /// 服务器没有回报 token 范围，无法确认是只读。
  scopeUnverified,

  /// 只读但不止设备（比如 all:read）：比需要的大，不长期保存。
  scopeBroaderThanDevices,
}

class CatalogReadResult {
  const CatalogReadResult(this.listing, {this.refusal});
  final TailscaleDeviceListing listing;

  /// null 表示已保存。
  final PersistRefusal? refusal;
  bool get persisted => refusal == null;
}

/// 目录读取的三个入口（R11）。界面是 presentation/screens/tailscale_catalog_screen.dart（R13）。
///
/// 1. 粘贴短期 token 读一次：token 只在内存里，读完即丢。
/// 2. 用自己的 OAuth client 读：默认读完即丢；用户显式要求持续刷新、且换来的 token
///    经服务器确认只有设备读取时，才把 client 存进独立安全存储。
/// 3. 用已保存的 client 刷新：401 时受控刷新一次；还不行就要求重新授权，**不删**已保存的 client、
///    也不碰已导入的设备和主机——删不删由用户决定。
///
/// 没有定时刷新、没有后台保活：只在用户操作时发请求。
class TailscaleCatalogAccess {
  TailscaleCatalogAccess(this._store, this._clientFor);

  final TailscaleCatalogSecretStore _store;
  final TailscaleCatalogClient Function(TailscaleCredential) _clientFor;

  /// 已保存来源的客户端，复用内存里的 access token，免得每次刷新都重新换。
  final _saved = <String, TailscaleCatalogClient>{};

  Future<TailscaleDeviceListing> readOnceWithToken(
    String token, {
    String tailnet = '-',
  }) async {
    final client = _clientFor(PastedAccessToken(token));
    try {
      return await client.listDevices(tailnet: tailnet);
    } finally {
      client.forgetToken();
    }
  }

  Future<CatalogReadResult> readWithOAuthClient({
    required String catalogId,
    required OAuthClientCredential credential,
    required bool persist,
    String tailnet = '-',
  }) async {
    final client = _clientFor(credential);
    final TailscaleDeviceListing listing;
    try {
      listing = await client.listDevices(tailnet: tailnet);
    } on Object {
      client.forgetToken();
      rethrow;
    }
    final refusal = !persist
        ? PersistRefusal.notRequested
        : switch (listing.scopeStatus) {
            TokenScopeStatus.deviceReadOnly => null,
            TokenScopeStatus.unverified => PersistRefusal.scopeUnverified,
            TokenScopeStatus.readOnlyBroader =>
              PersistRefusal.scopeBroaderThanDevices,
          };
    if (refusal != null) {
      client.forgetToken();
      return CatalogReadResult(listing, refusal: refusal);
    }
    await _store.saveOAuthClient(catalogId, credential);
    _saved.remove(catalogId)?.forgetToken();
    _saved[catalogId] = client;
    return CatalogReadResult(listing);
  }

  Future<TailscaleDeviceListing> refreshSaved({
    required String catalogId,
    String tailnet = '-',
  }) async {
    var client = _saved[catalogId];
    if (client == null) {
      final credential = await _store.readOAuthClient(catalogId);
      if (credential == null) {
        throw const TailscaleReauthorizationRequired(
          '这个目录来源没有保存的 OAuth client，请重新授权。本地已导入的设备和主机不受影响。',
        );
      }
      client = _saved[catalogId] = _clientFor(credential);
    }
    return client.listDevices(tailnet: tailnet);
  }

  /// 本机有没有保存这个来源的 OAuth client（界面据此决定显示「刷新」还是「重新授权」）。
  Future<bool> hasSaved(String catalogId) async =>
      _saved.containsKey(catalogId) ||
      await _store.readOAuthClient(catalogId) != null;

  /// 删除本机保存的 client。只是删副本：要让它彻底失效，得在 Tailscale 后台撤销。
  Future<void> forgetSaved(String catalogId) async {
    _saved.remove(catalogId)?.forgetToken();
    await _store.forget(catalogId);
  }
}

final tailscaleCatalogAccessProvider = Provider<TailscaleCatalogAccess>((ref) {
  final http = ref.watch(httpClientProvider);
  return TailscaleCatalogAccess(
    const TailscaleCatalogSecretStore(FlutterSecureCatalogBackend()),
    (credential) => TailscaleCatalogClient.official(http, credential),
  );
});
