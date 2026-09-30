import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';

import '../domain/device_references.dart';
import '../domain/plugins/builtin_plugins.dart';
import '../infrastructure/tailscale/catalog_cache.dart';
import '../infrastructure/tailscale/catalog_cache_repository.dart';
import '../infrastructure/tailscale/tailscale_api.dart';
import 'plugin_registry.dart';
import 'tailscale_catalog_refresh.dart';

/// 关联、恢复来源被拒的原因。给用户看，不含凭据。
class CatalogLinkRefused implements Exception {
  const CatalogLinkRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 主机里引用了、本机却没有的目录来源：来源被移除过，或主机是从别的手机同步、导入来的。
class MissingCatalogSource {
  const MissingCatalogSource(this.catalogId, this.hosts);
  final String catalogId;
  final List<CatalogHost> hosts;
}

/// Tailscale 目录作为内置 DeviceCatalogProvider（X05）。
///
/// 只是把 R11–R13 已有的实现接进插件体系，HTTP、缓存、合并、导入规则一行没改：
/// - 身份是 registry 里的 `builtin.tailscale`：随 App 发布、构造即可用、外部包冒用会被拒。
///   每个操作先向 registry 要 device-catalog 能力，和以后任何目录 provider 走同一个口子。
/// - 碰得到的：自己来源的控制面凭据（按来源 ID 分开存）、目录缓存、主机的 id/名字/地址/目录绑定。
///   碰不到：主机密码、私钥、代理口令、别的来源的凭据（见 [CatalogHosts]）。
/// - 设备关联就是主机上的目录绑定：存在保险库里，重启不丢，跟着保险库导出、同步。
///   这里不另存一份——两处都存，迟早一处说关联着、另一处说没有。
/// - 没有「连接」：目录里有这台设备不代表能连上。它要先成为一台主机，由 SSH 自己走路线、核对指纹、登录。
class TailscaleCatalogProvider {
  TailscaleCatalogProvider({
    required PluginRegistry registry,
    required CatalogRefresher refresher,
    required CatalogCacheRepository repository,
    required CatalogHosts hosts,
  })  : _registry = registry,
        _refresher = refresher,
        _repository = repository,
        _hosts = hosts;

  final PluginRegistry _registry;
  final CatalogRefresher _refresher;
  final CatalogCacheRepository _repository;
  final CatalogHosts _hosts;

  /// 不可用抛 [PluginUnavailable]，在发任何请求、读任何凭据之前。
  void _require() =>
      _registry.require(BuiltinPlugins.tailscale, Capability.deviceCatalog);

  Future<CatalogCache> addSource({
    required String catalogId,
    String tailnet = '-',
    String? label,
  }) async {
    _require();
    return _refresher.addSource(
      catalogId: catalogId,
      tailnet: tailnet,
      label: label,
    );
  }

  Future<CatalogRefreshOutcome> refreshSaved(String catalogId) async {
    _require();
    return _refresher.refreshSaved(catalogId);
  }

  Future<CatalogRefreshOutcome> refreshWithToken(
    String catalogId,
    String token,
  ) async {
    _require();
    return _refresher.refreshWithToken(catalogId, token);
  }

  Future<CatalogRefreshOutcome> refreshWithOAuthClient(
    String catalogId,
    OAuthClientCredential credential, {
    required bool persist,
  }) async {
    _require();
    return _refresher.refreshWithOAuthClient(
      catalogId,
      credential,
      persist: persist,
    );
  }

  Future<bool> hasSavedCredentials(String catalogId) async {
    _require();
    return _refresher.hasSavedCredentials(catalogId);
  }

  Future<void> forgetCredentials(String catalogId) async {
    _require();
    await _refresher.forgetCredentials(catalogId);
  }

  /// 移除来源：删缓存和本机保存的 client。关联它的主机和主机上的绑定都留着（DEV02），
  /// 之后可以用 [restoreSource] 在本机恢复同一个来源。
  Future<void> removeSource(String catalogId) async {
    _require();
    await _refresher.removeSource(catalogId);
  }

  /// 当前的设备关联（SSH 主机 ↔ 目录设备），从保险库里主机上的绑定算出来。
  Future<DeviceLinks> links() async {
    _require();
    return catalogDeviceLinks(await _hosts.list());
  }

  /// 有主机引用、本机却没有缓存的来源。更新版本写的缓存算「有」：它只是当前版本读不了，不能当成没有去恢复。
  Future<List<MissingCatalogSource>> missingSources() async {
    _require();
    final byCatalog = <String, List<CatalogHost>>{};
    for (final host in await _hosts.list()) {
      final id = host.binding?.catalogId;
      if (id == null || !isValidCatalogId(id)) continue;
      byCatalog.putIfAbsent(id, () => []).add(host);
    }
    final missing = <MissingCatalogSource>[];
    for (final MapEntry(key: id, value: hosts) in byCatalog.entries) {
      try {
        if (await _repository.load(id) != null) continue;
      } on CatalogCacheTooNew {
        continue;
      }
      missing.add(MissingCatalogSource(id, hosts));
    }
    missing.sort((a, b) => a.catalogId.compareTo(b.catalogId));
    return missing;
  }

  /// 在本机按原来的来源 ID 重建一个空来源，让引用它的主机重新对上目录（DEV02「缺 provider 的配置可保留修复」）。
  ///
  /// 只建空缓存，不发请求、不碰主机：之后用这个 tailnet 的凭据读一次，设备 ID 对得上的主机就恢复
  /// 「在列表里」，地址仍等于上次由目录写入的值的，重新跟随目录。读的是别的 tailnet，设备 ID 对不上，
  /// 主机只显示「缓存里没有这台设备」，什么都不会被改。
  Future<CatalogCache> restoreSource(
    String catalogId, {
    String tailnet = '-',
    String? label,
  }) async {
    _require();
    final referenced = (await _hosts.list())
        .any((host) => host.binding?.catalogId == catalogId);
    if (!referenced) {
      throw const CatalogLinkRefused('没有主机引用这个来源，不需要恢复。新来源请用「添加来源」。');
    }
    return _refresher.addSource(
      catalogId: catalogId,
      tailnet: tailnet,
      label: label,
    );
  }

  /// 用户明确选了一台已有主机，把它和目录里的一台设备关联起来（DEV01：只有用户关联才形成关联）。
  ///
  /// 只写绑定，不写地址：`appliedAddress` 留空，所以刷新永远不会改这台主机的地址；
  /// 用户名、端口、认证、路线、指纹一概不碰，也不连接。
  /// 一台主机只关联一台设备、一台设备只关联一台主机，检查和写入在保险库的同一次串行写里做。
  Future<void> linkHost({
    required String hostId,
    required String catalogId,
    required String deviceId,
  }) async {
    _require();
    final cache = await _repository.load(catalogId);
    final record = cache?.devices[deviceId];
    if (record == null) {
      throw const CatalogLinkRefused('缓存里没有这台设备，先读一次设备列表。');
    }
    if (record.missing) {
      throw const CatalogLinkRefused('最近一次完整列表里没有这台设备，不能关联。');
    }
    final device = catalogDeviceRef(catalogId, deviceId);
    var found = false;
    await _hosts.change(hostId, (current, all) {
      found = true;
      final links = catalogDeviceLinks(all);
      if (current.binding != null) {
        throw const CatalogLinkRefused('这台主机已经关联了目录里的设备，先在主机编辑器里断开。');
      }
      final taken = links.recordOf(device);
      if (taken != null) {
        final other = taken.refs
            .where((r) => r.providerId == BuiltinPlugins.ssh)
            .map((r) => r.displayName)
            .join('、');
        throw CatalogLinkRefused('这台设备已经关联了主机：$other');
      }
      // 规则由 plugin_api 的 DeviceLinks 最终把关（同 provider 不能互相关联、已属于别的记录要先解除）。
      links.linkByUser([
        sshHostRef(current.id,
            displayName: current.label, hostname: current.hostname),
        device,
      ]);
      return CatalogHostChange(
        binding: CatalogBinding(catalogId: catalogId, deviceId: deviceId),
      );
    });
    if (!found) {
      throw const CatalogLinkRefused('这台主机已不在保险库里。');
    }
  }
}

/// 从主机上的目录绑定算出设备关联：每个绑定是一对（SSH 主机，目录设备）。
///
/// 同一台设备被两台主机绑定（从别的手机同步来、或旧数据）时，只有列表里靠前的那台算关联，
/// 另一台的绑定照旧保留、照旧显示在它的编辑器里，由用户决定断开哪台——这里不替用户选、也不删。
DeviceLinks catalogDeviceLinks(List<CatalogHost> hosts) {
  final links = DeviceLinks();
  for (final host in hosts) {
    final binding = host.binding;
    if (binding == null || !isValidCatalogId(binding.catalogId)) continue;
    if (binding.deviceId.isEmpty) continue;
    try {
      links.linkByUser([
        sshHostRef(host.id, displayName: host.label, hostname: host.hostname),
        catalogDeviceRef(binding.catalogId, binding.deviceId),
      ]);
    } on StateError {
      continue;
    }
  }
  return links;
}

final tailscaleCatalogProvider = Provider<TailscaleCatalogProvider>((ref) {
  return TailscaleCatalogProvider(
    registry: ref.read(pluginRegistryProvider.notifier),
    refresher: ref.watch(catalogRefresherProvider),
    repository: ref.watch(catalogCacheRepositoryProvider),
    hosts: ref.watch(catalogHostsProvider),
  );
});
