import 'tmux_target.dart';

/// One explicit AI CLI run in a dedicated tmux session's sole pane. Session
/// identity alone is insufficient: a pane may be replaced within that session.
class AiCliTmuxRun {
  AiCliTmuxRun({
    required this.requestId,
    required this.target,
    required this.windowId,
    required this.paneId,
    required this.panePid,
  }) {
    if (!_uuid.hasMatch(requestId) ||
        !_window.hasMatch(windowId) ||
        !_pane.hasMatch(paneId) ||
        panePid <= 0 ||
        target.displayName != 'shun-ai-$requestId') {
      throw const FormatException('AI tmux 目标无效');
    }
  }

  static final _uuid =
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  static final _window = RegExp(r'^@\d{1,9}$');
  static final _pane = RegExp(r'^%\d{1,9}$');

  final String requestId;
  final TmuxTarget target;
  final String windowId;
  final String paneId;
  final int panePid;

  String get paneGuard => '${target.sessionId}:$windowId:$paneId:$panePid';

  bool sameAs(AiCliTmuxRun other) =>
      target.sameAs(other.target) &&
      windowId == other.windowId &&
      paneId == other.paneId &&
      panePid == other.panePid &&
      requestId == other.requestId;

  Map<String, Object?> toJson() => {
        'requestId': requestId,
        'target': target.toJson(),
        'windowId': windowId,
        'paneId': paneId,
        'panePid': panePid,
      };

  static AiCliTmuxRun? fromJson(Object? raw) {
    try {
      final data = raw as Map<String, dynamic>;
      final target =
          TmuxTarget.fromJson((data['target'] as Map).cast<String, Object?>());
      if (target == null) return null;
      return AiCliTmuxRun(
        requestId: data['requestId'] as String,
        target: target,
        windowId: data['windowId'] as String,
        paneId: data['paneId'] as String,
        panePid: data['panePid'] as int,
      );
    } on Object {
      return null;
    }
  }
}
