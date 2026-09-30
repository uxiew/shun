import '../domain/connection_route.dart';
import '../domain/models/host.dart';
import '../domain/models/vault.dart';
import '../infrastructure/tailscale/catalog_cache.dart';
import 'tailscale_catalog_refresh.dart';

/// 从目录批量导入主机（R13）：选中的设备按同一套设置生成新主机，只写保险库，不连接、不开 VPN。
///
/// 规则（docs/05「连接入口」、R13 验收）：
/// - 用户名必须填：目录只知道设备，不知道服务器上的 Unix 用户，不默认 root。
/// - 路线按用户选的走：直连、已保存的代理配置、保险库里的跳板机。目录不创造连通性。
/// - 不写任何指纹信任：导入的主机第一次连接照常核对指纹，设备 ID 不能替 host key 担保（TSC04）。
/// - 已导入过的设备跳过，不重复建、也不改已有主机（包括用户手动建的）。

/// 批量导入时所有选中设备共用的设置。
class CatalogImportOptions {
  const CatalogImportOptions({
    required this.username,
    this.port = 22,
    this.address = CatalogAddressKind.ipv4,
    this.proxyProfileId,
    this.proxyConfig,
    this.jumpHostIds = const [],
    this.authMethod = HostAuthMethod.auto,
    this.identityFileId,
    this.group,
  });

  final String username;
  final int port;
  final CatalogAddressKind address;

  /// 已保存的代理配置。和 [jumpHostIds] 同时给时，代理只用于连第一台跳板机（R07 的「代理入口 + 跳板」）。
  final String? proxyProfileId;

  /// 自定义代理，写进每台新主机（和编辑器里「自定义 HTTP / SOCKS5 代理」同一种存法）。
  /// 手机端目前没有新建代理配置的入口，只有从桌面端导入的才有 [proxyProfileId] 可选。
  final ProxyConfig? proxyConfig;
  final List<String> jumpHostIds;
  final HostAuthMethod authMethod;
  final String? identityFileId;
  final String? group;
}

/// 设置本身不成立（比如没填用户名），一台都不导。
class CatalogImportInvalid implements Exception {
  const CatalogImportInvalid(this.message);
  final String message;
  @override
  String toString() => message;
}

class CatalogImportSkip {
  const CatalogImportSkip(this.deviceId, this.name, this.reason);
  final String deviceId;
  final String name;
  final String reason;
}

class CatalogImportResult {
  const CatalogImportResult(this.hosts, this.skipped);

  /// 要新建的主机，每台都带 [CatalogBinding]（appliedAddress 就是写进去的地址）。
  final List<HostProfile> hosts;
  final List<CatalogImportSkip> skipped;
}

/// 设备显示名：Tailscale 的机器名，没有就取 MagicDNS 名的第一段，再没有就用 ID。
String catalogDeviceName(CatalogDeviceRecord record) {
  final device = record.device;
  final hostname = device.hostname?.trim() ?? '';
  if (hostname.isNotEmpty) return hostname;
  final name = device.name?.trim() ?? '';
  if (name.isNotEmpty) return name.split('.').first;
  return device.id;
}

CatalogImportResult buildCatalogImport({
  required CatalogCache cache,
  required List<String> deviceIds,
  required CatalogImportOptions options,
  required VaultData vault,
  required String Function() newId,
}) {
  final username = options.username.trim();
  if (username.isEmpty) {
    throw const CatalogImportInvalid('要填登录用户名：目录不知道服务器上的 Unix 用户，不会默认用 root。');
  }
  if (RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(username)) {
    throw const CatalogImportInvalid('用户名里不能有空格或控制字符。');
  }
  if (options.port < 1 || options.port > 65535) {
    throw const CatalogImportInvalid('端口要在 1–65535 之间。');
  }
  if (options.authMethod == HostAuthMethod.key &&
      (options.identityFileId ?? '').isEmpty) {
    throw const CatalogImportInvalid('选了私钥认证，要选一把私钥。');
  }
  if ((options.proxyProfileId ?? '').isNotEmpty &&
      options.proxyConfig != null) {
    throw const CatalogImportInvalid('代理只能选一个：已保存的配置或自定义，不能都填。');
  }
  if (options.jumpHostIds.length > maxJumpHosts) {
    throw const CatalogImportInvalid('跳板机最多 $maxJumpHosts 台。');
  }

  final imported = <String, HostProfile>{
    for (final host in vault.hosts)
      if (CatalogBinding.of(host) case final binding?
          when binding.catalogId == cache.catalogId)
        binding.deviceId: host,
  };
  final hosts = <HostProfile>[];
  final skipped = <CatalogImportSkip>[];
  for (final deviceId in deviceIds) {
    final record = cache.devices[deviceId];
    if (record == null) {
      skipped.add(CatalogImportSkip(deviceId, deviceId, '缓存里没有这台设备'));
      continue;
    }
    final name = catalogDeviceName(record);
    final existing = imported[deviceId];
    if (existing != null) {
      skipped.add(CatalogImportSkip(deviceId, name, '已导入为“${existing.label}”'));
      continue;
    }
    if (record.missing) {
      skipped.add(CatalogImportSkip(deviceId, name, '最近一次完整列表里没有它'));
      continue;
    }
    final binding = CatalogBinding(
      catalogId: cache.catalogId,
      deviceId: deviceId,
      address: options.address,
    );
    final address = binding.addressOf(record.device);
    if (address == null || address.isEmpty) {
      skipped.add(CatalogImportSkip(
          deviceId,
          name,
          switch (options.address) {
            CatalogAddressKind.ipv4 => '没有 IPv4 地址',
            CatalogAddressKind.ipv6 => '没有 IPv6 地址',
            CatalogAddressKind.fqdn => '没有 MagicDNS 名称',
          }));
      continue;
    }
    final host = _host(
      newId(),
      name,
      address,
      username,
      options,
      CatalogBinding(
        catalogId: cache.catalogId,
        deviceId: deviceId,
        address: options.address,
        appliedAddress: address,
      ),
    );
    // 和连接时同一个函数检查路线：路线矛盾（找不到跳板、循环、代理配置缺失）整批都不成立，
    // 只和这台设备有关的（地址不合法、和某台跳板是同一台机器）只跳过这台。
    try {
      resolveRoutePlan(
        host,
        hosts: [...vault.hosts, ...hosts],
        proxyProfiles: vault.proxyProfiles,
        keys: vault.keys,
      );
    } on RouteConfigException catch (error) {
      if (_routeLevel(error, options, vault)) {
        throw CatalogImportInvalid(error.message);
      }
      skipped.add(CatalogImportSkip(deviceId, name, error.message));
      continue;
    }
    hosts.add(host);
    imported[deviceId] = host;
  }
  return CatalogImportResult(hosts, skipped);
}

HostProfile _host(
  String id,
  String label,
  String address,
  String username,
  CatalogImportOptions options,
  CatalogBinding binding,
) {
  final data = HostProfile.create(
    id: id,
    label: label,
    hostname: address,
    username: username,
    port: options.port,
  ).data
    ..['authMethod'] = options.authMethod.name
    ..[CatalogBinding.key] = binding.toJson();
  final keyId = options.identityFileId ?? '';
  if (options.authMethod != HostAuthMethod.password && keyId.isNotEmpty) {
    data['identityFileId'] = keyId;
  }
  final group = options.group?.trim() ?? '';
  if (group.isNotEmpty) data['group'] = group;
  if (options.jumpHostIds.isNotEmpty) {
    data['hostChain'] = {
      'hostIds': [...options.jumpHostIds],
    };
  }
  final proxy = options.proxyProfileId ?? '';
  if (proxy.isNotEmpty) data['proxyProfileId'] = proxy;
  final custom = options.proxyConfig;
  if (custom != null) data['proxyConfig'] = custom.toJson();
  return HostProfile(data);
}

/// 这个错误是路线设置本身的问题（每台都会一样），还是只和这台设备的地址有关。
/// 用一个不会出问题的占位地址再算一遍：还报错就是设置的问题。
bool _routeLevel(
  RouteConfigException error,
  CatalogImportOptions options,
  VaultData vault,
) {
  final probe = _host(
    '__probe__',
    'probe',
    '192.0.2.1', // TEST-NET-1：文档专用地址，不会和任何跳板重复
    'probe',
    options,
    const CatalogBinding(catalogId: 'probe', deviceId: 'probe'),
  );
  try {
    resolveRoutePlan(
      probe,
      hosts: vault.hosts,
      proxyProfiles: vault.proxyProfiles,
      keys: vault.keys,
    );
    return false;
  } on RouteConfigException {
    return true;
  }
}
