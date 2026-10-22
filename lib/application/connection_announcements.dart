import 'session_controller.dart';

/// 一个标签上次念过以后的连接状态。
///
/// 要自己存一份：`ActiveTerminalSession.connected` 是原地改的字段，前后两次 [SessionState]
/// 里是同一个对象，拿上一次的 state 比永远看不出变化。
typedef TabLinkState = ({bool connected, bool recovering});

Map<String, TabLinkState> tabLinkStates(SessionState state) => {
      for (final session in state.sessions)
        if (!session.closedByUser)
          session.id: (
            connected: session.connected,
            recovering: state.recovering.contains(session.id),
          ),
    };

/// 读屏要主动念的连接变化（UX02）。
///
/// 画面上断线有横幅写字，但 TalkBack 用户不摸到那条就不知道断了；真机上拔线断开、自动恢复都一声不吐。
/// 只念前后都在的标签：新开的有等待页、关掉的是用户自己点的，不用再说。
List<String> connectionAnnouncements(
  Map<String, TabLinkState> before,
  SessionState after,
) {
  final messages = <String>[];
  for (final session in after.sessions) {
    final was = before[session.id];
    if (was == null || session.closedByUser) continue;
    final name = session.host.label;
    final recovering = after.recovering.contains(session.id);
    if (was.connected && !session.connected) {
      messages.add(
        recovering ? '“$name”断开了，正在自动恢复' : '“$name”断开了',
      );
    } else if (!was.connected && session.connected) {
      messages.add('“$name”重新连上了');
    } else if (!session.connected && was.recovering && !recovering) {
      messages.add('“$name”没能自动恢复，可以点「重新连接」');
    }
  }
  return messages;
}
