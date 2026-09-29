/// 某个 provider 自己的设备引用。身份只由 (providerId, refId) 决定，
/// 名字和地址只是展示用的"自称"，两个 provider 报出同名同 IP 也不代表是同一台（DEV01）。
class ProviderDeviceRef {
  const ProviderDeviceRef({
    required this.providerId,
    required this.refId,
    required this.displayName,
    this.addresses = const [],
  });

  final String providerId;
  final String refId;
  final String displayName;
  final List<String> addresses;

  @override
  bool operator ==(Object other) =>
      other is ProviderDeviceRef &&
      other.providerId == providerId &&
      other.refId == refId;

  @override
  int get hashCode => Object.hash(providerId, refId);
}

/// 用户显式关联的一组引用。每个引用仍归各自 provider 所有，
/// 认证方式、路由、凭据都挂在各自引用上，关联不会互相复制。
class DeviceRecord {
  DeviceRecord._(this.id, this.refs);

  final String id;
  final Set<ProviderDeviceRef> refs;
}

class DeviceLinks {
  final _records = <String, DeviceRecord>{};
  var _next = 0;

  Iterable<DeviceRecord> get records => _records.values;

  /// 唯一的建立关联方式：用户在界面上明确选中两条（或多条）引用。
  ///
  /// 故意没有"按名字/IP 自动合并"的方法——自动合并会把 A 设备的 SSH 身份
  /// 或网络策略错套到 B 设备上。
  DeviceRecord linkByUser(Iterable<ProviderDeviceRef> refs) {
    final set = refs.toSet();
    if (set.length < 2) {
      throw ArgumentError('至少选择两条引用才能关联');
    }
    if (set.map((r) => r.providerId).toSet().length != set.length) {
      throw ArgumentError('同一个 provider 的两条引用不能关联成一台设备');
    }
    for (final record in _records.values) {
      if (record.refs.intersection(set).isNotEmpty) {
        throw StateError('其中有引用已属于另一条设备记录，先解除关联');
      }
    }
    final record = DeviceRecord._('device-${_next++}', Set.unmodifiable(set));
    _records[record.id] = record;
    return record;
  }

  /// 解除关联只删记录本身；各 provider 的引用和它们的设置原样保留。
  void unlink(String recordId) => _records.remove(recordId);

  /// 只把一条引用从它所在的记录里拿出来（比如用户移除了某个目录来源，DEV02）。
  /// 其余引用继续互相关联；只剩一条时记录不再有意义，随之解散。任何引用本身都不删除。
  void unlinkRef(ProviderDeviceRef ref) {
    final record = recordOf(ref);
    if (record == null) return;
    final rest = record.refs.difference({ref});
    if (rest.length < 2) {
      _records.remove(record.id);
    } else {
      _records[record.id] = DeviceRecord._(record.id, Set.unmodifiable(rest));
    }
  }

  DeviceRecord? recordOf(ProviderDeviceRef ref) =>
      _records.values.where((r) => r.refs.contains(ref)).firstOrNull;
}
