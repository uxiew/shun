/// 断线后的自动恢复为什么停了（R22）。规则见 `application/connection_lifecycle.dart`。
library;

enum RestoreHoldKind {
  /// 回到前台（手机已解锁、人在）时自动再给一轮恢复。
  untilForeground,

  /// 要用户点「重新连接」。
  untilUser,
}

/// 界面照 [message] 原样显示，旁边给「重新连接」。
class RestoreHold {
  const RestoreHold(this.kind, this.message);

  const RestoreHold.untilUser(this.message) : kind = RestoreHoldKind.untilUser;

  const RestoreHold.untilForeground(this.message)
      : kind = RestoreHoldKind.untilForeground;

  final RestoreHoldKind kind;
  final String message;

  @override
  String toString() => message;
}
