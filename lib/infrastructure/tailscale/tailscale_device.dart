import 'dart:convert';
import 'dart:io';

/// Tailscale 设备列表里的一台设备，只留目录用得到的字段（R11）。
///
/// 字段名和类型照官方 OpenAPI 的 `Device` schema（默认字段集）。schema 没有 required 列表，
/// 任何字段都可能缺：缺了或类型不对就是 null（UNKNOWN），不补默认值。
///
/// 故意丢掉的默认字段：machineKey、nodeKey、tailnetLockKey、tailnetLockError、clientVersion、
/// updateAvailable、created、isEphemeral——目录用不到，存了只是多一份管理数据。
///
/// **没有任何「能不能 SSH」的信息。**官方的 sshEnabled 只在 fields=all 才返回，且表示的是
/// Tailscale SSH，不是普通 sshd；这里不请求它。connectedToControl 表示连着 Tailscale 控制面，
/// 也不代表手机此刻能连到它，更不代表 22 端口开着（docs/05）。
class TailscaleDevice {
  const TailscaleDevice({
    required this.id,
    this.nodeId,
    this.name,
    this.hostname,
    this.addresses = const [],
    this.os,
    this.user,
    this.tags = const [],
    this.lastSeen,
    this.connectedToControl,
    this.authorized,
    this.isExternal,
    this.keyExpiryDisabled,
    this.expires,
    this.blocksIncomingConnections,
  });

  /// 设备 ID。和 catalogId 一起才是稳定身份，名字和地址都不是（docs/05）。
  final String id;
  final String? nodeId;

  /// MagicDNS 全名，比如 `host.tail1234.ts.net`。
  final String? name;
  final String? hostname;

  /// 只保留合法的 IP 字面量。
  final List<String> addresses;
  final String? os;
  final String? user;
  final List<String> tags;
  final DateTime? lastSeen;
  final bool? connectedToControl;
  final bool? authorized;
  final bool? isExternal;
  final bool? keyExpiryDisabled;
  final DateTime? expires;
  final bool? blocksIncomingConnections;
}

/// 一次列设备响应的解析结果。
///
/// [complete] 只有在响应结构正确、每一条都有合法且不重复的 id 时才为 true。
/// R12 只能在 complete 时推断「某台设备不见了」；否则只更新能确认的记录，绝不据此删除主机。
/// 官方明确说明没有分页、一次返回全部，所以一个结构完整的响应就是整个 tailnet 的快照。
class TailscaleDeviceSnapshot {
  const TailscaleDeviceSnapshot({
    required this.devices,
    required this.skippedEntries,
    required this.duplicateIds,
  });

  final List<TailscaleDevice> devices;

  /// 没有合法 id、不是对象的条目数。
  final int skippedEntries;

  /// 出现不止一次的 id（只保留第一条）。
  final Set<String> duplicateIds;

  bool get complete => skippedEntries == 0 && duplicateIds.isEmpty;

  static const _maxDevices = 50000;

  /// 顶层必须是 `{"devices": [...]}`。结构不对直接抛 [FormatException]——空快照和坏快照
  /// 不能被当成「tailnet 里没有设备」。
  static TailscaleDeviceSnapshot parse(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw const FormatException('设备列表不是 JSON');
    }
    if (json is! Map<String, Object?> || json['devices'] is! List) {
      throw const FormatException('设备列表缺少 devices 数组');
    }
    final raw = json['devices'] as List;
    if (raw.length > _maxDevices) {
      throw const FormatException('设备数量超出上限');
    }
    final devices = <TailscaleDevice>[];
    final seen = <String>{};
    final duplicates = <String>{};
    var skipped = 0;
    for (final entry in raw) {
      final device = entry is Map<String, Object?> ? _device(entry) : null;
      if (device == null) {
        skipped++;
        continue;
      }
      if (!seen.add(device.id)) {
        duplicates.add(device.id);
        continue;
      }
      devices.add(device);
    }
    return TailscaleDeviceSnapshot(
      devices: List.unmodifiable(devices),
      skippedEntries: skipped,
      duplicateIds: Set.unmodifiable(duplicates),
    );
  }

  static TailscaleDevice? _device(Map<String, Object?> m) {
    final id = _string(m['id'], max: 128);
    if (id == null || id.isEmpty) return null;
    return TailscaleDevice(
      id: id,
      nodeId: _string(m['nodeId'], max: 128),
      name: _string(m['name'], max: 253),
      hostname: _string(m['hostname'], max: 253),
      addresses: _strings(m['addresses'], max: 16)
          .where((a) => InternetAddress.tryParse(a) != null)
          .toList(growable: false),
      os: _string(m['os'], max: 64),
      user: _string(m['user'], max: 320),
      tags: _strings(m['tags'], max: 64),
      lastSeen: _time(m['lastSeen']),
      connectedToControl: _bool(m['connectedToControl']),
      authorized: _bool(m['authorized']),
      isExternal: _bool(m['isExternal']),
      keyExpiryDisabled: _bool(m['keyExpiryDisabled']),
      expires: _time(m['expires']),
      blocksIncomingConnections: _bool(m['blocksIncomingConnections']),
    );
  }

  static final _control = RegExp(r'[\x00-\x1f\x7f]');

  static String? _string(Object? value, {required int max}) {
    if (value is! String || value.length > max || _control.hasMatch(value)) {
      return null;
    }
    return value;
  }

  static List<String> _strings(Object? value, {required int max}) {
    if (value is! List) return const [];
    return value
        .map((e) => _string(e, max: 253))
        .whereType<String>()
        .take(max)
        .toList(growable: false);
  }

  static bool? _bool(Object? value) => value is bool ? value : null;

  /// 官方说明 lastSeen 在从未上线或正连着控制面时省略；外部设备 created 为空。
  /// 官方 Go 客户端把空串当零值；这里空串、零时间、解析失败都记为 null（不知道）。
  static DateTime? _time(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null || parsed.year <= 1) return null;
    return parsed.toUtc();
  }
}
