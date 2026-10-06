import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';

import '../domain/connection_route.dart';
import '../domain/models/host.dart';
import '../domain/plugins/mosh_bootstrap.dart';
import '../domain/plugins/mosh_route.dart';
import '../infrastructure/plugins/android_plugin_bridge.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/terminal/terminal_session_adapter.dart';
import 'plugin_discovery.dart';
import 'plugin_registry.dart';
import 'plugin_sessions.dart';

/// 本机的 Mosh 运行时（插件）。宿主只通过它找插件、开会话；测试可以换成假的。
abstract interface class MoshRuntime {
  /// 找到能用的 Mosh 插件并确认能和它说话。只在本机做，不碰服务器；不能用抛 [MoshPluginUnavailable]。
  Future<PluginEntry> prepare();

  /// 把这次 bootstrap 的材料交给插件开会话。无论成败，返回前宿主这边的 key 都已清零。
  Future<PluginTerminalSession> open(
    PluginEntry entry, {
    required int cols,
    required int rows,
    required MoshSessionTarget target,
  });
}

/// Mosh 插件现在用不了（没装、没批准、停用、握手不过…）。抛出时还没碰服务器。
class MoshPluginUnavailable implements Exception {
  const MoshPluginUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 真实实现：Android 上单独安装的插件 APK（`plugins/mosh`）。
class PluginMoshRuntime implements MoshRuntime {
  PluginMoshRuntime(this._ref);

  final Ref _ref;

  /// 只认这一个插件：Mosh 的临时会话 key 只交给它（还要用户批准过它的证书）。
  static const pluginId = 'xwshun.mosh';
  static const packageName = 'top.xdwa.xwshun.mosh';

  @override
  Future<PluginEntry> prepare() async {
    final bridge = _ref.read(androidPluginBridgeProvider);
    if (!bridge.supported) {
      throw const MoshPluginUnavailable('Mosh 只在 Android 上有：它由单独安装的 Mosh 插件提供。');
    }
    // App 启动时不自动发现插件（X04），所以每次连 Mosh 前向系统查一遍，顺带按当下的证书和描述符重新核对。
    final discovery = await _ref.read(pluginDiscoveryProvider.future);
    await discovery.start();
    final registry = _ref.read(pluginRegistryProvider.notifier);
    final entry = registry.readyEntry(pluginId);
    if (entry == null) {
      throw MoshPluginUnavailable(_whyUnavailable(registry.entries));
    }
    final descriptor = entry.descriptor!;
    if (!descriptor.capabilities.contains(Capability.terminalSession) ||
        !descriptor.permissions.contains(Permission.ownSessionEphemeralSecret)) {
      throw const MoshPluginUnavailable(
          '装着的 Mosh 插件没有声明终端会话能力或临时会话密钥权限，不能用它连 Mosh。');
    }
    if (checkRoute(descriptor, TransportKind.udp, RequestedRoute.systemDefault)
        is RouteUnsupported) {
      throw const MoshPluginUnavailable('装着的 Mosh 插件没有声明支持直连，不能用它连 Mosh。');
    }
    await _connect(bridge, entry);
    return entry;
  }

  /// 已经连着就沿用。Kotlin 桥的 connect 会先断开同一个插件的旧连接，连带关掉它正在跑的会话：
  /// 开第二个 Mosh 标签时重新 connect，第一个标签就断了。
  Future<void> _connect(AndroidPluginBridge bridge, PluginEntry entry) async {
    final package = entry.packageName!;
    final nonce = Random.secure().nextInt(1 << 31);
    try {
      if (await bridge.ping(package, nonce) == nonce) return;
      throw const MoshPluginUnavailable('Mosh 插件的应答不对，没有用它。');
    } on PluginBridgeException catch (error) {
      if (!const {'NOT_CONNECTED', 'DEAD', 'CLOSED'}.contains(error.code)) {
        throw MoshPluginUnavailable('Mosh 插件没有正常响应：${error.message}');
      }
    }
    try {
      // 握手时插件核对宿主的证书，宿主核对插件的 UID 和批准过的证书（X02）。
      await bridge.connect(
        packageName: package,
        serviceClass: entry.serviceClass!,
        pluginId: entry.pluginId!,
        sha256: entry.binding!.signingDigest,
      );
      if (await bridge.ping(package, nonce) != nonce) {
        throw const MoshPluginUnavailable('Mosh 插件的应答不对，没有用它。');
      }
    } on PluginBridgeException catch (error) {
      throw MoshPluginUnavailable('连不上 Mosh 插件：${error.message}');
    }
  }

  static String _whyUnavailable(List<PluginEntry> entries) {
    final seen = entries
        .where((e) => e.pluginId == pluginId || e.packageName == packageName)
        .firstOrNull;
    return switch (seen?.status) {
      null =>
        '没有装 Mosh 插件（top.xdwa.xwshun.mosh）。装好后到「设置 → 插件（实验）」核对证书并批准，再连。',
      PluginStatus.needsApproval =>
        'Mosh 插件还没批准：到「设置 → 插件（实验）」核对证书后批准，再连。',
      PluginStatus.disabled => 'Mosh 插件被停用了：到「设置 → 插件（实验）」启用它，再连。',
      PluginStatus.missing => 'Mosh 插件已被卸载：装回同一证书的包会直接恢复。',
      PluginStatus.rejected => 'Mosh 插件被拒绝了，原因见「设置 → 插件（实验）」里它的条目。',
      PluginStatus.incompatible =>
        'Mosh 插件和这个 App 不兼容，原因见「设置 → 插件（实验）」里它的条目。',
      PluginStatus.ready => 'Mosh 插件现在不可用。',
    };
  }

  @override
  Future<PluginTerminalSession> open(
    PluginEntry entry, {
    required int cols,
    required int rows,
    required MoshSessionTarget target,
  }) =>
      _ref
          .read(pluginSessionManagerProvider)
          .open(entry, cols: cols, rows: rows, mosh: target);
}

final moshRuntimeProvider = Provider<MoshRuntime>(PluginMoshRuntime.new);

/// Mosh 连接的编排（X09，docs/16 的六步）：路线 → 插件 → SSH 引导 → 交给插件走 UDP → 接到终端。
///
/// 每一步失败都停在那一步，后面的事一件不做：
/// - 路线不是直连：一个连接都不拨，远端什么都不启动（MOS04）。
/// - 插件不能用：还没碰服务器。
/// - 指纹没过、登录失败、远端没有 mosh-server：插件不启动，也没有临时 key 可交；不安装、不 sudo（MOS02）。
/// - 交给插件失败：key 在宿主这边已清零；远端那个没人连的 mosh-server 60 秒后自己退出（mosh-server 的规矩）。
///
/// 插件只拿到这次会话的数字 IP、UDP 端口和临时 key；SSH 密码、私钥、代理口令、Tailscale 凭据都不经过它（PLG14）。
class MoshBootstrapCoordinator {
  MoshBootstrapCoordinator(this._ssh, this._runtime);

  final SshService _ssh;
  final MoshRuntime _runtime;

  /// 插件会话先按这个尺寸开；终端视图一量出实际尺寸就改过去（和 SSH 的 PTY 一样）。
  static const _initialCols = 80;
  static const _initialRows = 24;

  Future<ActiveTerminalSession> connect({
    required String sessionId,
    required HostProfile host,
    required RoutePlan plan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required TerminalSessionAdapter terminal,
    required ConnectionAttempt attempt,
  }) async {
    attempt.throwIfCancelled();
    final unsupported = moshRouteProblem(plan);
    if (unsupported != null) throw unsupported;
    final ports = moshPortRangeOf(host);
    attempt.report(const ConnectionStage(ConnectionStep.plugin));
    final entry = await attempt.waitFor(_runtime.prepare());
    final outcome = await _ssh.bootstrapMosh(
      plan: plan,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
      attempt: attempt,
      portRange: ports,
    );
    final authority = outcome.authority;
    if (attempt.isCancelled) {
      outcome.material.wipe();
      throw const ConnectionCancelledException();
    }
    attempt.report(ConnectionStage(
      ConnectionStep.moshUdp,
      label: plan.target.host.label,
      detail: authority,
    ));
    final session = await attempt.waitFor(
      _runtime.open(
        entry,
        cols: _initialCols,
        rows: _initialRows,
        target: MoshSessionTarget(outcome.udpHost, outcome.material),
      ),
      onCancelled: (session) => unawaited(session.close()),
    );
    attempt.handOver();
    return MoshTerminalProvider.attach(
      sessionId: sessionId,
      host: host,
      plan: plan,
      terminal: terminal,
      session: session,
      udpAuthority: authority,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
    );
  }
}

/// 把一个 Mosh 插件会话接到标签的终端上（X09）。
///
/// 单一所有者（docs/16 第 5 步、MOS05）：终端的输入和尺寸只有这一个出口——终端绑定 → [PluginTerminalSession.write] /
/// resize → 插件的 FD。终端引擎已经把按键、输入法提交编成了字节，这里原样转交，不再编码一遍；也没有第二条路往插件写。
/// 输出原样进终端：mosh-client 画好的 VT 字节，分块边界是 FD 读的边界，被切开的字符由终端适配器拼回去。
///
/// 会话结束后输入绑定立刻解除：之后的按键直接丢掉，不排队，也不留给下一次连接重发（NET11 的 Mosh 部分）。
class MoshTerminalProvider implements PluginTerminalLink {
  MoshTerminalProvider._(this.session, this.detail);

  final PluginTerminalSession session;

  @override
  final String detail;

  @override
  String get protocol => 'Mosh';

  TerminalBinding? _binding;
  StreamSubscription<SessionPhase>? _phaseSubscription;
  (int, int)? _pendingSize;
  final _ended = Completer<void>();
  String? _endNotice;

  /// 终端交给这个会话的输入次数，和 [PluginTerminalSession.writeCount] 对照：两者相等说明每次提交只写了一次。
  int inputEvents = 0;

  /// 插件没收下的输入字节（会话已结束、积压超限）。这些字节不重发。
  int droppedInputBytes = 0;

  static ActiveTerminalSession attach({
    required String sessionId,
    required HostProfile host,
    required RoutePlan plan,
    required TerminalSessionAdapter terminal,
    required PluginTerminalSession session,
    required String udpAuthority,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
  }) {
    final link = MoshTerminalProvider._(session, 'UDP $udpAuthority');
    final TerminalBinding binding;
    try {
      binding = terminal.bind(link._input, resize: link._resize);
    } on Object {
      // 标签在打开途中被关、终端已释放：会话没人要了。
      unawaited(session.close());
      rethrow;
    }
    link._binding = binding;
    final output = session.output.listen(terminal.feed);
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
    _endNotice = moshEndNotice(session);
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

/// Mosh 会话为什么结束，给用户看的一句话（X08 留下的：插件报的 `failed:exit-<码>` 要说成人话）。
String describeMoshEnd(PluginTerminalSession session) {
  final failure = session.failure;
  // stopConfirmed 只在宿主自己发起关闭时才有值：null 说明是远端先结束的。
  return switch (session.phase) {
    SessionPhase.closed when failure != null => _describeFailure(failure),
    SessionPhase.closed when session.stopConfirmed == false =>
      'Mosh 会话已关闭，但插件没有确认 mosh-client 已退出。远端可能还有旧会话（mosh-server）。',
    SessionPhase.closed when session.stopConfirmed == true =>
      '本 App 关掉了这个 Mosh 会话（插件被停用、撤销批准或更新），插件确认 mosh-client 已退出。',
    SessionPhase.closed => '远端 shell 已退出，Mosh 会话结束。',
    SessionPhase.interrupted when failure != null => _describeFailure(failure),
    SessionPhase.interrupted => 'Mosh 插件关掉了这个会话，没说原因。远端可能还有旧会话（mosh-server）。',
    SessionPhase.providerDied => 'Mosh 插件进程没了（被系统或手动结束）。'
        '远端可能还有旧会话：mosh-server 会一直等客户端回来，可以在服务器上用 pkill mosh-server 清掉。',
    SessionPhase.permissionRevoked =>
      'Mosh 插件被停用、撤销批准、更新或断开了连接，会话已关闭。远端可能还有旧会话（mosh-server）。',
    _ => 'Mosh 会话已结束。',
  };
}

/// mosh-client 的退出码（插件按 `exit-<码>` 报；被信号结束时是 128 + 信号号）。
/// 1 是它自己的「没能正常收尾」：mosh 1.4.0 `mosh-client.cc` 末尾 `return !success`。
String _describeFailure(String failure) {
  final code = failure.startsWith('exit-')
      ? int.tryParse(failure.substring('exit-'.length))
      : null;
  if (code == 1) {
    return 'mosh-client 没能正常收尾（退出码 1）。最常见的是 UDP 到不了服务器：'
        '服务器或中间的防火墙没放行 mosh-server 用的 UDP 端口；也可能是网络断得太久、服务器一直没回应。'
        '上面终端里 mosh 自己打印的说明更具体。远端可能还有旧会话（mosh-server）。';
  }
  if (code != null && code > 128) {
    final signal = code - 128;
    return signal == 9
        ? 'mosh-client 被强制结束（信号 9）：关闭时 8 秒内没退出会被插件强杀，系统内存紧张时也会这样。远端可能还有旧会话（mosh-server）。'
        : 'mosh-client 被信号 $signal 结束。远端可能还有旧会话（mosh-server）。';
  }
  if (code != null && code >= 0) {
    return 'mosh-client 异常退出（退出码 $code）。远端可能还有旧会话（mosh-server）。';
  }
  return 'Mosh 插件报告运行时失败（$failure）。远端可能还有旧会话（mosh-server）。';
}

/// 会话结束时写进终端的提示：原因、不会自动重连、不会重发输入、怎么再连。
String moshEndNotice(PluginTerminalSession session) {
  final reason = describeMoshEnd(session);
  final normal = session.phase == SessionPhase.closed &&
      session.failure == null &&
      session.stopConfirmed == null;
  if (normal) return '\r\n\x1b[33m[Mosh] $reason 不会自动重连。\x1b[0m\r\n';
  return '\r\n\x1b[31m[Mosh] $reason\x1b[0m\r\n'
      '\x1b[33m不会自动重连，也不会重发断开前的输入；断开前最后打的字有没有到远端，App 无法确认。\r\n'
      '要再连，从保险库重新连接这台主机：会在服务器上新起一个 mosh-server，不是原来那个会话。\x1b[0m\r\n';
}
