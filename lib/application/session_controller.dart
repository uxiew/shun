import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../domain/connection_route.dart';
import '../domain/models/host.dart';
import '../domain/terminal_paste.dart';
import '../domain/tmux/tmux_target.dart';
import '../infrastructure/ssh/connection_platform_service.dart';
import '../infrastructure/ssh/ssh_login_watch.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/ssh/server_monitor_service.dart';
import '../infrastructure/terminal/terminal_session_adapter.dart';
import '../infrastructure/tmux/tmux_protocol.dart';
import '../infrastructure/tmux/tmux_service.dart';
import 'connection_lifecycle.dart';
import 'credential_availability.dart';
import 'mosh_session.dart';
import 'plugin_host_session.dart';
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
    this.recovering = const {},
    this.networkAvailable = true,
    this.keepAliveProblem,
  });

  static const _notProvided = Object();

  final List<ActiveTerminalSession> sessions;
  final int activeIndex;
  final List<PendingTerminalConnection> pendingConnections;
  final String? activePendingId;
  final Object? error;

  /// 正在自动恢复的标签（R22）：断线后 2 分钟的窗口里，按退避一次次重试。
  final Set<String> recovering;

  /// 手机现在有没有可用的默认网络。没有时自动恢复先等着，不白白试。
  final bool networkAvailable;

  /// 后台保活服务没开起来的原因；开着或者用不着时为 null。
  final String? keepAliveProblem;

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
    Set<String>? recovering,
    bool? networkAvailable,
    Object? keepAliveProblem = _notProvided,
  }) =>
      SessionState(
        sessions: sessions ?? this.sessions,
        activeIndex: activeIndex ?? this.activeIndex,
        pendingConnections: pendingConnections ?? this.pendingConnections,
        activePendingId: identical(activePendingId, _notProvided)
            ? this.activePendingId
            : activePendingId as String?,
        error: identical(error, _notProvided) ? this.error : error,
        recovering: recovering ?? this.recovering,
        networkAvailable: networkAvailable ?? this.networkAvailable,
        keepAliveProblem: identical(keepAliveProblem, _notProvided)
            ? this.keepAliveProblem
            : keepAliveProblem as String?,
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
    platform: ref.watch(connectionPlatformProvider),
  ),
);

/// 一个标签这一轮自动恢复的账（R22）。
class _Recovery {
  _Recovery(this.startedAt, {this.verifyHostKey, this.keyboardInteractive});

  /// 窗口从这时算起（[recoveryWindow]）。没网络的那段不算：网络回来时重新起算。
  DateTime startedAt;
  int attempts = 0;
  DateTime? nextAt;

  /// 这一轮里遇到过手机锁着。窗口到了时据此说清楚为什么没恢复。
  bool sawLock = false;

  /// 用户点「重新连接」时界面给的指纹核对和键盘交互；放回来的标签没有当时的，只能用这个。
  final HostKeyVerifier? verifyHostKey;
  final KeyboardInteractiveHandler? keyboardInteractive;
}

class SessionController extends StateNotifier<SessionState> {
  SessionController(
    this.service,
    this.vaultController,
    this.ref, {
    TerminalAdapterFactory? newTerminal,
    ConnectionPlatform? platform,
    DateTime Function()? now,
    this.leaseAfter = credentialLease,
  })  : newTerminal = newTerminal ?? newTerminalAdapter,
        _platform = platform ?? NoConnectionPlatform(),
        _now = now ?? DateTime.now,
        super(const SessionState()) {
    _platformEvents = _platform.events.listen(_onPlatformEvent);
    addListener((_) => _onStateChanged(), fireImmediately: false);
    unawaited(_startLifecycle());
  }

  final SshService service;
  final VaultController vaultController;
  final Ref ref;

  /// 新标签用的终端。终端归标签：这里创建，标签关掉（或新开的连接没进标签）时这里销毁；
  /// 断线恢复沿用原来那个。连接层和页面都不创建、不销毁终端（R16，GST02）。
  final TerminalAdapterFactory newTerminal;
  /// 正在跑的那一轮恢复；同一时刻只跑一轮。
  Future<void>? _recoveryPass;
  bool _backgrounded = false;
  bool _pinging = false;

  /// App 在后台时每 8 秒探一次连着的会话：dartssh2 自己的 keepalive 只发不等，半死的连接它发现不了。
  Timer? _pingTimer;

  /// 有标签在自动恢复时每秒看一眼该不该试下一次。息屏后 CPU 睡着它也不走，醒来接着算。
  Timer? _recoveryTimer;

  /// App 进后台满 [leaseAfter] 时清掉各标签的凭据副本（SEC07）。
  Timer? _leaseTimer;

  /// 平时就是 [credentialLease]（10 分钟）；测试改短。
  final Duration leaseAfter;
  final _recoveries = <String, _Recovery>{};

  final ConnectionPlatform _platform;
  final DateTime Function() _now;
  StreamSubscription<ConnectionPlatformEvent>? _platformEvents;
  NetworkStatus _network = NetworkStatus.unknown;

  /// 发给平台的最后一份保活请求；null 表示让它停了（或从没开过）。
  KeepAliveRequest? _keepAliveSent;
  var _keepAliveGeneration = 0;
  Future<void> _keepAliveChain = Future<void>.value();

  /// 上次 App 被结束前开着的标签已经放回来了（或者没有可放的）。放完之前不写，
  /// 不然刚启动时一个新连接就会把上次的清单覆盖掉。
  bool _restoreDone = false;
  RestorableTabsStore? _restorableTabs;

  /// 每个标签（按 id）正在进行的连接尝试，新开或恢复，最多一个；结束就移除。
  ///
  /// 这是「代次」的唯一真相：一个结果只有在它的尝试仍是这里登记的那一个、且没被取消时才算数，
  /// 否则一律关掉。取消、关标签、controller 销毁都会让尝试失效，迟到的成功不能复活连接（NET09）。
  final _attempts = <String, ConnectionAttempt>{};
  var _generation = 0;

  static const _backgroundPingInterval = Duration(seconds: 8);

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
      final ActiveTerminalSession session;
      if (connectionHost.protocol == HostProtocol.plugin) {
        // 插件主机（X12）：插件自己联网，本 App 不算路线、不查凭据（这台主机上本来就不该有凭据交给它）。
        session = await ref.read(pluginHostConnectorProvider).connect(
              sessionId: sessionId,
              host: connectionHost,
              terminal: terminal,
              attempt: attempt,
              verifyHostKey: verifyHostKey,
              keyboardInteractive: keyboardInteractive,
            );
      } else {
        // 路线在这里一次算好：配置有错此时就报，算好的路线存进等待卡片，失败页据此显示实际路径。
        // 沿用来源标签冻结的路线时，那份路线的凭据可能已经清掉了（后台待久了，SEC07）：按保险库补回，
        // 补之前核对路线没变——目标是在那条路线上查到的，换了路线可能到了另一台机器。
        final plan = routePlan != null && routePlan.secretsForgotten
            ? rehydrateRoutePlan(
                routePlan,
                sourceHostId: sourceHostIdOf(connectionHost),
                hosts: vault.hosts,
                proxyProfiles: vault.proxyProfiles,
                keys: vault.keys,
              )
            : routePlan ??
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
        session = connectionHost.protocol == HostProtocol.mosh
            ? await MoshBootstrapCoordinator(
                    service, ref.read(moshRuntimeProvider))
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
      }
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
      if (_backgrounded) {
        session.monitor?.pause();
        _ensurePingTimer();
      }
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
      sourceHostIdKey: sourceHostIdOf(parent.host),
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
      sourceHostIdKey: sourceHostIdOf(parent.host),
    });
    return connect(
      host,
      parent.verifyHostKey,
      keyboardInteractive: parent.keyboardInteractive,
      routePlan: parent.routePlan,
      tmuxAttach: target,
    );
  }

  /// 一轮恢复：等着恢复的标签各试一次，不看退避时间（测试和「重新连接」用；平时由 [_recoveryTimer] 按退避驱动）。
  Future<void> reconnectDisconnected() => _runRecoveries(force: true);

  /// 计时器每秒跑的那一轮：看窗口、退避、锁屏、网络。测试直接调，不用等真的计时器。
  @visibleForTesting
  Future<void> runRecoveryPass() => _runRecoveries();

  /// 用户在断开的标签上点了「重新连接」（R22）。
  ///
  /// 不管自动恢复为什么停（窗口到了、指纹、凭据、从通知断开、上次 App 被结束），都按用户的意思再试一轮；
  /// 试的还是「恢复」：不跑启动命令，tmux 标签只附着原来那个目标、远端核对不过就停（REG02、TMX04）。
  /// 放回来的标签（[ActiveTerminalSession.restored]）按保险库现在的配置连，界面给的 [verifyHostKey] 核对指纹。
  ///
  /// Mosh 和插件会话结束了就是结束了：这里关掉旧标签、按主机重新开一个新会话（新的 shell），不冒充原来那个。
  Future<void> reconnect(
    String sessionId, {
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
  }) async {
    final index = state.sessions.indexWhere((value) => value.id == sessionId);
    if (index < 0) return;
    final session = state.sessions[index];
    if (session.connected || session.closedByUser) return;
    final protocol = session.host.protocol;
    if (session.plugin != null ||
        protocol == HostProtocol.mosh ||
        protocol == HostProtocol.plugin) {
      final vault = await vaultController.ready();
      final source = vault.hosts
          .where((value) => value.id == sourceHostIdOf(session.host))
          .firstOrNull;
      if (!mounted || !_owns(session)) return;
      if (source == null) {
        _hold(
          session,
          const RestoreHold.untilUser('这台主机已经从保险库里删掉了。'),
        );
        return;
      }
      await close(index);
      await connect(
        source,
        verifyHostKey,
        keyboardInteractive: keyboardInteractive,
      );
      return;
    }
    session.restoreHold = null;
    _recoveries[sessionId] = _Recovery(
      _now(),
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
    );
    _publishRecoveries();
    _ensureRecoveryTimer();
    await _runRecoveries(force: true, only: sessionId);
  }

  /// 一轮恢复。已经有一轮在跑时：计时器、网络事件来的（[force] 为 false）直接让开；
  /// 「重新连接」和 [reconnectDisconnected] 等那一轮跑完再跑自己的——断线当场就会自动开始一轮，
  /// 不等的话调用方一返回就去看「连上没有」，看到的是半路的状态。
  Future<void> _runRecoveries({bool force = false, String? only}) async {
    while (_recoveryPass != null) {
      if (!force) return;
      await _recoveryPass;
    }
    if (!mounted ||
        state.pendingConnections.any(
          (value) => value.phase == PendingConnectionPhase.connecting,
        )) {
      return;
    }
    final pass = Completer<void>();
    _recoveryPass = pass.future;
    try {
      // 恢复先等网络：没网时每一次都是白试（LIFE03「不无限重试」）。窗口在网络回来时重新起算。
      if (!_network.available && !force) return;
      bool? locked;
      for (final old in [...state.sessions]) {
        if (!mounted) break;
        if (only != null && old.id != only) continue;
        if (!_waitingForRestore(old) || !_owns(old)) continue;
        if (_attempts.containsKey(old.id)) continue;
        final recovery =
            _recoveries.putIfAbsent(old.id, () => _Recovery(_now()));
        final now = _now();
        if (!force && now.difference(recovery.startedAt) > recoveryWindow) {
          _hold(
            old,
            RestoreHold.untilForeground(
              recovery.sawLock
                  ? '断线时手机锁着，后台没有重新登录。解锁回到 App 会自动恢复，也可以点「重新连接」。'
                  : '断线后 ${recoveryWindow.inMinutes} 分钟内没恢复上，自动恢复停了。回到 App 会再试一轮，也可以点「重新连接」。',
            ),
          );
          continue;
        }
        if (!force &&
            recovery.nextAt != null &&
            now.isBefore(recovery.nextAt!)) {
          continue;
        }
        // 后台、手机锁着：不重新登录，等用户解锁回到 App（所有者 10-08 定的 SEC07 策略）。
        if (_backgrounded) {
          locked ??= await _platform.isDeviceLocked();
          if (!mounted) break;
          if (locked) {
            recovery.sawLock = true;
            _hold(
              old,
              const RestoreHold.untilForeground(
                '断线时手机锁着，后台没有重新登录。解锁回到 App 会自动恢复，也可以点「重新连接」。',
              ),
            );
            continue;
          }
        }
        await _recoverOne(old, recovery);
      }
    } finally {
      _recoveryPass = null;
      pass.complete();
      if (mounted) _publishRecoveries();
    }
  }

  Future<void> _recoverOne(
    ActiveTerminalSession old,
    _Recovery recovery,
  ) async {
    final attempt = _beginAttempt(old.id);
    recovery.attempts++;
    try {
      // 沿用这个标签建连时冻结的路线：自动恢复只走同一条路线、同一套身份，
      // 期间改过的主机、跳板、代理配置只对新开的连接生效（NET10，docs/07）。
      // 凭据副本已经清掉的（后台待久了，SEC07），按保险库补回，补之前核对路线没变。
      var plan = old.routePlan;
      final vault = plan == null || plan.secretsForgotten
          ? await vaultController.ready()
          : null;
      attempt.throwIfCancelled();
      var host = old.host;
      var tmux = old.tmux?.target ?? old.resumeTmux;
      if (plan != null && plan.secretsForgotten) {
        plan = rehydrateRoutePlan(
          plan,
          sourceHostId: sourceHostIdOf(old.host),
          hosts: vault!.hosts,
          proxyProfiles: vault.proxyProfiles,
          keys: vault.keys,
        );
      } else if (old.restored && old.resumeTmux != null) {
        // 放回来的 tmux 标签：按保险库现在的配置算路线，到达的还得是原来那台机器，
        // 否则目标是在别的机器上查到的，不附着（R21 的 hostKey 规则）。
        final source = vault!.hosts
            .where((value) => value.id == sourceHostIdOf(old.host))
            .firstOrNull;
        if (source == null) {
          throw const RouteChangedException('这台主机已经从保险库里删掉了。');
        }
        plan = resolveRoutePlan(
          source,
          hosts: vault.hosts,
          proxyProfiles: vault.proxyProfiles,
          keys: vault.keys,
        );
        if (plan.target.endpoint.authority != old.resumeTmux!.hostKey) {
          throw RouteChangedException(
            '这台主机的地址改过（原来是 ${old.resumeTmux!.hostKey}），上次附着的 tmux 会话在原来那台机器上，没有附着。',
          );
        }
      } else if (old.restored) {
        // 放回来的普通标签：用保险库里这台主机现在的配置。
        host = vault!.hosts
                .where((value) => value.id == sourceHostIdOf(old.host))
                .firstOrNull ??
            (throw const RouteChangedException('这台主机已经从保险库里删掉了。'));
        final problem = unreadableCredentialProblem(
          host,
          vault,
          vaultController.repository.unreadableSecrets,
        );
        if (problem != null) throw CredentialUnavailableException(problem);
        tmux = null;
      }
      old.terminal.showNotice('\r\n\x1b[33m正在恢复连接…\x1b[0m\r\n');
      final replacement = await service.connect(
        sessionId: old.id,
        host: host,
        routePlan: plan,
        hosts: vault?.hosts ?? const [],
        keys: vault?.keys ?? const [],
        proxyProfiles: vault?.proxyProfiles ?? const [],
        verifyHostKey: recovery.verifyHostKey ?? old.verifyHostKey,
        keyboardInteractive:
            recovery.keyboardInteractive ?? old.keyboardInteractive,
        terminal: old.terminal,
        // 恢复只重建连接，不替用户再执行命令：托管终端的 startupCommand 就是那条
        // 管理命令（比如重启服务），断线重连时重跑会造成真实副作用（REG02）。
        purpose: ConnectionPurpose.restore,
        attempt: attempt,
        // tmux 标签只重新附着原来那个目标，远端核对不过就失败，不新建（TMX04/TMX05）。
        tmuxAttach: tmux,
      );
      if (!_isCurrent(old.id, attempt) || !_owns(old)) {
        // 恢复期间标签被关、这次恢复被取消或 controller 已销毁：
        // 新连接不能顶替进去，立刻关掉。
        _endAttempt(old.id, attempt);
        await replacement.close();
        return;
      }
      _endAttempt(old.id, attempt);
      _recoveries.remove(old.id);
      final current =
          state.sessions.indexWhere((value) => identical(value, old));
      // 旧连接这一代到此为止：断开它的输出（两者共用一个 terminal），网络资源确保释放。
      old.detachOutput();
      old.abort();
      if (host.startupCommand?.isNotEmpty == true) {
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
      if (_backgrounded) {
        replacement.monitor?.pause();
      }
      unawaited(_detectSystem(replacement, host));
    } catch (error) {
      final stale = !_isCurrent(old.id, attempt) || !_owns(old);
      _endAttempt(old.id, attempt);
      if (stale || error is ConnectionCancelledException) return;
      final hold = switch (error) {
        // 后台每隔几秒重试一次的话，每次都会让 Tailscale 再生成一条 check 请求。停在这里等用户。
        RouteHopException(cause: TailscaleCheckNeedsUser()) =>
          const RestoreHold.untilUser(
            '这台主机要在浏览器里完成 Tailscale check，自动恢复不替你打开链接。关掉这个标签、从主机列表重新连接，会显示确认链接。',
          ),
        // 原来的 tmux 目标不在了：再试也一样，停下等用户在面板里自己选（TMX04/TMX05）。
        TmuxTargetGoneException() ||
        TmuxCommandException(exitCode: TmuxExit.missing) =>
          RestoreHold.untilUser('原来的 tmux 会话不在了，没有新建也没有附着别的：$error'),
        RouteChangedException(:final message) => RestoreHold.untilUser(message),
        _ when !isTransientConnectionError(error) => holdForError(error),
        _ => null,
      };
      if (hold != null) {
        _hold(old, hold);
      } else {
        final delay = recoveryBackoff[
            (recovery.attempts - 1).clamp(0, recoveryBackoff.length - 1)];
        recovery.nextAt = _now().add(delay);
      }
      old.terminal.showNotice('\r\n\x1b[31m恢复连接失败：$error\x1b[0m\r\n');
      state = state.copyWith(error: error);
    }
  }

  /// 停下这个标签的自动恢复，写明原因。
  void _hold(ActiveTerminalSession session, RestoreHold hold) {
    session.restoreHold = hold;
    _recoveries.remove(session.id);
    if (!mounted) return;
    state = state.copyWith(sessions: [...state.sessions]);
    _publishRecoveries();
  }

  void _publishRecoveries() {
    if (!mounted) return;
    final ids = {
      for (final session in state.sessions)
        if (_recoveries.containsKey(session.id) && _waitingForRestore(session))
          session.id,
    };
    _recoveries.removeWhere(
      (id, _) => !state.sessions.any((value) => value.id == id),
    );
    if (ids.length != state.recovering.length ||
        !ids.containsAll(state.recovering)) {
      state = state.copyWith(recovering: ids);
    }
    if (_recoveries.isEmpty) {
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
    }
  }

  void _ensureRecoveryTimer() {
    if (_recoveries.isEmpty || !mounted) return;
    _recoveryTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_runRecoveries()),
    );
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
        session.monitor?.pause();
      }
      _leaseTimer?.cancel();
      _leaseTimer = Timer(leaseAfter, _forgetCredentials);
      _ensurePingTimer();
      unawaited(_pingConnections());
      return;
    }
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    final now = _now();
    for (final session in state.sessions) {
      if (session.connected) session.monitor?.resume();
      // 回到前台：人在、手机已解锁。等着「回前台再恢复」的标签再给一轮。
      if (session.restoreHold?.kind == RestoreHoldKind.untilForeground) {
        session.restoreHold = null;
        _recoveries[session.id] = _Recovery(now);
      }
    }
    if (state.keepAliveProblem != null) {
      // 后台开不起来的保活，人回到前台了再开一次。
      _keepAliveSent = null;
      state = state.copyWith(keepAliveProblem: null);
    }
    state = state.copyWith(sessions: [...state.sessions]);
    _publishRecoveries();
    _ensureRecoveryTimer();
    unawaited(_runRecoveries(force: true));
  }

  void _ensurePingTimer() {
    if (!_backgrounded || !state.sessions.any((value) => value.connected)) {
      return;
    }
    _pingTimer ??= Timer.periodic(
      _backgroundPingInterval,
      (_) => unawaited(_pingConnections()),
    );
  }

  /// 后台时探一遍连着的会话，探不通的标成断开、交给恢复。
  Future<void> _pingConnections({Duration? timeout}) async {
    if (_pinging || !mounted) return;
    _pinging = true;
    try {
      for (final session in [...state.sessions]) {
        if (!session.connected || session.closedByUser) continue;
        try {
          await (timeout == null
              ? session.ping()
              : session.ping(timeout: timeout));
        } on Object {
          _markDisconnected(session);
        }
      }
    } finally {
      _pinging = false;
    }
  }

  static bool _waitingForRestore(ActiveTerminalSession session) =>
      !session.connected &&
      !session.closedByUser &&
      session.restoreHold == null &&
      session.plugin == null;

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
      session.restoreHold = const RestoreHold.untilUser(
        '会话已结束。点「重新连接」会新开一个会话（新的 shell），不是接回原来那个。',
      );
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
      session.restoreHold = RestoreHold.untilUser(
        'tmux 客户端已退出（分离了，或会话已结束），不会自动重新附着。会话 ${tmux.target.sessionId} 如果还在，点「重新连接」会核对后附着它。',
      );
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
      _network.available
          ? '\r\n\x1b[33m连接已断开，正在自动恢复（最多 ${recoveryWindow.inMinutes} 分钟）…\x1b[0m\r\n'
          : '\r\n\x1b[33m连接已断开。手机现在没有网络，网络回来后自动恢复。\x1b[0m\r\n',
    );
    _recoveries[session.id] = _Recovery(_now());
    if (!mounted) return;
    state = state.copyWith(sessions: [...state.sessions]);
    _publishRecoveries();
    _ensureRecoveryTimer();
    unawaited(_runRecoveries());
  }

  // ---- 生命周期：平台事件、保活服务、凭据租期、放回上次的标签（R22）----

  Future<void> _startLifecycle() async {
    final network = await _platform.currentNetwork();
    if (!mounted) return;
    _network = network;
    if (state.networkAvailable != network.available) {
      state = state.copyWith(networkAvailable: network.available);
    }
    await _restoreTabs();
  }

  void _onPlatformEvent(ConnectionPlatformEvent event) {
    if (!mounted) return;
    switch (event) {
      case KeepAliveStopRequested(:final generation):
        // 只认当前这一代：上一代服务迟到的点击，不能把之后新开的会话也断掉（LIFE05）。
        if (generation != _keepAliveSent?.generation) return;
        stopAll(
          const RestoreHold.untilUser(
            '已从通知「全部断开」。不会自动重连；要继续就点「重新连接」。',
          ),
          notice: '已从通知「全部断开」，这个会话断开了。',
        );
      case KeepAliveStopped(:final generation):
        if (generation != _keepAliveSent?.generation) return;
        _keepAliveSent = null;
        if (_backgrounded) {
          // 系统停了后台服务：不在后台把它再开起来（Android 也不让），会话全部断开，等用户回来（LIFE02）。
          stopAll(
            const RestoreHold.untilUser(
              '后台服务被系统停了，会话随之断开，没有自动重连。要继续就点「重新连接」。',
            ),
            notice: '后台服务被系统停了，这个会话断开了。',
          );
        } else {
          // 人在前台：会话还连着就不动它们，服务按现在的状态重开一次。
          _syncKeepAlive();
        }
      case NetworkChanged(:final status):
        _onNetwork(status);
    }
  }

  /// 换了网络：逐条探一下，死了的交给恢复，活着的不动（LIFE03「不因通知无条件断开」）。
  /// 网络没了：什么都不断——绑在旧网络上的 socket 系统会掐掉，掐掉时自然走断线流程；恢复先等网络回来。
  void _onNetwork(NetworkStatus status) {
    final previous = _network;
    _network = status;
    if (state.networkAvailable != status.available) {
      state = state.copyWith(networkAvailable: status.available);
    }
    if (!status.available) return;
    if (!previous.available) {
      // 没网的那段不算进恢复窗口。
      final now = _now();
      for (final recovery in _recoveries.values) {
        recovery
          ..startedAt = now
          ..nextAt = null;
      }
    }
    if (previous.available && previous.id == status.id) return;
    unawaited(_pingConnections(timeout: networkProbeTimeout));
    unawaited(_runRecoveries());
  }

  /// 全部断开（通知上点了、或系统停了后台服务）：先让进行中的连接和恢复失效，再释放连接（docs/07）。
  /// 标签留着、写明原因，不自动重连；用户点「重新连接」才连（LIFE02）。
  void stopAll(RestoreHold hold, {required String notice}) {
    for (final attempt in _attempts.values.toList()) {
      attempt.cancel();
    }
    _attempts.clear();
    _recoveries.clear();
    for (final session in state.sessions) {
      if (session.closedByUser) continue;
      session.monitor?.stop();
      final wasConnected = session.connected;
      session.abort();
      session.restoreHold = hold;
      if (wasConnected || session.plugin == null) {
        session.terminal.showNotice('\r\n\x1b[33m$notice\x1b[0m\r\n');
      }
    }
    _pingTimer?.cancel();
    _pingTimer = null;
    state = state.copyWith(
      sessions: [...state.sessions],
      pendingConnections: state.pendingConnections
          .where((value) => value.phase != PendingConnectionPhase.connecting)
          .toList(growable: false),
    );
    _publishRecoveries();
  }

  void _forgetCredentials() {
    _leaseTimer = null;
    if (!mounted || !_backgrounded) return;
    for (final session in state.sessions) {
      session.forgetSecrets();
      // 临时标签（tmux、托管终端）的 host 是从保险库主机拷出来的，拷贝里也有密码。
      if (session.host.data['_ephemeralTerminal'] == true) {
        try {
          session.host.data.remove('password');
        } on UnsupportedError {
          // 不可改的 map：只有测试里手工构造的会这样。
        }
      }
    }
  }

  void _onStateChanged() {
    _syncKeepAlive();
    unawaited(_persistTabs());
  }

  /// 保活服务开不开、通知上写什么，全由这里按会话状态决定（原来在 app.dart：有标签就开，断了也开着）。
  ///
  /// 有连着的会话、正在恢复的、正在新连接的才开；全部停了（等用户、等回前台）就关——
  /// 没有要保的东西还挂着前台服务和通知，是在骗人。
  void _syncKeepAlive() {
    if (!mounted) return;
    final connected = state.sessions.where((value) => value.connected).length;
    final recovering = state.recovering.length;
    final connecting = state.pendingConnections
        .where((value) => value.phase == PendingConnectionPhase.connecting)
        .length;
    KeepAliveRequest? next;
    if (connected + recovering + connecting > 0) {
      final parts = [
        if (connected > 0) '$connected 个连着',
        if (recovering > 0) '$recovering 个在恢复',
        if (connecting > 0) '$connecting 个在连接',
      ];
      final summary = parts.join('，');
      next = KeepAliveRequest(
        generation: _keepAliveSent?.generation ?? ++_keepAliveGeneration,
        title: 'xwshun 终端：$summary',
        text: '锁着屏时断线不会在后台重新登录，解锁回到 App 再恢复',
      );
    }
    if (next == _keepAliveSent) return;
    _keepAliveSent = next;
    final request = next;
    _keepAliveChain = _keepAliveChain.then((_) async {
      final result = await _platform.setKeepAlive(request);
      if (!mounted || request == null || result.started) return;
      if (result.error == null) return; // 没有平台实现（桌面、测试）
      state = state.copyWith(
        keepAliveProblem:
            '后台保活没开起来（${result.error}）：App 在后台时系统可能停掉连接。回到 App 会再开一次。',
      );
    });
  }

  Future<RestorableTabsStore?> _store() async {
    if (_restorableTabs != null) return _restorableTabs;
    try {
      return _restorableTabs =
          RestorableTabsStore(await SharedPreferences.getInstance());
    } on Object {
      // 没有平台实现（部分测试）：不记、不放回。
      return null;
    }
  }

  /// 记下现在开着的标签，App 被系统结束后下次放回来（只有主机和 tmux 目标，见 [RestorableTab]）。
  /// 托管终端（「系统管理」里开的一次性命令）不记：放回来也只是一个普通 shell，原来那条命令不会再跑。
  Future<void> _persistTabs() async {
    if (!_restoreDone) return;
    final store = await _store();
    if (store == null || !mounted) return;
    await store.save([
      for (final session in state.sessions)
        if (!session.closedByUser &&
            !(session.host.data['_ephemeralTerminal'] == true &&
                session.tmux == null &&
                session.resumeTmux == null))
          RestorableTab(
            id: session.id,
            hostId: sourceHostIdOf(session.host),
            label: session.host.label,
            tmux: session.tmux?.target ?? session.resumeTmux,
          ),
    ]);
  }

  /// 上次 App 被系统结束（或强行停止）前开着的标签放回来：断开的、写明原因、不自动连（LIFE02、LIFE05）。
  Future<void> _restoreTabs() async {
    try {
      final store = await _store();
      final saved = store?.load() ?? const <RestorableTab>[];
      if (saved.isEmpty) return;
      final vault = await vaultController.ready();
      if (!mounted) return;
      final restored = <ActiveTerminalSession>[];
      for (final tab in saved) {
        if (state.sessions.any((value) => value.id == tab.id)) continue;
        final source =
            vault.hosts.where((value) => value.id == tab.hostId).firstOrNull;
        if (source == null) continue; // 主机删了：不放回
        final TerminalSessionAdapter terminal;
        try {
          terminal = newTerminal();
        } on Object {
          continue; // 终端引擎起不来：放回来也没地方显示
        }
        // tmux 标签照 openTmuxTerminal 的样子拷一份；拷贝里不留密码和启动命令（连接时路线按保险库现算）。
        // 普通标签直接用保险库里的主机对象，不能在它上面删字段。
        final host = tab.tmux == null
            ? source
            : HostProfile({
                for (final entry in source.data.entries)
                  if (entry.key != 'password' && entry.key != 'startupCommand')
                    entry.key: entry.value,
                'id': 'tmux-${const Uuid().v4()}',
                'label': tab.label,
                '_ephemeralTerminal': true,
                sourceHostIdKey: source.id,
              });
        final how = tab.tmux == null
            ? '点「重新连接」按现在的配置连（不跑启动命令）。'
            : '点「重新连接」按现在的配置连，tmux 会话先核对还是不是原来那个再附着。';
        terminal.showNotice(
          // 前面空几行：终端是空的，提示会印在最上面，正好被页面顶上的状态条盖住。
          '\r\n\r\n\r\n\r\n\x1b[33m上次 App 被结束了（系统回收、强行停止，或者会话都断了之后被划掉），这个会话断开了。$how\x1b[0m\r\n',
        );
        restored.add(ActiveTerminalSession.restored(
          id: tab.id,
          host: host,
          terminal: terminal,
          hold: const RestoreHold.untilUser(
            '上次 App 被结束了，会话断开了。不会自动重连，点「重新连接」才连。',
          ),
          tmux: tab.tmux,
        ));
      }
      if (restored.isEmpty || !mounted) return;
      final hadSessions = state.sessions.isNotEmpty;
      state = state.copyWith(
        sessions: [...restored, ...state.sessions],
        activeIndex: hadSessions ? state.activeIndex + restored.length : 0,
      );
    } finally {
      _restoreDone = true;
      if (mounted) unawaited(_persistTabs());
    }
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
    _recoveries.remove(removed.id);
    _publishRecoveries();
    if (!sessions.any((value) => value.connected)) {
      _pingTimer?.cancel();
      _pingTimer = null;
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
    _pingTimer?.cancel();
    _recoveryTimer?.cancel();
    _leaseTimer?.cancel();
    unawaited(_platformEvents?.cancel());
    // 会话都关了，保活服务不能留着（docs/07：停止时先失效代次再释放）。
    if (_keepAliveSent != null) {
      _keepAliveSent = null;
      unawaited(_platform.setKeepAlive(null));
    }
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
