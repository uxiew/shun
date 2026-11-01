import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../infrastructure/http_client_provider.dart';
import '../infrastructure/tailscale/catalog_secret_store.dart';
import '../infrastructure/tailscale/tailscale_api.dart';

class CatalogReadResult {
  const CatalogReadResult(this.listing, {required this.persisted});
  final TailscaleDeviceListing listing;
  final bool persisted;
}

/// 目录读取的四个入口（R11）。界面是 presentation/screens/tailscale_catalog_screen.dart（R13）。
///
/// 1. 访问令牌读一次：只在内存里，读完即丢。
/// 2. 访问令牌读成功后存下来（[readWithToken]）。读失败不存：不留一个读不了的 key。
/// 3. 用自己的 OAuth client 读，[readWithOAuthClient] 的 persist 决定存不存，同样读成功才存。
/// 4. 用已保存的 key 刷新：OAuth 的 401 时受控刷新一次；还不行就要求重新授权，**不删**已保存的 key、
///    也不碰已导入的设备和主机——删不删由用户决定。
///
/// 这里不排定时器、不做后台保活。前台的自动刷新在 [CatalogOverviewController]（R67）。
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

  Future<TailscaleDeviceListing> readWithToken({
    required String catalogId,
    required String token,
    String tailnet = '-',
  }) async {
    final client = _clientFor(PastedAccessToken(token));
    final TailscaleDeviceListing listing;
    try {
      listing = await client.listDevices(tailnet: tailnet);
    } on Object {
      client.forgetToken();
      rethrow;
    }
    await _store.saveAccessToken(catalogId, token);
    _saved.remove(catalogId)?.forgetToken();
    _saved[catalogId] = client;
    return listing;
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
    if (!persist) {
      client.forgetToken();
      return CatalogReadResult(listing, persisted: false);
    }
    await _store.saveOAuthClient(catalogId, credential);
    _saved.remove(catalogId)?.forgetToken();
    _saved[catalogId] = client;
    return CatalogReadResult(listing, persisted: true);
  }

  Future<TailscaleDeviceListing> refreshSaved({
    required String catalogId,
    String tailnet = '-',
  }) async {
    var client = _saved[catalogId];
    if (client == null) {
      final credential = await _savedCredential(catalogId);
      if (credential == null) {
        throw const TailscaleReauthorizationRequired(
          '这个来源没有保存的 key，到 Tailscale 设置里填一个。已导入的设备和主机不受影响。',
        );
      }
      client = _saved[catalogId] = _clientFor(credential);
    }
    return client.listDevices(tailnet: tailnet);
  }

  Future<TailscaleCredential?> _savedCredential(String catalogId) async {
    final client = await _store.readOAuthClient(catalogId);
    if (client != null) return client;
    final token = await _store.readAccessToken(catalogId);
    return token == null ? null : PastedAccessToken(token);
  }

  /// 本机有没有保存这个来源的 key（界面据此决定显示「刷新」还是去设置里填）。
  Future<bool> hasSaved(String catalogId) async =>
      _saved.containsKey(catalogId) ||
      await _savedCredential(catalogId) != null;

  /// 删除本机保存的 key。只是删副本：要让它彻底失效，得在 Tailscale 后台撤销。
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
