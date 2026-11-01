import 'package:uuid/uuid.dart';

import '../domain/connection_route.dart';
import '../domain/credential_identity.dart';
import '../domain/models/host.dart';
import '../domain/models/vault.dart';
import '../infrastructure/tailscale/catalog_cache.dart';
import 'tailscale_catalog_refresh.dart';
import 'vault_controller.dart';
import '../domain/vault_secrets.dart';

/// 从目录批量导入主机（R13）：选中的设备按同一套设置生成新主机，只写保险库，不连接、不开 VPN。
///
/// 规则（docs/05「连接入口」、R13 验收）：
/// - 用户名可以空着，但不默认 root：目录只知道设备，不知道服务器上的 Unix 用户。空着的主机第一次连接时问
///   （R26 所有者：不是每台机器都用同一个用户，导入时统一填不合理）。
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
    this.jumpRouteConfirmation,
    this.authMethod = HostAuthMethod.auto,
    this.identityFileId,
    this.identityId,
    this.group,
  });

  final String username;
  final int port;
  final CatalogAddressKind address;

  /// 已保存的代理配置。和 [jumpHostIds] 同时给时，代理只用于连第一台跳板机（R07 的「代理入口 + 跳板」）。
  final String? proxyProfileId;

  /// 自定义代理，写进每台新主机（和编辑器里「自定义 HTTP / SOCKS5 代理」同一种存法）。
  /// 旧内联配置继续支持；共用路线编辑器也可新建并选择 [proxyProfileId]。
  final ProxyConfig? proxyConfig;
  final List<String> jumpHostIds;
  final Object? jumpRouteConfirmation;
  final HostAuthMethod authMethod;
  final String? identityFileId;

  /// 用「凭据」里的哪一个（F31）。选了就不看 [username]、[authMethod]、[identityFileId]。
  final String? identityId;
  final String? group;
}

/// 来源上存的导入默认值（R26）：导入不再弹设置页，直接按它建主机。存在 [CatalogCache.importDefaults]，
/// 只有设置、没有密码：代理只记已保存代理的 ID（口令在安全存储里），跳板只记主机 ID，凭据只记它的 ID。
class CatalogImportDefaults {
  const CatalogImportDefaults({
    this.username = '',
    this.port = 22,
    this.address = CatalogAddressKind.ipv4,
    this.proxyProfileId,
    this.jumpHostIds = const [],
    this.jumpRouteConfirmation,
    this.identityFileId,
    this.identityId,
    this.group = '',
  });

  factory CatalogImportDefaults.of(CatalogCache cache) =>
      CatalogImportDefaults.fromJson(cache.importDefaults);

  /// 读不懂的项按默认值：这只是偏好，不该让整个来源读不出来。
  factory CatalogImportDefaults.fromJson(Map<String, Object?> json) {
    final port = json['port'];
    final jumps = json['jumpHostIds'];
    return CatalogImportDefaults(
      username: json['username'] is String ? json['username'] as String : '',
      port: port is int && port >= 1 && port <= 65535 ? port : 22,
      address: CatalogAddressKind.values
              .where((kind) => kind.name == json['address'])
              .firstOrNull ??
          CatalogAddressKind.ipv4,
      proxyProfileId: json['proxyProfileId'] is String
          ? json['proxyProfileId'] as String
          : null,
      jumpHostIds: jumps is List
          ? [
              for (final id in jumps)
                if (id is String && id.isNotEmpty) id
            ]
          : const [],
      jumpRouteConfirmation: json['jumpRouteConfirmation'],
      identityFileId: json['identityFileId'] is String
          ? json['identityFileId'] as String
          : null,
      identityId:
          json['identityId'] is String ? json['identityId'] as String : null,
      group: json['group'] is String ? json['group'] as String : '',
    );
  }

  final String username;
  final int port;
  final CatalogAddressKind address;
  final String? proxyProfileId;
  final List<String> jumpHostIds;
  final Object? jumpRouteConfirmation;

  /// 用哪把已存的私钥（只记 ID）。认证方式始终是自动：先试私钥，不行再问密码。
  /// 有凭据之前的设置，照常生效；现在选不到新的，只能在设置页清掉（F31）。
  final String? identityFileId;

  /// 所有导入的主机共用的凭据（F31）。
  final String? identityId;
  final String group;

  Map<String, Object?> toJson() => {
        if (username.trim().isNotEmpty) 'username': username.trim(),
        if (port != 22) 'port': port,
        'address': address.name,
        if ((proxyProfileId ?? '').isNotEmpty) 'proxyProfileId': proxyProfileId,
        if (jumpHostIds.isNotEmpty) 'jumpHostIds': jumpHostIds,
        if (jumpRouteConfirmation != null)
          'jumpRouteConfirmation': jumpRouteConfirmation,
        if ((identityFileId ?? '').isNotEmpty) 'identityFileId': identityFileId,
        if ((identityId ?? '').isNotEmpty) 'identityId': identityId,
        if (group.trim().isNotEmpty) 'group': group.trim(),
      };

  CatalogImportOptions options() => CatalogImportOptions(
        username: username,
        port: port,
        address: address,
        proxyProfileId: proxyProfileId,
        jumpHostIds: jumpHostIds,
        jumpRouteConfirmation: jumpRouteConfirmation,
        identityFileId: identityFileId,
        identityId: identityId,
        group: group,
      );
}

/// 设置本身不成立（比如端口不对、路线矛盾），一台都不导。
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

/// 写入前再查一次：同一来源的同一台设备在保险库里已有主机（比如另一个页面刚导入过），就不再建。
bool alreadyImported(VaultData current, HostProfile host) {
  final binding = CatalogBinding.of(host);
  if (binding == null) return false;
  return current.hosts.any((existing) {
    final other = CatalogBinding.of(existing);
    return other != null &&
        other.catalogId == binding.catalogId &&
        other.deviceId == binding.deviceId;
  });
}

CatalogImportResult buildCatalogImport({
  required CatalogCache cache,
  required List<String> deviceIds,
  required CatalogImportOptions options,
  required VaultData vault,
  required String Function() newId,
}) {
  final username = options.username.trim();
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
    // 文案写死 3：插值后运行时的句子对不上英文翻译表。上限改了要一起改。
    throw const CatalogImportInvalid('跳板机最多 3 台。');
  }

  // 凭据删了（默认值还记着它）就当没选，第一次连接时会问，不至于导不进来。
  final identity = vaultIdentities(vault)
      .where((item) => item.id == options.identityId)
      .firstOrNull;
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
      os: record.device.os,
      identity: identity,
    );
    // 和连接时同一个函数检查路线：路线矛盾（找不到跳板、循环、代理配置缺失）整批都不成立，
    // 只和这台设备有关的（地址不合法、和某台跳板是同一台机器）只跳过这台。
    try {
      resolveRoutePlan(
        host,
        hosts: [...vault.hosts, ...hosts],
        proxyProfiles: vault.proxyProfiles,
        keys: vault.keys,
        identities: vaultIdentityMaps(vault),
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

/// 按来源上存的默认值直接导入，不弹设置页（R26）。和设置页一样只写保险库、不连接；
/// 写入前再查一次已导入的（[alreadyImported]）。设置本身不成立时抛 [CatalogImportInvalid]。
Future<({List<HostProfile> added, List<CatalogImportSkip> skipped})>
    importCatalogDevices(
  VaultController controller,
  CatalogCache cache,
  Iterable<String> deviceIds,
) async {
  final vault = await controller.ready();
  const uuid = Uuid();
  final result = buildCatalogImport(
    cache: cache,
    deviceIds: [...deviceIds],
    options: CatalogImportDefaults.of(cache).options(),
    vault: vault,
    newId: uuid.v4,
  );
  final added = result.hosts.isEmpty
      ? const <HostProfile>[]
      : await controller.addHosts(result.hosts, skip: alreadyImported);
  return (added: added, skipped: result.skipped);
}

/// 这个来源里还没导入、导得进来的设备（「全部导入」用）：不含最近完整列表里不见了的。
List<String> importableCatalogDevices(CatalogCache cache, VaultData vault) {
  final imported = {
    for (final host in vault.hosts)
      if (CatalogBinding.of(host) case final binding?
          when binding.catalogId == cache.catalogId)
        binding.deviceId,
  };
  return [
    for (final record in cache.devices.values)
      if (!record.missing && !imported.contains(record.id)) record.id,
  ];
}

HostProfile _host(
  String id,
  String label,
  String address,
  String username,
  CatalogImportOptions options,
  CatalogBinding binding, {
  String? os,
  IdentityProfile? identity,
}) {
  final data = HostProfile.create(
    id: id,
    label: label,
    hostname: address,
    username: username,
    port: options.port,
  ).data
    ..['authMethod'] = options.authMethod.name
    ..[CatalogBinding.key] = binding.toJson();
  // 先按 Tailscale 报的系统显示图标（R26）；连上以后读到 os-release 会换成具体发行版。
  if (os case final os? when os.trim().isNotEmpty) data['os'] = os.trim();
  final keyId = options.identityFileId ?? '';
  if (options.authMethod != HostAuthMethod.password && keyId.isNotEmpty) {
    data['identityFileId'] = keyId;
  }
  if (identity != null) useCredentialOn(data, identity);
  final group = options.group?.trim() ?? '';
  if (group.isNotEmpty) data['group'] = group;
  if (options.jumpHostIds.isNotEmpty) {
    data['hostChain'] = {
      'hostIds': [...options.jumpHostIds],
      if (options.jumpRouteConfirmation != null)
        jumpRouteConfirmationKey: options.jumpRouteConfirmation,
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
      identities: vaultIdentityMaps(vault),
    );
    return false;
  } on RouteConfigException {
    return true;
  }
}
