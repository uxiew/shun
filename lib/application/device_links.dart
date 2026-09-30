import 'package:plugin_api/plugin_api.dart';

import '../domain/device_references.dart';
import 'tailscale_catalog_refresh.dart';
import 'uuremote.dart';

/// 一台设备在各个 provider 里的引用，按用户建立的关联聚在一起（docs/17 §4 的 DeviceRecord）。
///
/// 关联各存各处、不另存一份：SSH 主机 ↔ 目录设备是主机上的目录绑定（保险库，X05）；
/// SSH 主机 ↔ UU 设备是 UU 绑定上记的主机 id（UU 自己的安全存储，X06）。这里只是把它们拼起来看。
/// 每条关联都来自用户操作（导入、关联已有主机、在 UU 里选设备并确认），没有按名字或地址自动合并（DEV01）。
///
/// 同一台主机只算一条 UU 绑定（同一个 provider 的两条引用不能关联）；万一存了多条，只取最早的那条，
/// 其余照旧留在 UU 列表里由用户处理，不在这里删。
DeviceLinks deviceLinksOf({
  required List<CatalogHost> hosts,
  List<UuBinding> uu = const [],
}) {
  final uuByHost = <String, UuBinding>{};
  for (final binding in [...uu]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt))) {
    uuByHost.putIfAbsent(binding.hostId, () => binding);
  }
  final links = DeviceLinks();
  for (final host in hosts) {
    final ssh =
        sshHostRef(host.id, displayName: host.label, hostname: host.hostname);
    final catalog = switch (host.binding) {
      final b? when isValidCatalogId(b.catalogId) && b.deviceId.isNotEmpty =>
        catalogDeviceRef(b.catalogId, b.deviceId),
      _ => null,
    };
    final device = uuByHost[host.id];
    final uuRef = device == null ? null : uuBindingRef(device.id);
    if (catalog != null && links.recordOf(catalog) != null) {
      // 同一台目录设备被两台主机绑定（同步来的旧数据）：目录这条只算靠前的那台，另一台主机的绑定照旧保留（X05）；
      // 这台主机和 UU 的关联不受影响。
      if (uuRef != null) links.linkByUser([ssh, uuRef]);
      continue;
    }
    final refs = [
      ssh,
      if (catalog != null) catalog,
      if (uuRef != null) uuRef,
    ];
    if (refs.length >= 2) links.linkByUser(refs);
  }
  return links;
}
