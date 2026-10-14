import '../infrastructure/plugins/rustdesk_external.dart';

/// 独立条目的 RustDesk ID：hostId 沿用旧存储字段名，现指本 provider 的条目 ID。
///
/// 只存在本机的独立加密存储里，不进保险库：保险库要和桌面端同步，那边不认这个字段；
/// 这条关联也不该跟着保险库导出（docs/17）。
class RustDeskLink {
  const RustDeskLink({
    required this.id,
    required this.hostId,
    required this.peer,
    required this.createdAt,
  });

  /// 本 App 给这条关联起的 ID（设备引用用它，不用 RustDesk ID）。
  final String id;
  final String hostId;
  final RustDeskPeerId peer;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'hostId': hostId,
        'peerId': peer.value,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  /// 校验不通过返回 null，由存储层阻止整份数据被启用，不静默丢记录。
  static RustDeskLink? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final hostId = json['hostId'];
    final peerId = json['peerId'];
    final created = json['createdAt'] is String
        ? DateTime.tryParse(json['createdAt'] as String)
        : null;
    if (id is! String ||
        hostId is! String ||
        peerId is! String ||
        created == null) {
      return null;
    }
    try {
      return RustDeskLink(
        id: id,
        hostId: hostId,
        peer: RustDeskPeerId.parse(peerId),
        createdAt: created,
      );
    } on RustDeskPeerIdRejected {
      return null;
    }
  }
}
