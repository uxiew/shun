import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../domain/connection_route.dart';
import '../domain/models/host.dart';
import '../domain/terminal_paste.dart';
import '../domain/tmux/tmux_target.dart';
import '../infrastructure/ssh/ssh_login_watch.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/ssh/server_monitor_service.dart';
import '../infrastructure/terminal/terminal_session_adapter.dart';
import '../infrastructure/tmux/tmux_protocol.dart';
import '../infrastructure/tmux/tmux_service.dart';
import 'credential_availability.dart';
import 'mosh_session.dart';
import 'terminal_engine.dart';
import 'vault_controller.dart';

enum PendingConnectionPhase { connecting, failed }

class PendingTerminalConnection {
  const PendingTerminalConnection({
    required this.id,
    required this.host,
    this.phase = PendingConnectionPhase.connecting,
    this.error,
    this.stage,
    this.routePlan,
    this.checkPrompt,
  });

  static const _keep = Object();

  final String id;
  final HostProfile host;
  final PendingConnectionPhase phase;
  final Object? error;

  /// 连到哪一步了；还没开始拨号时为 null。
  final ConnectionStage? stage;

  /// 这次连接实际走的路线；路线配置本身有错、还没算出来时为 null。失败页据此显示实际路径（UX04）。
  final RoutePlan? routePlan;

  /// 正在等用户处理的 Tailscale check；没有时为 null。连接结束（成功、失败、取消）就清掉。
  final TailscaleCheckPrompt? checkPrompt;

  PendingTerminalConnection copyWith({
    PendingConnectionPhase? phase,
    Object? error,
    ConnectionStage? stage,
    RoutePlan? routePlan,
    Object? checkPrompt = _keep,
  }) =>
      PendingTerminalConnection(
        id: id,
        host: host,
        phase: phase ?? this.phase,
        error: error ?? this.error,
        stage: stage ?? this.stage,
        routePlan: routePlan ?? this.routePlan,
        checkPrompt: identical(checkPrompt, _keep)
            ? this.checkPrompt
            : checkPrompt as TailscaleCheckPrompt?,
      );
}

class SessionState {
  const SessionState({
    this.sessions = const [],
    this.activeIndex = 0,
    this.pendingConnections = const [],
    this.activePendingId,
    this.error,
  });

  static const _notProvided = Object();

  final List<ActiveTerminalSession> sessions;
  final int activeIndex;
  final List<PendingTerminalConnection> pendingConnections;
  final String? activePendingId;
  final Object? error;

  ActiveTerminalSession? get active => sessions.isEmpty
      ? null
      : sessions[activeIndex.clamp(0, sessions.length - 1)];

  PendingTerminalConnection? get selectedPending {
    for (final pending in pendingConnections) {
      if (pending.id == activePendingId) return pending;
    }
    return null;
  }

  int get tabCount => sessions.length + pendingConnections.length;

  SessionState copyWith({
    List<ActiveTerminalSession>? sessions,
    int? activeIndex,
    List<PendingTerminalConnection>? pendingConnections,
    Object? activePendingId = _notProvided,
    Object? error = _notProvided,
  }) =>
      SessionState(
        sessions: sessions ?? this.sessions,
        activeIndex: activeIndex ?? this.activeIndex,
        pendingConnections: pendingConnections ?? this.pendingConnections,
        activePendingId: identical(activePendingId, _notProvided)
            ? this.activePendingId
            : activePendingId as String?,
        error: identical(error, _notProvided) ? this.error : error,
      );
}

final sshServiceProvider = Provider((ref) => SshService());

final sessionControllerProvider =
    StateNotifierProvider<SessionController, SessionState>(
  (ref) => SessionController(
    ref.watch(sshServiceProvider),
    ref.watch(vaultControllerProvider.notifier),
    ref,
    newTerminal: ref.watch(terminalAdapterFactoryProvider),
  ),
);

class SessionController extends StateNotifier<SessionState> {
  SessionController(
    this.service,
    this.vaultController,
    this.ref, {
    TerminalAdapterFactory? newTerminal,
  })  : newTerminal = newTerminal ?? defaultTerminalAdapter,
        super(const SessionState());

  final SshService service;
  final VaultController vaultController;
  final Ref ref;

  /// 新标签用的终端。终端归标签：这里创建，标签关掉（或新开的连接没进标签）时这里销毁；
  /// 断线恢复沿用原来那个。连接层和页面都不创建、不销毁终端（R16，GST02）。
  final TerminalAdapterFactory newTerminal;
  bool _reconnecting = false;
  bool _backgrounded = false;
  bool _backgroundMaintenanceRunning = false;
  Timer? _backgroundMaintenanceTimer;
  DateTime? _nextBackgroundReconnect;
  int _backgroundReconnectAttempt = 0;

  /// 每个标签（按 id）正在进行的连接尝试，新开或恢复，最多一个；结束就移除。
  ///
  /// 这是「代次」的唯一真相：一个结果只有在它的尝试仍是这里登记的那一个、且没被取消时才算数，
  /// 否则一律关掉。取消、关标签、controller 销毁都会让尝试失效，迟到的成功不能复活连接（NET09）。
  final _attempts = <String, ConnectionAttempt>{};
  var _generation = 0;

  static const _backgroundMaintenanceInterval = Duration(seconds: 8);
  static const _backgroundReconnectDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  ConnectionAttempt _beginAttempt(String tabId) {
    _attempts.remove(tabId)?.cancel();
    final attempt = ConnectionAttempt(generation: ++_generation);
    _attempts[tabId] = attempt;
    return attempt;
  }

  /// 这次尝试的结果还算不算数。
  bool _isCurrent(String tabId, ConnectionAttempt attempt) =>
      mounted && !attempt.isCancelled && identical(_attempts[tabId], attempt);

  void _endAttempt(String tabId, ConnectionAttempt attempt) {
    if (identical(_attempts[tabId], attempt)) _attempts.remove(tabId);
  }

  bool _owns(ActiveTerminalSession session) =>
      state.sessions.any((value) => identical(value, session));

  /// 新开一个终端连接。返回 true 表示连接已进标签；被取消、或结果迟到被关掉时返回 false。
  /// 调用方只有拿到 true 才能说「已连接」——以前取消后也正常返回，界面照样弹「已连接」。
  ///
  /// [routePlan] 给了就沿用这条冻结的路线（附着 tmux 的新标签用来源标签的路线，保证还是同一台主机、同一套身份），
  /// 不再按保险库现算。[tmuxAttach] 给了就不开 shell，而是附着这个 tmux 目标（R21）。
  Future<bool> connect(
    HostProfile host,
    HostKeyVerifier verifyHostKey, {
    KeyboardInteractiveHandler? keyboardInteractive,
    RoutePlan? routePlan,
    TmuxTarget? tmuxAttach,
  }) async {
    final sessionId = const Uuid().v4();
    final attempt = _beginAttempt(sessionId);
    attempt.onStage = (stage) {
      if (!mounted) return;
      state = state.copyWith(
        pendingConnections: [
          for (final value in state.pendingConnections)
            value.id == sessionId ? value.copyWith(stage: stage) : value,
        ],
      );
    };
    attempt.onCheckPrompt = (prompt) {
      if (!mounted) return;
      state = state.copyWith(
        pendingConnections: [
          for (final value in state.pendingConnections)
            value.id == sessionId ? value.copyWith(checkPrompt: prompt) : value,
        ],
      );
    };
    final pending = PendingTerminalConnection(id: sessionId, host: host);
    state = state.copyWith(
      pendingConnections: [...state.pendingConnections, pending],
      activePendingId: sessionId,
      error: null,
    );
    TerminalSessionAdapter? terminal;
    var handedOver = false;
    try {
      // 终端先建：引擎（Ghostty 的原生库）建不起来时连接照常失败，失败页写清是哪个引擎，
      // 不先拨号再发现没地方显示，也不换成别的引擎凑合。
      terminal = newTerminal();
      final vault = await vaultController.ready();
      // 等保险库解锁时用户可能已经点了终止：此时一个连接都还没拨，直接放弃。
      attempt.throwIfCancelled();
      final connectionHost = host.data['_ephemeralTerminal'] == true
          ? host
          : vault.hosts.firstWhere(
              (value) => value.id == host.id,
              orElse: () => host,
            );
      // 路线在这里一次算好：配置有错此时就报，算好的路线存进等待卡片，失败页据此显示实际路径。
      final plan = routePlan ??
          resolveRoutePlan(
            connectionHost,
            hosts: vault.hosts,
            proxyProfiles: vault.proxyProfiles,
            keys: vault.keys,
          );
      if (mounted) {
        state = state.copyWith(
          pendingConnections: [
            for (final value in state.pendingConnections)
              value.id == sessionId ? value.copyWith(routePlan: plan) : value,
          ],
        );
      }
      // 要用的凭据解不开就在拨号前拒绝，不拿空密码去试（SEC06）。冻结的路线自带建连时的凭据副本，不再查保险库。
      final problem = routePlan != null
          ? null
          : unreadableCredentialProblem(
              connectionHost,
              vault,
              vaultController.repository.unreadableSecrets,
            );
      if (problem != null) throw CredentialUnavailableException(problem);
      // Mosh 主机：SSH 只用来启动 mosh-server，会话由插件经 UDP 承载（X09）。路线不是直连在这里面第一步就拒绝。
      final session = connectionHost.protocol == HostProtocol.mosh
          ? await MoshBootstrapCoordinator(service, ref.read(moshRuntimeProvider))
              .connect(
              sessionId: sessionId,
              host: connectionHost,
              plan: plan,
              verifyHostKey: verifyHostKey,
              keyboardInteractive: keyboardInteractive,
              terminal: terminal,
              attempt: attempt,
            )
          : await service.connect(
              sessionId: sessionId,
              host: connectionHost,
              routePlan: plan,
              verifyHostKey: verifyHostKey,
              keyboardInteractive: keyboardInteractive,
              terminal: terminal,
              attempt: attempt,
              tmuxAttach: tmuxAttach,
            );
      if (!_isCurrent(sessionId, attempt)) {
        // 迟到的成功：尝试已被取消或 controller 已销毁。连接此刻归这里，立刻关掉，不进标签。
        _endAttempt(sessionId, attempt);
        await session.close();
        return false;
      }
      _endAttempt(sessionId, attempt);
      handedOver = true;
      final sessions = [...state.sessions, session];
      final wasSelected = state.activePendingId == sessionId;
      state = state.copyWith(
        sessions: sessions,
        activeIndex: wasSelected ? sessions.length - 1 : state.activeIndex,
        pendingConnections: state.pendingConnections
            .where((value) => value.id != sessionId)
            .toList(growable: false),
        activePendingId: wasSelected ? null : state.activePendingId,
        error: null,
      );
      _watchSession(session);
      _ensureBackgroundMaintenance();
      if (connectionHost.data['_ephemeralTerminal'] == true) {
        session.systemInfo = connectionHost.systemInfo;
      } else {
        unawaited(vaultController.markConnected(connectionHost));
        unawaited(_detectSystem(session, connectionHost));
      }
      return true;
    } catch (error) {
      final stale = !_isCurrent(sessionId, attempt);
      _endAttempt(sessionId, attempt);
      if (!mounted) return false;
      if (stale || error is ConnectionCancelledException) {
        state = state.copyWith(
          pendingConnections: state.pendingConnections
              .where((value) => value.id != sessionId)
              .toList(growable: false),
          activePendingId:
              state.activePendingId == sessionId ? null : state.activePendingId,
          error: null,
        );
        return false;
      }
      state = state.copyWith(
        pendingConnections: state.pendingConnections
            .map(
              (value) => value.id == sessionId
                  ? value.copyWith(
                      phase: PendingConnectionPhase.failed,
                      error: error,
                      checkPrompt: null,
                    )
                  : value,
            )
            .toList(growable: false),
        error: error,
      );
      rethrow;
    } finally {
      // 没进标签的终端（失败、取消、迟到的成功）没有别人会用，就地释放。
      if (!handedOver) terminal?.dispose();
    }
  }

  Future<bool> openManagedTerminal(
    ActiveTerminalSession parent, {
    required String label,
    required String command,
  }) {
    final host = HostProfile({
      ...parent.host.data,
      'id': 'managed-${const Uuid().v4()}',
      'label': label,
      'startupCommand': command,
      '_ephemeralTerminal': true,
    });
    return connect(
      host,
      parent.verifyHostKey,
      keyboardInteractive: parent.keyboardInteractive,
    );
  }

  /// 在新标签里附着一个 tmux 目标（R21）。只附着这个确定的目标：远端先核对它还在、还是同一个，
  /// 不在就失败（等待卡片写明原因），不按名字找替身、不新建。不带 -d，不踢掉别的客户端。
  ///
  /// 用来源标签冻结的路线连过去：目标是在那条连接上查到的，换条路线可能到了另一台机器。
  Future<bool> openTmuxTerminal(
    ActiveTerminalSession parent,
    TmuxTarget target,
  ) {
    if (target.hostKey != tmuxHostKeyOf(parent)) {
      throw StateError('这个 tmux 目标不是在这台主机上查到的');
    }
    final data = {...parent.host.data}..remove('startupCommand');
    final host = HostProfile({
      ...data,
      'id': 'tmux-${const Uuid().v4()}',
      'label': 'tmux: ${target.displayName}',
      '_ephemeralTerminal': true,
    });
    return connect(
      host,
      parent.verifyHostKey,
      keyboardInteractive: parent.keyboardInteractive,
      routePlan: parent.routePlan,
      tmuxAttach: target,
    );
  }

  Future<void> reconnectDisconnected() async {
    if (_reconnecting ||
        state.pendingConnections.any(
          (value) => value.phase == PendingConnectionPhase.connecting,
        )) {
      return;
    }
    _reconnecting = true;
    try {
      for (final old in [...state.sessions]) {
        if (!mounted) break;
        if (old.connected ||
            old.closedByUser ||
            old.autoRestoreBlocked ||
            old.plugin != null ||
            !_owns(old)) {
          continue;
        }
        final attempt = _beginAttempt(old.id);
        try {
          // 沿用这个标签建连时冻结的路线：自动恢复只走同一条路线、同一套身份，
          // 期间改过的主机、跳板、代理配置只对新开的连接生效（NET10，docs/07）。
          final plan = old.routePlan;
          final vault = plan == null ? await vaultController.ready() : null;
          attempt.throwIfCancelled();
          old.terminal.showNotice('\r\n\x1b[33m正在恢复连接…\x1b[0m\r\n');
          final replacement = await service.connect(
            sessionId: old.id,
            host: old.host,
            routePlan: plan,
            hosts: vault?.hosts ?? const [],
            keys: vault?.keys ?? const [],
            proxyProfiles: vault?.proxyProfiles ?? const [],
            verifyHostKey: old.verifyHostKey,
            keyboardInteractive: old.keyboardInteractive,
            terminal: old.terminal,
            // 恢复只重建连接，不替用户再执行命令：托管终端的 startupCommand 就是那条
            // 管理命令（比如重启服务），断线重连时重跑会造成真实副作用（REG02）。
            purpose: ConnectionPurpose.restore,
            attempt: attempt,
            // tmux 标签只重新附着原来那个目标，远端核对不过就失败，不新建（TMX04/TMX05）。
            tmuxAttach: old.tmux?.target,
          );
          if (!_isCurrent(old.id, attempt) || !_owns(old)) {
            // 恢复期间标签被关、这次恢复被取消或 controller 已销毁：
            // 新连接不能顶替进去，立刻关掉。
            _endAttempt(old.id, attempt);
            await replacement.close();
            continue;
          }
          _endAttempt(old.id, attempt);
          final current =
              state.sessions.indexWhere((value) => identical(value, old));
          // 旧连接这一代到此为止：断开它的输出（两者共用一个 terminal），网络资源确保释放。
          old.detachOutput();
          old.abort();
          if (old.host.startupCommand?.isNotEmpty == true) {
            old.terminal.showNotice(
              '\x1b[33m已恢复为新的 shell，启动命令不会在恢复时重新执行。\x1b[0m\r\n',
            );
          }
          final sessions = [...state.sessions];
          sessions[current] = replacement;
          state = state.copyWith(
            sessions: sessions,
            activeIndex: state.activeIndex.clamp(0, sessions.length - 1),
            error: null,
          );
          _watchSession(replacement);
          _backgroundReconnectAttempt = 0;
          _nextBackgroundReconnect = null;
          unawaited(_detectSystem(replacement, old.host));
        } catch (error) {
          final stale = !_isCurrent(old.id, attempt) || !_owns(old);
          _endAttempt(old.id, attempt);
          if (stale || error is ConnectionCancelledException) continue;
          if (error is RouteHopException &&
              error.cause is TailscaleCheckNeedsUser) {
            // 后台每隔几秒重试一次的话，每次都会让 Tailscale 再生成一条 check 请求。停在这里等用户。
            old.autoRestoreBlocked = true;
          }
          if (error is TmuxTargetGoneException ||
              (error is TmuxCommandException &&
                  error.exitCode == TmuxExit.missing)) {
            // 原来的 tmux 目标不在了：再试也一样，停下等用户在面板里自己选（TMX04/TMX05）。
            old.autoRestoreBlocked = true;
          }
          old.terminal.showNotice('\r\n\x1b[31m恢复连接失败：$error\x1b[0m\r\n');
          state = state.copyWith(error: error);
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  void _watchSession(ActiveTerminalSession session) {
    if (session.isSsh) {
      session.monitor ??= SessionMonitor(session);
      session.monitor!.start();
    }
    unawaited(session.done.then((_) {
      _markDisconnected(session);
    }));
  }

  void setBackgrounded(bool backgrounded) {
    if (_backgrounded == backgrounded) return;
    _backgrounded = backgrounded;
    if (backgrounded) {
      // 快捷键栏按下的 Ctrl/Alt 只管下一次输入；切到后台再回来还亮着，用户早忘了，
      // 下一个字就成了控制键（TER04）。
      for (final session in state.sessions) {
        session.terminal.input.clearModifiers();
      }
      _ensureBackgroundMaintenance();
      unawaited(_maintainBackgroundConnections());
      return;
    }
    _backgroundMaintenanceTimer?.cancel();
    _backgroundMaintenanceTimer = null;
    _backgroundReconnectAttempt = 0;
    _nextBackgroundReconnect = null;
    unawaited(reconnectDisconnected());
  }

  void _ensureBackgroundMaintenance() {
    if (!_backgrounded || state.sessions.isEmpty) return;
    _backgroundMaintenanceTimer ??= Timer.periodic(
      _backgroundMaintenanceInterval,
      (_) => unawaited(_maintainBackgroundConnections()),
    );
  }

  Future<void> _maintainBackgroundConnections() async {
    if (!_backgrounded || _backgroundMaintenanceRunning || !mounted) return;
    _backgroundMaintenanceRunning = true;
    try {
      for (final session in [...state.sessions]) {
        if (!session.connected || session.closedByUser) continue;
        try {
          await session.ping();
        } on Object {
          _markDisconnected(session);
          session.abort();
        }
      }
      if (!mounted) return;
      if (!state.sessions.any(_waitingForRestore)) {
        _backgroundReconnectAttempt = 0;
        _nextBackgroundReconnect = null;
        return;
      }
      final now = DateTime.now();
      final next = _nextBackgroundReconnect;
      if (next != null && now.isBefore(next)) return;
      await reconnectDisconnected();
      if (!mounted) return;
      if (state.sessions.any(_waitingForRestore)) {
        final delay =
            _backgroundReconnectDelays[_backgroundReconnectAttempt.clamp(
          0,
          _backgroundReconnectDelays.length - 1,
        )];
        _backgroundReconnectAttempt++;
        _nextBackgroundReconnect = DateTime.now().add(delay);
      } else {
        _backgroundReconnectAttempt = 0;
        _nextBackgroundReconnect = null;
      }
    } finally {
      _backgroundMaintenanceRunning = false;
    }
  }

  static bool _waitingForRestore(ActiveTerminalSession session) =>
      !session.connected &&
      !session.closedByUser &&
      !session.autoRestoreBlocked;

  void _markDisconnected(ActiveTerminalSession session) {
    session.monitor?.stop();
    if (session.closedByUser || !session.connected) return;
    if (!mounted || !_owns(session)) {
      // 已被替换或已不在标签里的旧连接迟到的断开事件：只释放它自己，不碰界面状态。
      session.abort();
      return;
    }
    if (session.plugin case final plugin?) {
      // Mosh 会话结束了就是结束了，不自动重连：重连等于在服务器上再起一个 mosh-server、开一个新 shell，
      // 冒充不了原来那个会话（docs/16 第 6 步）；断开前的输入也不重发。要不要再连由用户决定。
      session.autoRestoreBlocked = true;
      session.abort();
      session.terminal.showNotice(plugin.endNotice ?? '');
      if (!mounted) return;
      state = state.copyWith(sessions: [...state.sessions]);
      return;
    }
    final tmux = session.tmux;
    final ssh = session.sshSession;
    if (tmux != null &&
        ssh != null &&
        (ssh.exitCode != null || ssh.exitSignal != null)) {
      // tmux 客户端自己退出了（分离、会话结束、server 退出）：这不是断线，不自动重新附着。
      // tmux 会话本身（如果还在）不受影响；要回去由用户在面板里明确再附着一次。
      session.autoRestoreBlocked = true;
      session.abort();
      session.terminal.showNotice(
        '\r\n\x1b[33mtmux 客户端已退出（分离了，或会话已结束）。不会自动重新附着；'
        '如果会话 ${tmux.target.sessionId} 还在，可在「系统管理 → tmux」里重新附着。\x1b[0m\r\n',
      );
      if (!mounted) return;
      state = state.copyWith(sessions: [...state.sessions]);
      return;
    }
    // 断了就把这一代的网络资源全部释放。shell 通道结束（比如输入了 exit）时，
    // 目标和各跳板的 SSH 连接可能还开着；不关的话每次断线恢复都会多留一整条链路（LIFE06）。
    // 借用这条连接的 SFTP、转发随之失效，不会被悄悄改走别的路线（docs/03）。
    session.abort();
    session.terminal.showNotice(
      _backgrounded
          ? '\r\n\x1b[33m连接已断开，正在后台自动恢复…\x1b[0m\r\n'
          : '\r\n\x1b[33m连接已断开，返回前台后将自动重连。\x1b[0m\r\n',
    );
    if (!mounted) return;
    state = state.copyWith(sessions: [...state.sessions]);
    _ensureBackgroundMaintenance();
    if (_backgrounded) unawaited(_maintainBackgroundConnections());
  }

  Future<void> _detectSystem(
    ActiveTerminalSession session,
    HostProfile host,
  ) async {
    if (!session.isSsh) return;
    if (host.data['_ephemeralTerminal'] == true) {
      session.systemInfo = host.systemInfo;
      return;
    }
    try {
      final info = await ServerMonitorService().detect(session);
      session.systemInfo = info;
      // 只补这三个字段，写到保险库里此刻的那份主机上。以前拿连接开始时的整份快照写回，
      // 连接期间用户改的地址、账号、代理会被悄悄改回去，删掉的主机也会被加回来（NET10）。
      await vaultController.patchHost(host.id, {
        'os': info.platform,
        'distro': info.distro,
        'systemInfo': info.toJson(),
      });
      if (!mounted) return;
      state = state.copyWith(
        sessions: [...state.sessions],
      );
    } on Object {
      // Detection is best effort and must never interrupt an SSH session.
    }
  }

  void activate(int index) {
    if (index < 0 || index >= state.tabCount) return;
    if (index < state.sessions.length) {
      state = state.copyWith(activeIndex: index, activePendingId: null);
      return;
    }
    final pending = state.pendingConnections[index - state.sessions.length];
    state = state.copyWith(activePendingId: pending.id);
  }

  void dismissPending(String id) {
    final pending =
        state.pendingConnections.where((value) => value.id == id).firstOrNull;
    if (pending == null || pending.phase == PendingConnectionPhase.connecting) {
      return;
    }
    state = state.copyWith(
      pendingConnections: state.pendingConnections
          .where((value) => value.id != id)
          .toList(growable: false),
      activePendingId:
          state.activePendingId == id ? null : state.activePendingId,
      error: null,
    );
  }

  void cancelPendingConnection(String id) {
    final exists = state.pendingConnections.any(
      (value) =>
          value.id == id && value.phase == PendingConnectionPhase.connecting,
    );
    if (!exists) return;
    // 先让这次尝试失效并关掉已建好的 socket / client，再改界面（docs/07：先失效代次再释放）。
    _attempts.remove(id)?.cancel();
    state = state.copyWith(
      pendingConnections: state.pendingConnections
          .where((value) => value.id != id)
          .toList(growable: false),
      activePendingId:
          state.activePendingId == id ? null : state.activePendingId,
      error: null,
    );
  }

  void reorderSessionTab(int oldIndex, int newIndex) {
    final sessions = [...state.sessions];
    if (oldIndex < 0 || oldIndex >= sessions.length) return;
    final activeId = state.active?.id;
    final insertionIndex = newIndex.clamp(0, sessions.length - 1);
    if (insertionIndex == oldIndex) return;
    final moved = sessions.removeAt(oldIndex);
    sessions.insert(insertionIndex, moved);
    final activeIndex = activeId == null
        ? 0
        : sessions.indexWhere((session) => session.id == activeId);
    state = state.copyWith(
      sessions: sessions,
      activeIndex: activeIndex < 0 ? 0 : activeIndex,
    );
  }

  Future<void> close(int index) async {
    if (index < 0 || index >= state.sessions.length) return;
    final sessions = [...state.sessions];
    final removed = sessions.removeAt(index);
    // 顺序：先让这个标签正在进行的恢复失效，再从界面移除，最后释放资源。
    // 以前先 await 关闭再写回之前拍的 sessions 快照，期间新连上的标签会被这份旧快照抹掉（且连接不关）；
    // 恢复中关标签，恢复出来的新连接也没人关。
    _attempts.remove(removed.id)?.cancel();
    var activeIndex = state.activeIndex;
    if (index < activeIndex) {
      activeIndex--;
    } else if (index == activeIndex && activeIndex >= sessions.length) {
      activeIndex = sessions.length - 1;
    }
    state = state.copyWith(
      sessions: sessions,
      activeIndex:
          sessions.isEmpty ? 0 : activeIndex.clamp(0, sessions.length - 1),
    );
    if (sessions.isEmpty) {
      _backgroundMaintenanceTimer?.cancel();
      _backgroundMaintenanceTimer = null;
    }
    await removed.close();
    removed.terminal.dispose();
  }

  /// 命令片段发到当前标签（R19）。按粘贴发，不按打字发：多行片段在远端开着 bracketed paste 时
  /// 不会逐行执行；末尾的换行和控制字符先去掉（同粘贴预览，见 [PasteReview]），回车只看片段的
  /// 「自动运行」[enter]。目标断开时抛 [TerminalTargetChangedException]。
  void send(String text, {bool enter = false}) {
    final session = state.active;
    if (session == null) return;
    pasteInto(session, PasteReview.of(text).text, enter: enter);
  }

  /// 快捷键栏的输入：和软键盘打字一样直接交给终端。没连着时终端没有绑定，字就丢掉，
  /// 不像 [sendToSession] 那样抛错（按一下 Esc 不该弹红屏）。
  void typeInto(String sessionId, String text) {
    final session =
        state.sessions.where((value) => value.id == sessionId).firstOrNull;
    session?.terminal.sendText(text);
  }

  /// 快捷键栏的功能键，见 [TerminalSpecialKey]。规矩同 [typeInto]。
  void pressKey(String sessionId, TerminalSpecialKey key) {
    final session =
        state.sessions.where((value) => value.id == sessionId).firstOrNull;
    session?.terminal.sendKey(key);
  }

  void sendToSession(String sessionId, String text, {bool enter = false}) {
    final session =
        state.sessions.where((value) => value.id == sessionId).firstOrNull;
    if (session == null) {
      throw StateError('目标终端会话已关闭');
    }
    if (!session.connected) {
      throw StateError('目标终端连接已断开');
    }
    session.terminal.sendText(enter ? '$text\r' : text);
  }

  /// [target] 现在还能不能收；能收返回 null（R19，SEC10）。
  ///
  /// 认的是用户动手那一刻的连接对象本身，不是标签 id：期间标签被关、连接断了，
  /// 或者断线恢复换成了一条新连接（同一个标签、新的 shell），都算目标变了。
  TerminalTargetProblem? targetProblem(ActiveTerminalSession target) {
    final current =
        state.sessions.where((value) => value.id == target.id).firstOrNull;
    if (current == null) return TerminalTargetProblem.closed;
    if (!identical(current, target)) return TerminalTargetProblem.replaced;
    if (!target.connected) return TerminalTargetProblem.disconnected;
    return null;
  }

  /// 同一个标签现在那条连着的连接（恢复后的新连接），没有就是 null。粘贴预览里「改发到新连接」用。
  ActiveTerminalSession? liveSessionFor(ActiveTerminalSession target) {
    final current =
        state.sessions.where((value) => value.id == target.id).firstOrNull;
    return current != null && current.connected ? current : null;
  }

  /// 把 [text] 当粘贴发给 [target]（见 [TerminalSessionAdapter.paste]：不套修饰键、按远端的
  /// bracketed paste 包标记，末尾不加回车）。
  ///
  /// 目标变了（见 [targetProblem]）就不发，抛 [TerminalTargetChangedException]：不改发给现在的标签，
  /// 也不等恢复以后补发（TER09「不自动重发」）。[enter] 只在用户明确点了「粘贴并回车」时为 true，
  /// 粘贴完再单独发一个回车。
  void pasteInto(
    ActiveTerminalSession target,
    String text, {
    bool enter = false,
  }) {
    final problem = targetProblem(target);
    if (problem != null) throw TerminalTargetChangedException(problem);
    target.terminal.paste(text);
    if (enter) target.terminal.sendText('\r');
  }

  /// controller 销毁（应用退出、测试结束）时：所有进行中的尝试失效并关掉半成品，
  /// 已建立的连接全部释放。以前只停监控，SSH 连接和跳板连接会一直留着没人管（LIFE06）。
  @override
  void dispose() {
    for (final attempt in _attempts.values.toList()) {
      attempt.cancel();
    }
    _attempts.clear();
    for (final session in state.sessions) {
      unawaited(session.close());
      session.terminal.dispose();
    }
    _backgroundMaintenanceTimer?.cancel();
    super.dispose();
  }
}

/// 粘贴、发送的目标为什么收不到了（R19，SEC10）。
enum TerminalTargetProblem {
  /// 标签关了。
  closed,

  /// 连接断了，还没恢复。
  disconnected,

  /// 断线后恢复成了一条新连接：同一个标签，但已经是新的 shell，原来那条收不到了。
  replaced,
}

class TerminalTargetChangedException implements Exception {
  const TerminalTargetChangedException(this.problem);

  final TerminalTargetProblem problem;

  @override
  String toString() => switch (problem) {
        TerminalTargetProblem.closed => '没有发送：目标标签已经关了',
        TerminalTargetProblem.disconnected => '没有发送：目标连接已断开',
        TerminalTargetProblem.replaced => '没有发送：连接已经恢复成新的 shell，原来那条收不到了',
      };
}
