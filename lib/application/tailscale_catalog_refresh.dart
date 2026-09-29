import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/host.dart';
import '../infrastructure/tailscale/catalog_cache.dart';
import '../infrastructure/tailscale/catalog_cache_repository.dart';
import '../infrastructure/tailscale/tailscale_api.dart';
import '../infrastructure/tailscale/tailscale_device.dart';
import 'tailscale_catalog_access.dart';
import 'vault_controller.dart';

/// 主机用设备的哪个地址。默认 IPv4（少依赖 MagicDNS，docs/05）；IPv6 和 FQDN 由用户显式选。
enum CatalogAddressKind { ipv4, ipv6, fqdn }

/// 一台保险库主机和目录设备的关联（R12）。存在主机记录上，只有 ID，不含任何凭据。
///
/// 主机上的显示名、用户名、端口、认证、路由都是用户的，刷新从不写。唯一可能被刷新改的是地址，
/// 而且只在主机地址仍等于 [appliedAddress]（上次由目录写入的值）时——用户改过就不再跟随目录。
class CatalogBinding {
  const CatalogBinding({
    required this.catalogId,
    required this.deviceId,
    this.address = CatalogAddressKind.ipv4,
    this.appliedAddress,
  });

  static const key = 'xwshunCatalogSource';

  final String catalogId;
  final String deviceId;
  final CatalogAddressKind address;

  /// 目录上次写进主机的地址。null 表示从没自动写过，刷新不会改这台主机的地址。
  final String? appliedAddress;

  static CatalogBinding? of(HostProfile host) {
    final raw = host.data[key];
    if (raw is! Map) return null;
    final catalogId = raw['catalogId'];
    final deviceId = raw['deviceId'];
    if (catalogId is! String || deviceId is! String) return null;
    return CatalogBinding(
      catalogId: catalogId,
      deviceId: deviceId,
      address: CatalogAddressKind.values
              .where((k) => k.name == raw['address'])
              .firstOrNull ??
          CatalogAddressKind.ipv4,
      appliedAddress: raw['appliedAddress'] is String
          ? raw['appliedAddress'] as String
          : null,
    );
  }

  Map<String, Object?> toJson() => {
        'catalogId': catalogId,
        'deviceId': deviceId,
        'address': address.name,
        if (appliedAddress != null) 'appliedAddress': appliedAddress,
      };

  /// 设备当前记录里对应种类的地址；没有就是 null（不回退到别的种类，更不回退成系统直连）。
  String? addressOf(TailscaleDevice device) => switch (address) {
        CatalogAddressKind.ipv4 =>
          device.addresses.where((a) => a.contains('.')).firstOrNull,
        CatalogAddressKind.ipv6 =>
          device.addresses.where((a) => a.contains(':')).firstOrNull,
        CatalogAddressKind.fqdn => switch (device.name) {
            final String n when n.endsWith('.') => n.substring(0, n.length - 1),
            final n => n,
          },
      };
}

/// 刷新后这台主机要不要跟着改地址；不用改返回 null。
///
/// 改了地址不会带走任何信任：指纹按地址（逻辑名）记录，新地址第一次连接照常要核对（SEC04），
/// 设备 ID 不能替新地址的新 host key 担保（docs/05）。
HostProfile? refreshedHost(HostProfile host, CatalogCache cache) {
  final binding = CatalogBinding.of(host);
  if (binding == null || binding.catalogId != cache.catalogId) return null;
  final record = cache.devices[binding.deviceId];
  if (record == null || record.missing) return null;
  final address = binding.addressOf(record.device);
  if (address == null || address == binding.appliedAddress) return null;
  if (binding.appliedAddress == null ||
      host.hostname != binding.appliedAddress) {
    return null; // 用户改过地址，或从没由目录写过：尊重用户的值。
  }
  return HostProfile({
    ...host.data,
    'hostname': address,
    CatalogBinding.key: CatalogBinding(
      catalogId: binding.catalogId,
      deviceId: binding.deviceId,
      address: binding.address,
      appliedAddress: address,
    ).toJson(),
  });
}

/// 主机和目录的关系此刻是什么状态。故意没有「在线」「SSH 可用」：
/// 目录只知道设备在不在列表里、连没连 Tailscale 控制面，不知道手机能不能连到它（TSC03、TSC06）。
enum CatalogPresence {
  /// 最近一次列表里有它。
  listed,

  /// 在一次完整、非空的列表里没出现。
  missing,

  /// 缓存里没有这个设备（缓存被清掉、或从另一台手机导入的主机）。
  unknownDevice,

  /// 本机没有这个来源（来源被移除，或关联来自别的设备）。
  sourceNotOnThisDevice,
}

class HostCatalogStatus {
  const HostCatalogStatus({
    required this.presence,
    this.record,
    this.cache,
  });

  final CatalogPresence presence;
  final CatalogDeviceRecord? record;
  final CatalogCache? cache;

  /// Tailscale 报告的控制面连接；null 是不知道。不等于手机能连到它，更不等于 SSH 开着。
  bool? get connectedToControl => record?.device.connectedToControl;
}

HostCatalogStatus? catalogStatusOf(
  HostProfile host,
  Map<String, CatalogCache> caches,
) {
  final binding = CatalogBinding.of(host);
  if (binding == null) return null;
  final cache = caches[binding.catalogId];
  if (cache == null) {
    return const HostCatalogStatus(
      presence: CatalogPresence.sourceNotOnThisDevice,
    );
  }
  final record = cache.devices[binding.deviceId];
  return HostCatalogStatus(
    presence: record == null
        ? CatalogPresence.unknownDevice
        : record.missing
            ? CatalogPresence.missing
            : CatalogPresence.listed,
    record: record,
    cache: cache,
  );
}

class CatalogRefreshOutcome {
  const CatalogRefreshOutcome(this.cache,
      {this.hostsReaddressed = 0, this.error});
  final CatalogCache cache;

  /// 跟着目录改了地址的主机数。
  final int hostsReaddressed;

  /// 刷新失败的原因（已脱敏）。失败时缓存里的设备和所有主机都没动。
  final TailscaleApiException? error;
}

/// 目录来源的增删与刷新（R12）。界面在 R13。
///
/// 刷新只做三件事：把列表并进缓存（只加、只改、只标记）、保存、给「地址仍跟随目录」的主机改地址。
/// 失败只记原因；删来源只删缓存和凭据副本——这些操作都不删除、不改写任何主机的用户字段。
class CatalogRefresher {
  CatalogRefresher({
    required TailscaleCatalogAccess access,
    required CatalogCacheRepository repository,
    required Future<List<HostProfile>> Function() hosts,
    required Future<void> Function(
      String id,
      HostProfile? Function(HostProfile current) change,
    ) updateHost,
    DateTime Function()? now,
  })  : _access = access,
        _repository = repository,
        _hosts = hosts,
        _updateHost = updateHost,
        _now = now ?? DateTime.now;

  final TailscaleCatalogAccess _access;
  final CatalogCacheRepository _repository;
  final Future<List<HostProfile>> Function() _hosts;
  final Future<void> Function(String, HostProfile? Function(HostProfile))
      _updateHost;
  final DateTime Function() _now;

  Future<CatalogCache> addSource({
    required String catalogId,
    String tailnet = '-',
    String? label,
  }) async {
    if (await _repository.load(catalogId) != null) {
      throw StateError('这个目录来源已存在');
    }
    final cache = CatalogCache(
      catalogId: catalogId,
      tailnet: tailnet,
      label: label,
    );
    await _repository.save(cache);
    return cache;
  }

  /// 用已保存的 OAuth client 刷新（受控刷新一次 401 在 R11 里）。
  Future<CatalogRefreshOutcome> refreshSaved(String catalogId) => _refresh(
        catalogId,
        (tailnet) =>
            _access.refreshSaved(catalogId: catalogId, tailnet: tailnet),
      );

  /// 用粘贴的短期 token 刷新一次，token 不保存。
  Future<CatalogRefreshOutcome> refreshWithToken(
    String catalogId,
    String token,
  ) =>
      _refresh(
        catalogId,
        (tailnet) => _access.readOnceWithToken(token, tailnet: tailnet),
      );

  /// 只删本机保存的 OAuth client（来源、缓存、主机都留着）。之后刷新会要求重新授权。
  /// 这只是删副本：要让它彻底失效，得在 Tailscale 后台撤销。
  Future<void> forgetCredentials(String catalogId) =>
      _access.forgetSaved(catalogId);

  /// 移除来源：删缓存和本机保存的 client。关联它的主机原样保留（显示「来源不在本机」），
  /// 由用户决定断开关联还是删除主机（TSC10、DEV02）。
  Future<void> removeSource(String catalogId) async {
    await _access.forgetSaved(catalogId);
    await _repository.delete(catalogId);
  }

  Future<CatalogRefreshOutcome> _refresh(
    String catalogId,
    Future<TailscaleDeviceListing> Function(String tailnet) read,
  ) async {
    final cache = await _repository.load(catalogId);
    if (cache == null) throw StateError('本机没有这个目录来源');
    final TailscaleDeviceListing listing;
    try {
      listing = await read(cache.tailnet);
    } on TailscaleApiException catch (error) {
      final failed = cache.recordFailure(error.message, _now());
      await _repository.save(failed);
      return CatalogRefreshOutcome(failed, error: error);
    }
    final next = cache.merge(listing.snapshot, _now());
    await _repository.save(next);
    var readdressed = 0;
    for (final host in await _hosts()) {
      if (CatalogBinding.of(host)?.catalogId != catalogId) continue;
      var changed = false;
      await _updateHost(host.id, (current) {
        final updated = refreshedHost(current, next);
        changed = updated != null;
        return updated;
      });
      if (changed) readdressed++;
    }
    return CatalogRefreshOutcome(next, hostsReaddressed: readdressed);
  }
}

final catalogRefresherProvider = Provider<CatalogRefresher>((ref) {
  final vault = ref.watch(vaultControllerProvider.notifier);
  return CatalogRefresher(
    access: ref.watch(tailscaleCatalogAccessProvider),
    repository: ref.watch(catalogCacheRepositoryProvider),
    hosts: () async => (await vault.ready()).hosts,
    updateHost: vault.updateHost,
  );
});
