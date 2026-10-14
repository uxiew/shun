import 'package:plugin_api/plugin_api.dart';
import '../domain/remote_entry.dart';
import '../infrastructure/plugins/uuremote_adapter.dart';

/// 独立条目的 UU 绑定；hostId 沿用旧字段名，现指本 provider 的条目 ID。
///
/// 只存在本机的独立安全存储里，不进保险库：加密标识和生成它时登录的 UU 账号绑定，换手机、换账号都用不了，
/// 同步过去没有意义；它又是敏感值，不能跟着保险库导出（docs/17）。
class UuBinding {
  const UuBinding({
    required this.id,
    required this.hostId,
    required this.anonymousDeviceId,
    required this.createdAt,
    this.invalidReason,
    this.invalidAt,
  });

  final String id;
  final String hostId;

  /// UU 返回的加密设备标识。不透明：不解密、不显示、不写日志、不复制到剪贴板。
  final String anonymousDeviceId;
  final DateTime createdAt;

  /// UU 报告这条绑定失效的原因（目前只有 device_not_found：设备解绑、被删或换了 UU 账号）。
  final String? invalidReason;
  final DateTime? invalidAt;

  bool get valid => invalidReason == null;

  UuBinding invalidated(String reason, DateTime at) => UuBinding(
        id: id,
        hostId: hostId,
        anonymousDeviceId: anonymousDeviceId,
        createdAt: createdAt,
        invalidReason: reason,
        invalidAt: at,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'hostId': hostId,
        'anonymousDeviceId': anonymousDeviceId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (invalidReason != null) 'invalidReason': invalidReason,
        if (invalidAt != null)
          'invalidAt': invalidAt!.toUtc().toIso8601String(),
      };

  static UuBinding? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final hostId = json['hostId'];
    final device = json['anonymousDeviceId'];
    final created = json['createdAt'] is String
        ? DateTime.tryParse(json['createdAt'] as String)
        : null;
    if (id is! String ||
        hostId is! String ||
        device is! String ||
        device.isEmpty ||
        device.length > maxDeviceIdLength ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(device) ||
        created == null) {
      return null;
    }
    return UuBinding(
      id: id,
      hostId: hostId,
      anonymousDeviceId: device,
      createdAt: created,
      invalidReason: json['invalidReason'] is String
          ? json['invalidReason'] as String
          : null,
      invalidAt: json['invalidAt'] is String
          ? DateTime.tryParse(json['invalidAt'] as String)
          : null,
    );
  }

  /// 调试输出里不带加密标识。
  @override
  String toString() =>
      'UuBinding($id -> host $hostId${valid ? '' : ', invalid'})';
}

/// 等 UU 回调的请求。同一时刻只有一个（官方：UU 同一时刻只处理一个第三方请求）。
///
/// state、nonce 是一次性的随机值：只有它们对上，回调才算这个请求的；用过、过期、被用户结束等待就作废。
/// 存进安全存储：UU 在前台远控时本 App 可能被系统杀掉，回调来时要能在新进程里对上。
class UuPendingRequest {
  const UuPendingRequest({
    required this.kind,
    required this.state,
    required this.hostId,
    required this.createdAt,
    required this.expiresAt,
    this.nonce,
    this.bindingId,
  });

  final UuCallbackKind kind;
  final String state;

  /// 只有绑定请求有（控制请求官方没有 nonce 字段）。
  final String? nonce;
  final String hostId;

  /// 控制请求对应的绑定。
  final String? bindingId;
  final DateTime createdAt;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'state': state,
        if (nonce != null) 'nonce': nonce,
        'hostId': hostId,
        if (bindingId != null) 'bindingId': bindingId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };

  static UuPendingRequest? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind =
        UuCallbackKind.values.where((k) => k.name == json['kind']).firstOrNull;
    final state = json['state'];
    final hostId = json['hostId'];
    DateTime? time(Object? v) => v is String ? DateTime.tryParse(v) : null;
    final created = time(json['createdAt']);
    final expires = time(json['expiresAt']);
    if (kind == null ||
        state is! String ||
        hostId is! String ||
        created == null ||
        expires == null ||
        !expires.isAfter(created) ||
        expires.difference(created) > uuPendingLifetime ||
        !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(state) ||
        (kind == UuCallbackKind.bind &&
            (json['nonce'] is! String ||
                (json['nonce'] as String).isEmpty ||
                (json['nonce'] as String).length > 128)) ||
        (kind == UuCallbackKind.control &&
            (json['bindingId'] is! String ||
                (json['bindingId'] as String).isEmpty))) {
      return null;
    }
    return UuPendingRequest(
      kind: kind,
      state: state,
      nonce: json['nonce'] is String ? json['nonce'] as String : null,
      hostId: hostId,
      bindingId:
          json['bindingId'] is String ? json['bindingId'] as String : null,
      createdAt: created,
      expiresAt: expires,
    );
  }
}

/// UU 远控这件事本 App 能知道的全部状态。故意没有「已连接」：
/// 全屏 UU 从不回报；小窗的成功只是 UU 在那一刻的报告（ExternalLaunchPhase 同样没有 connected）。
class UuAttempt {
  const UuAttempt({
    required this.kind,
    required this.phase,
    required this.at,
    this.window,
    this.code,
    this.unconfirmed = false,
  });

  final UuCallbackKind kind;
  final ExternalLaunchPhase phase;
  final DateTime at;
  final UuWindow? window;

  /// UU 报告的错误码 / reason 原文，或本 App 的拒收原因。
  final String? code;

  /// 用户结束了等待：UU 之后再回报也不算数。
  final bool unconfirmed;
}

/// UU 绑定成功回调、等用户确认的那一刻。只在内存里：确认前 App 被杀，就当没绑，用户重新绑一次。
class UuBindOffer {
  const UuBindOffer({
    required this.hostId,
    required this.anonymousDeviceId,
    required this.receivedAt,
  });
  final String hostId;
  final String anonymousDeviceId;
  final DateTime receivedAt;
}

class UuRemoteState {
  const UuRemoteState({
    this.app,
    this.bindings = const [],
    this.pending,
    this.offer,
    this.attempts = const {},
    this.notice,
    this.loaded = false,
    this.entries = const [],
    this.callbackRivals = const [],
  });

  /// null：还没探测过。
  final UuAppStatus? app;

  /// 最近一次探测到的、也声明了本 App 回调地址的其他包（见 [UuProbe.callbackRivals]）。
  final List<String> callbackRivals;
  final List<UuBinding> bindings;
  final UuPendingRequest? pending;
  final UuBindOffer? offer;

  /// 按主机 id：最近一次绑定或远控的结果。
  final Map<String, UuAttempt> attempts;

  /// 最近一条给用户看的提示（比如忽略了一条回调），不含加密标识。
  final String? notice;
  final bool loaded;
  final List<RemoteEntry> entries;

  UuBinding? bindingOf(String hostId) =>
      bindings.where((b) => b.hostId == hostId).firstOrNull;

  UuRemoteState copyWith({
    UuAppStatus? app,
    List<UuBinding>? bindings,
    UuPendingRequest? Function()? pending,
    UuBindOffer? Function()? offer,
    Map<String, UuAttempt>? attempts,
    String? Function()? notice,
    bool? loaded,
    List<RemoteEntry>? entries,
    List<String>? callbackRivals,
  }) =>
      UuRemoteState(
        callbackRivals: callbackRivals ?? this.callbackRivals,
        app: app ?? this.app,
        bindings: bindings ?? this.bindings,
        pending: pending == null ? this.pending : pending(),
        offer: offer == null ? this.offer : offer(),
        attempts: attempts ?? this.attempts,
        notice: notice == null ? this.notice : notice(),
        loaded: loaded ?? this.loaded,
        entries: entries ?? this.entries,
      );
}

/// 官方未登录队列最长 180 秒；本机统一限等 10 分钟，迁移不能延长它。
const uuPendingLifetime = Duration(minutes: 10);
