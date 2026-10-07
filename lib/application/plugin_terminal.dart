import 'dart:async';
import 'dart:typed_data';

import 'package:plugin_api/plugin_api.dart';

import '../domain/connection_route.dart';
import '../domain/models/host.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/terminal/terminal_session_adapter.dart';
import 'plugin_sessions.dart';

/// 把一个插件会话接到标签的终端上：Mosh（X09）和第三方终端插件（X12）共用这一条路。
///
/// 单一所有者（docs/16 第 5 步、MOS05）：终端的输入和尺寸只有这一个出口——终端绑定 → [PluginTerminalSession.write] /
/// resize → 插件的 FD。终端引擎已经把按键、输入法提交编成了字节，这里原样转交，不再编码一遍；也没有第二条路往插件写。
/// 输出原样进终端：插件写的 VT 字节，分块边界是 FD 读的边界，被切开的字符由终端适配器拼回去。
///
/// 会话结束后输入绑定立刻解除：之后的按键直接丢掉，不排队，也不留给下一次连接重发（NET11 的插件部分）。
/// 结束了就是结束了：会话控制器不自动重连插件标签，[endNotice] 写明为什么结束、怎么再连。
class PluginTerminalProvider implements PluginTerminalLink {
  PluginTerminalProvider(
    this.session, {
    required this.protocol,
    required this.detail,
    required String Function(PluginTerminalSession session) endNotice,
  }) : _noticeOf = endNotice;

  final PluginTerminalSession session;

  @override
  final String protocol;

  @override
  final String detail;

  final String Function(PluginTerminalSession session) _noticeOf;
  TerminalBinding? _binding;
  StreamSubscription<SessionPhase>? _phaseSubscription;
  (int, int)? _pendingSize;
  final _ended = Completer<void>();
  String? _endNotice;

  /// 终端交给这个会话的输入次数，和 [PluginTerminalSession.writeCount] 对照：两者相等说明每次提交只写了一次。
  int inputEvents = 0;

  /// 插件没收下的输入字节（会话已结束、积压超限）。这些字节不重发。
  int droppedInputBytes = 0;

  /// 绑到终端上，做成一个标签。终端已释放（标签在打开途中被关）时关掉会话再抛出。
  static ActiveTerminalSession attach(
    PluginTerminalProvider link, {
    required String sessionId,
    required HostProfile host,
    RoutePlan? plan,
    required TerminalSessionAdapter terminal,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
  }) {
    final TerminalBinding binding;
    try {
      binding = terminal.bind(link._input, resize: link._resize);
    } on Object {
      // 标签在打开途中被关、终端已释放：会话没人要了。
      unawaited(link.session.close());
      rethrow;
    }
    link._binding = binding;
    final output = link.session.output.listen(terminal.feed);
    link._watch();
    return ActiveTerminalSession(
      id: sessionId,
      host: host,
      terminal: terminal,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
      routePlan: plan,
      plugin: link,
      binding: binding,
      outputSubscriptions: [output],
    );
  }

  @override
  bool get active =>
      !_ended.isCompleted &&
      (session.phase == SessionPhase.active ||
          session.phase == SessionPhase.opening);

  @override
  Future<void> get ended => _ended.future;

  @override
  String? get endNotice => _endNotice;

  @override
  Future<void> close() => session.close();

  void _watch() {
    _onPhase(session.phase);
    if (_ended.isCompleted) return;
    _phaseSubscription = session.phases.listen(_onPhase);
  }

  void _onPhase(SessionPhase phase) {
    if (phase == SessionPhase.active) _flushSize();
    if (phase.isTerminal) _end();
  }

  void _end() {
    if (_ended.isCompleted) return;
    _binding?.release();
    unawaited(_phaseSubscription?.cancel());
    _endNotice = _noticeOf(session);
    _ended.complete();
  }

  void _input(Uint8List bytes) {
    if (_ended.isCompleted) return;
    inputEvents++;
    try {
      unawaited(session.write(bytes).catchError((Object _) {
        droppedInputBytes += bytes.length;
      }));
    } on StateError {
      droppedInputBytes += bytes.length;
    }
  }

  /// 插件只在会话运行时接受改尺寸；还在打开时先记下最新的，运行起来再发。
  void _resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    _pendingSize = (columns, rows);
    _flushSize();
  }

  void _flushSize() {
    final size = _pendingSize;
    if (size == null || session.phase != SessionPhase.active) return;
    _pendingSize = null;
    unawaited(session.resize(size.$1, size.$2).catchError((Object _) {}));
  }
}
