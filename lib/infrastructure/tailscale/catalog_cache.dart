import 'dart:convert';

import 'tailscale_device.dart';

/// 一个目录来源在本机的缓存（R12）：只有 provider 拥有的字段，没有任何凭据。
///
/// 身份是 (catalogId, deviceId)。catalogId 是本机给这个来源起的 ID，不是 tailnet 名：
/// 两个来源都写 `-`（「凭据所属的 tailnet」）时，App 无从确认它们是不是同一个 tailnet
/// ——列设备接口不返回任何 tailnet 标识——所以永远分开存、不自动合并（TSC10）。
class CatalogCache {
  const CatalogCache({
    required this.catalogId,
    required this.tailnet,
    this.label,
    this.devices = const {},
    this.lastAttempt,
    this.lastSuccess,
  });

  static const schemaVersion = 1;

  final String catalogId;
  final String tailnet;

  /// 用户给来源起的名字，只用于显示。
  final String? label;
  final Map<String, CatalogDeviceRecord> devices;

  /// 最近一次刷新（成功或失败）。
  final CatalogRefresh? lastAttempt;

  /// 最近一次成功拿到设备列表。界面上显示的「缓存时间」是它。
  final CatalogRefresh? lastSuccess;

  CatalogCache copyWith({
    Map<String, CatalogDeviceRecord>? devices,
    CatalogRefresh? lastAttempt,
    CatalogRefresh? lastSuccess,
  }) =>
      CatalogCache(
        catalogId: catalogId,
        tailnet: tailnet,
        label: label,
        devices: devices ?? this.devices,
        lastAttempt: lastAttempt ?? this.lastAttempt,
        lastSuccess: lastSuccess ?? this.lastSuccess,
      );

  /// 把一次成功的列设备结果并进缓存。**只加、只改、只标记，从不删除**。
  ///
  /// - 列表里有的：更新 provider 字段；以前标过「不见了」的恢复。
  /// - 列表里没有的：只有快照结构完整、且不是空列表时才标「目录里不见了」并记下时间。
  ///   不完整（缺 id、重复 id）或空列表都不据此推断——坏快照和空快照不能让任何设备消失（TSC05）。
  CatalogCache merge(TailscaleDeviceSnapshot snapshot, DateTime at) {
    final next = <String, CatalogDeviceRecord>{};
    for (final device in snapshot.devices) {
      final previous = devices[device.id];
      next[device.id] = CatalogDeviceRecord.fromDevice(
        device,
        firstSeenAt: previous?.firstSeenAt ?? at,
        lastListedAt: at,
      );
    }
    final canInferMissing = snapshot.complete && snapshot.devices.isNotEmpty;
    final skipped = snapshot.skippedEntries;
    final duplicates = snapshot.duplicateIds.length;
    for (final MapEntry(key: id, value: old) in devices.entries) {
      if (next.containsKey(id)) continue;
      next[id] = canInferMissing && old.missingSince == null
          ? old.markMissing(at)
          : old;
    }
    final refresh = CatalogRefresh(
      at: at,
      ok: true,
      complete: snapshot.complete,
      deviceCount: snapshot.devices.length,
      note: snapshot.devices.isEmpty
          ? '目录返回 0 台设备，没有据此把已有设备标成不见了'
          : snapshot.complete
              ? null
              : '这次的列表不完整（$skipped 条无法识别、$duplicates 个重复 ID），没有据此把已有设备标成不见了',
    );
    return copyWith(devices: next, lastAttempt: refresh, lastSuccess: refresh);
  }

  /// 刷新失败：设备一台都不动，只记下失败原因和时间。[message] 必须已脱敏（R11 的报错本来就不含凭据）。
  CatalogCache recordFailure(String message, DateTime at) => copyWith(
        lastAttempt: CatalogRefresh(
          at: at,
          ok: false,
          complete: false,
          deviceCount: 0,
          note:
              message.length > 300 ? '${message.substring(0, 300)}…' : message,
        ),
      );

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'catalogId': catalogId,
        'tailnet': tailnet,
        if (label != null) 'label': label,
        'devices': [for (final d in devices.values) d.toJson()],
        if (lastAttempt != null) 'lastAttempt': lastAttempt!.toJson(),
        if (lastSuccess != null) 'lastSuccess': lastSuccess!.toJson(),
      };

  /// 读不懂（版本不对、结构坏）返回 null，由调用方当作「没有缓存」，不猜。
  static CatalogCache? fromJson(Object? json) {
    if (json is! Map ||
        json['schemaVersion'] != schemaVersion ||
        json['catalogId'] is! String ||
        json['tailnet'] is! String ||
        json['devices'] is! List) {
      return null;
    }
    final devices = <String, CatalogDeviceRecord>{};
    for (final raw in json['devices'] as List) {
      final record = CatalogDeviceRecord.fromJson(raw);
      if (record == null) return null;
      devices[record.id] = record;
    }
    return CatalogCache(
      catalogId: json['catalogId'] as String,
      tailnet: json['tailnet'] as String,
      label: _string(json['label']),
      devices: devices,
      lastAttempt: CatalogRefresh.fromJson(json['lastAttempt']),
      lastSuccess: CatalogRefresh.fromJson(json['lastSuccess']),
    );
  }
}

class CatalogRefresh {
  const CatalogRefresh({
    required this.at,
    required this.ok,
    required this.complete,
    required this.deviceCount,
    this.note,
  });

  final DateTime at;
  final bool ok;
  final bool complete;
  final int deviceCount;

  /// 给用户看的一句说明（为什么没标不见了、失败原因），不含凭据。
  final String? note;

  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'ok': ok,
        'complete': complete,
        'deviceCount': deviceCount,
        if (note != null) 'note': note,
      };

  static CatalogRefresh? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = _time(json['at']);
    if (at == null) return null;
    return CatalogRefresh(
      at: at,
      ok: json['ok'] == true,
      complete: json['complete'] == true,
      deviceCount: (json['deviceCount'] as num?)?.toInt() ?? 0,
      note: _string(json['note']),
    );
  }
}

/// 缓存里的一台设备：R11 解析出的 provider 字段，外加本机观察到的三个时间。
///
/// 用户的覆写（显示名、用户名、端口、身份、路由）不在这里，在保险库的主机记录上；
/// 刷新永远不写那些字段。
class CatalogDeviceRecord {
  const CatalogDeviceRecord({
    required this.device,
    required this.firstSeenAt,
    required this.lastListedAt,
    this.missingSince,
  });

  factory CatalogDeviceRecord.fromDevice(
    TailscaleDevice device, {
    required DateTime firstSeenAt,
    required DateTime lastListedAt,
  }) =>
      CatalogDeviceRecord(
        device: device,
        firstSeenAt: firstSeenAt,
        lastListedAt: lastListedAt,
      );

  final TailscaleDevice device;
  final DateTime firstSeenAt;

  /// 最近一次出现在列表里。和设备的 lastSeen 不是一回事：那是 Tailscale 报告的「上次连控制面」。
  final DateTime lastListedAt;

  /// 在一次完整、非空的列表里没出现，从什么时候起。设备可能被删了、换了 tailnet，
  /// 或者是共享进来的设备而 OAuth token 看不到（tailscale#16911）。不据此删除任何东西。
  final DateTime? missingSince;

  String get id => device.id;
  bool get missing => missingSince != null;

  CatalogDeviceRecord markMissing(DateTime at) => CatalogDeviceRecord(
        device: device,
        firstSeenAt: firstSeenAt,
        lastListedAt: lastListedAt,
        missingSince: at,
      );

  Map<String, Object?> toJson() {
    final d = device;
    String? iso(DateTime? t) => t?.toUtc().toIso8601String();
    return {
      'id': d.id,
      if (d.nodeId != null) 'nodeId': d.nodeId,
      if (d.name != null) 'name': d.name,
      if (d.hostname != null) 'hostname': d.hostname,
      'addresses': d.addresses,
      if (d.os != null) 'os': d.os,
      if (d.user != null) 'user': d.user,
      'tags': d.tags,
      if (d.lastSeen != null) 'lastSeen': iso(d.lastSeen),
      if (d.connectedToControl != null)
        'connectedToControl': d.connectedToControl,
      if (d.authorized != null) 'authorized': d.authorized,
      if (d.isExternal != null) 'isExternal': d.isExternal,
      if (d.keyExpiryDisabled != null) 'keyExpiryDisabled': d.keyExpiryDisabled,
      if (d.expires != null) 'expires': iso(d.expires),
      if (d.blocksIncomingConnections != null)
        'blocksIncomingConnections': d.blocksIncomingConnections,
      'firstSeenAt': iso(firstSeenAt),
      'lastListedAt': iso(lastListedAt),
      if (missingSince != null) 'missingSince': iso(missingSince),
    };
  }

  /// 设备字段复用 R11 的严格解析（缺字段、类型不对记为不知道），本机时间戳缺了就整条作废。
  static CatalogDeviceRecord? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final snapshot = TailscaleDeviceSnapshot.parse(
      jsonEncode({
        'devices': [json],
      }),
    );
    if (snapshot.devices.length != 1) return null;
    final first = _time(json['firstSeenAt']);
    final listed = _time(json['lastListedAt']);
    if (first == null || listed == null) return null;
    final missing = _time(json['missingSince']);
    return CatalogDeviceRecord(
      device: snapshot.devices.single,
      firstSeenAt: first,
      lastListedAt: listed,
      missingSince: missing,
    );
  }
}

// 缓存文件可能被改坏：类型不对一律当作没有，不用 `as` 强转（强转失败会抛异常，而不是「读不懂」）。
String? _string(Object? value) => value is String ? value : null;
DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
