import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:uuid/uuid.dart';

import '../infrastructure/plugins/android_plugin_bridge.dart';
import 'plugin_discovery.dart';
import 'plugin_registry.dart';

/// 插件提供的一个终端会话（X03）。字节走 FD，这里只是宿主侧的状态机和字节流出口。
///
/// 规则（docs/15 §5、§7）：
/// - 代次和句柄由宿主生成；插件事件的代次不对、序号不增、或会话已进入关闭/终止状态，一律不改变状态——
///   已关的会话不会被迟到的 active「复活」（PLG08）。
/// - 关闭幂等：先关宿主这一端，再请插件关；插件 [closeConfirmWindow] 内回报 closed 才算确认停止，
///   否则 [stopConfirmed] 为 false，界面照实显示「停止未确认」，不伪报成功（PLG12）。
/// - 输出只有真正交给订阅者之后才回 ack；订阅者暂停或还没订阅就不回，宿主随之停读，背压传回插件（PLG07）。
class PluginTerminalSession implements PluginSessionHandle {
  PluginTerminalSession._(
    this._manager,
    this.packageName,
    this.providerId,
    this.handle,
    this.generation,
  ) : _state = SessionState(generation, 0, SessionPhase.opening) {
    _output = StreamController<Uint8List>(
      onListen: _flushAcks,
      onResume: _flushAcks,
    );
  }

  static const closeConfirmWindow = Duration(seconds: 2);

  final PluginSessionManager _manager;
  final String packageName;
  final String providerId;
  final String handle;
  final int generation;
  late final StreamController<Uint8List> _output;
  final _phases = StreamController<SessionPhase>.broadcast(sync: true);
  SessionState<SessionPhase> _state;
  int _pendingAcks = 0;
  Completer<void>? _closing;

  /// null：还没关，或不是宿主发起的关闭；true：插件确认停止；false：等不到确认。
  bool? stopConfirmed;

  /// 最近一次插件确认的尺寸（「cols x rows」）。
  String? lastResize;

  /// 宿主丢弃的属于这个会话的事件数（旧代次、会话已关、序号不增）。
  int droppedEvents = 0;

  SessionPhase get phase => _state.phase;
  Stream<SessionPhase> get phases => _phases.stream;
  Stream<Uint8List> get output => _output.stream;

  @override
  SessionKind get ref => TerminalSessionRef(handle, providerId, _state);

  Future<void> write(Uint8List bytes) {
    if (phase != SessionPhase.active && phase != SessionPhase.opening) {
      throw StateError('会话已结束');
    }
    return _manager._bridge
        .writeSession(packageName, handle, generation, bytes);
  }

  Future<void> resize(int cols, int rows) {
    if (phase != SessionPhase.active) throw StateError('会话不在运行');
    return _manager._bridge.resizeSession(
      packageName,
      handle,
      generation,
      cols,
      rows,
    );
  }

  Future<Map<String, Object?>?> stats() =>
      _manager._bridge.sessionStats(packageName, handle, generation);

  /// 幂等：第二次调用等第一次的结果。
  @override
  Future<void> close() {
    final existing = _closing;
    if (existing != null) return existing.future;
    final done = _closing = Completer<void>();
    if (phase.isTerminal) {
      done.complete();
      return done.future;
    }
    _move(SessionPhase.closing);
    unawaited(() async {
      try {
        await _manager._bridge.closeSession(packageName, handle, generation);
      } on PluginBridgeException {
        // 连接已断：宿主这端本来就没了，照样按「未确认」收尾。
      }
      await Future.any([
        phases.firstWhere((p) => p.isTerminal),
        Future<void>.delayed(closeConfirmWindow),
      ]);
      if (!phase.isTerminal) {
        stopConfirmed = false;
        _finish(SessionPhase.closed);
      }
      done.complete();
    }());
    return done.future;
  }

  void _flushAcks() {
    while (_pendingAcks > 0 && _output.hasListener && !_output.isPaused) {
      _pendingAcks--;
      unawaited(_manager._ack(this));
    }
  }

  void _onData(Uint8List bytes) {
    if (phase.isTerminal) return;
    _output.add(bytes);
    _pendingAcks++;
    _flushAcks();
  }

  void _onPluginState(int sequence, String state) {
    final before = _state;
    if (state == 'closed') {
      // 插件确认停止：宿主发起的关闭得到确认；插件自己结束也按正常关闭收尾。
      if (phase.isTerminal) return;
      _state = _state.apply(generation, sequence, _state.phase);
      if (identical(before, _state)) {
        droppedEvents++;
        return;
      }
      if (phase == SessionPhase.closing) stopConfirmed = true;
      _finish(SessionPhase.closed);
      return;
    }
    if (phase.isTerminal || phase == SessionPhase.closing) {
      droppedEvents++; // 迟到的 active 等：不复活
      return;
    }
    final next = state == 'active' ? SessionPhase.active : phase;
    _state = _state.apply(generation, sequence, next);
    if (identical(before, _state)) {
      droppedEvents++;
      return;
    }
    if (state.startsWith('resized:')) lastResize = state.substring(8);
    if (next != before.phase) _phases.add(next);
  }

  /// 插件关了它那一端（没经过 close）：插件进程还在就是中断，不在了就是插件死亡。
  void _onEof({bool? providerAlive}) {
    if (phase == SessionPhase.closing) return; // 我们在关，EOF 是预期内的
    if (phase.isTerminal) return;
    _finish(
      providerAlive == false
          ? SessionPhase.providerDied
          : SessionPhase.interrupted,
    );
  }

  /// 宿主断开了整个插件连接（撤销、停用、插件进程死亡）。
  void _onConnectionClosed(String? cause) {
    if (phase.isTerminal) return;
    if (phase == SessionPhase.closing) {
      stopConfirmed ??= false;
      _finish(SessionPhase.closed);
      return;
    }
    _finish(
      cause == 'providerDied'
          ? SessionPhase.providerDied
          : SessionPhase.permissionRevoked,
    );
  }

  void _move(SessionPhase phase) {
    _state = SessionState(generation, _state.sequence, phase);
    _phases.add(phase);
  }

  void _finish(SessionPhase phase) {
    _move(phase);
    _manager._forget(this);
    unawaited(_output.close());
  }
}

/// 打开插件会话，并把桥上的字节和事件按句柄分给各个会话。
class PluginSessionManager {
  PluginSessionManager(this._bridge, this._registry) {
    _subscriptions
      ..add(_bridge.sessionData.listen(_routeData))
      ..add(_bridge.sessionEvents.listen(_routeEvent));
  }

  final AndroidPluginBridge _bridge;
  final PluginRegistry _registry;
  final _sessions = <String, PluginTerminalSession>{};
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// 本进程内单调递增的代次。插件据此拒绝旧代次的调用。
  var _generation = 0;

  List<PluginTerminalSession> get sessions =>
      List.unmodifiable(_sessions.values);

  /// provider 必须是 Ready 且声明了 terminal-session，否则在这里就抛错，不去碰插件。
  /// 调用方要先 [PluginDiscovery.check]/connect 过这个插件（连接由桥维护）。
  Future<PluginTerminalSession> open(
    PluginEntry entry, {
    int cols = 80,
    int rows = 24,
  }) async {
    final id = entry.pluginId;
    final package = entry.packageName;
    if (id == null || package == null) {
      const reason = '不是已安装的插件';
      throw PluginUnavailable(package ?? '?', null, reason);
    }
    _registry.require(id, Capability.terminalSession);
    final session = PluginTerminalSession._(
      this,
      package,
      id,
      const Uuid().v4(),
      ++_generation,
    );
    _sessions[session.handle] = session;
    try {
      await _bridge.openSession(
        packageName: package,
        handle: session.handle,
        generation: session.generation,
        cols: cols,
        rows: rows,
      );
    } on Object {
      _sessions.remove(session.handle);
      session._finish(SessionPhase.closed);
      rethrow;
    }
    // 挂到注册表上：撤销、停用、换签、卸载时由注册表负责关掉它。
    _registry.attachSession(session);
    return session;
  }

  Future<void> _ack(PluginTerminalSession s) async {
    try {
      await _bridge.ackSession(s.packageName, s.handle, s.generation);
    } on PluginBridgeException {
      // 会话已关
    }
  }

  void _forget(PluginTerminalSession session) {
    if (identical(_sessions[session.handle], session)) {
      _sessions.remove(session.handle);
    }
    _registry.detachSession(session);
  }

  PluginTerminalSession? _find(
      String package, String? handle, int? generation) {
    final session = _sessions[handle];
    if (session == null ||
        session.packageName != package ||
        session.generation != generation) {
      return null;
    }
    return session;
  }

  void _routeData(SessionDataEvent e) =>
      _find(e.packageName, e.handle, e.generation)?._onData(e.bytes);

  void _routeEvent(SessionBridgeEvent e) {
    if (e.type == 'droppedEvent') {
      final session = _sessions[e.handle];
      if (session != null && session.packageName == e.packageName) {
        session.droppedEvents++;
      }
      return;
    }
    final session = _find(e.packageName, e.handle, e.generation);
    if (session == null) return;
    switch (e.type) {
      case 'sessionEvent':
        session._onPluginState(e.sequence ?? 0, e.state ?? '');
      case 'sessionEof':
        session._onEof(providerAlive: e.providerAlive);
      case 'sessionClosed':
        session._onConnectionClosed(e.cause);
    }
  }

  void dispose() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    for (final session in [..._sessions.values]) {
      unawaited(session.close());
    }
  }
}

final pluginSessionManagerProvider = Provider<PluginSessionManager>((ref) {
  final manager = PluginSessionManager(
    ref.watch(androidPluginBridgeProvider),
    ref.read(pluginRegistryProvider.notifier),
  );
  ref.onDispose(manager.dispose);
  return manager;
});
