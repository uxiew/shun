import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/models/server_stats.dart';
import '../../domain/plugins/mosh_bootstrap.dart';
import '../../domain/tailscale_ssh.dart';
import '../../domain/tmux/tmux_target.dart';
import '../terminal/terminal_input_controller.dart';
import '../terminal/terminal_session_adapter.dart';
import '../tmux/tmux_protocol.dart';
import '../transport/proxy_transport.dart';
import 'server_monitor_service.dart';
import 'ssh_identity.dart';
import 'ssh_login_watch.dart';

typedef HostKeyVerifier = Future<bool> Function(
  HostProfile host,
  String algorithm,
  String fingerprint,
);

typedef KeyboardInteractiveHandler = Future<List<String>?> Function(
  String name,
  String instruction,
  List<({String text, bool echo})> prompts,
);

class ConnectionCancelledException implements Exception {
  const ConnectionCancelledException();

  @override
  String toString() => '连接已由用户终止';
}

/// 路线上某一跳、某个阶段失败：哪台机器、卡在哪一步、什么原因（JMP02 / JMP04）。
class RouteHopException implements IOException {
  const RouteHopException(this.hop, this.message, this.cause,
      {this.relayed = false});

  /// 从 0 数的跳序号；等于跳板数时就是目标。
  final int hop;
  final String message;

  /// 原始错误，给测试和日志用；界面只显示 [message]。
  final Object cause;

  /// 这一跳不是手机直接连的：第一跳经代理，或者后面的跳经上一跳转发。
  /// 这时「连上后在登录前被关」也可能是代理、跳板机之后那一段断了，App 看不到（见 connectionHint）。
  final bool relayed;

  @override
  String toString() => message;
}

/// 这次连接是用户新开的，还是断线后的恢复。
///
/// 只有 [fresh] 会执行主机的 startupCommand。恢复时重跑它等于替用户再执行一遍命令——
/// 对托管终端（startupCommand 就是那条管理命令）尤其危险（A04 / REG02）。
enum ConnectionPurpose { fresh, restore, probe }

/// 测试连接的结果。[tty] 是远端分配的终端设备名（如 /dev/pts/3），Telnet 没有这一项。
class ProbeOutcome {
  const ProbeOutcome({required this.tty});
  final String? tty;
}

enum ConnectionStep {
  dial,
  proxy,
  handshake,
  check,
  forward,
  shell,
  pty,

  /// Mosh：核对本机的 Mosh 插件（批准、证书、握手），还没碰服务器。
  plugin,

  /// Mosh 第一段：已经登录，经 SSH 在远端启动 mosh-server。
  moshServer,

  /// Mosh 第二段：SSH 已断开，材料交给插件，由它经 UDP 直连。
  moshUdp,

  /// 插件主机（X12）：核对本机的插件装着、批准了、可用。还没打开会话。
  pluginHost,

  /// 插件主机：插件正在打开会话。它自己联网，本 App 不知道它连去哪。
  pluginSession,
}

/// 连接进行到了哪一步，给等待界面显示用。
///
/// 同一次尝试的阶段严格按代码顺序上报；尝试被取消后不再上报，所以界面上不会出现
/// 「已经取消了，进度还在往前走」或者旧尝试的进度盖掉新尝试的情况（NET09）。
class ConnectionStage {
  const ConnectionStage(
    this.step, {
    this.hop = 0,
    this.hopCount = 1,
    this.label = '',
    this.detail = '',
  });

  final ConnectionStep step;

  /// 从 0 数的跳序号，[hopCount] 是跳板数 + 1（目标）。
  final int hop;
  final int hopCount;

  /// 这一跳主机的名称。
  final String label;

  /// 地址之类的补充，比如代理端点、下一跳地址。
  final String detail;

  String describe() {
    final prefix = hopCount > 1 ? '第 ${hop + 1}/$hopCount 跳，' : '';
    return switch (step) {
      ConnectionStep.dial => '$prefix正在连接“$label”（$detail）',
      ConnectionStep.proxy => '$prefix正在经代理连接“$label”（代理 $detail）',
      ConnectionStep.handshake => '$prefix“$label”：SSH 握手、核对指纹、登录',
      ConnectionStep.check => '$prefix“$label”：等你完成 Tailscale check',
      ConnectionStep.forward => '$prefix“$label”：转发到下一跳（$detail）',
      ConnectionStep.shell => '正在打开终端',
      ConnectionStep.pty => '正在检查远端终端（PTY）',
      ConnectionStep.plugin => '正在核对本机的 Mosh 插件（还没连服务器）',
      ConnectionStep.moshServer => '第 1 段 SSH：“$label”（$detail）已登录，正在启动 mosh-server',
      ConnectionStep.moshUdp => '第 2 段 UDP：SSH 已断开，Mosh 插件正在直连 $detail',
      ConnectionStep.pluginHost => '正在核对本机的插件“$label”（还没打开会话）',
      ConnectionStep.pluginSession =>
        '插件“$label”正在打开会话：它自己联网，不经过本 App 的代理和跳板',
    };
  }

  @override
  String toString() => describe();
}

/// App 发起 TCP 连接的唯一入口，测试可替换成记录端点的实现。
typedef TcpDialer = Future<Socket> Function(
  String host,
  int port, {
  Duration? timeout,
});

Future<Socket> _systemDial(String host, int port, {Duration? timeout}) =>
    Socket.connect(host, port, timeout: timeout);

/// 不经 SSH 通道、由插件会话承载的终端（X09 的 Mosh）。连接层只通过它等结束、关会话，不认识插件的细节。
abstract interface class PluginTerminalLink {
  /// 给界面看的协议名，例如 Mosh。
  String get protocol;

  /// 数据实际走哪，例如「UDP 10.0.2.2:60101」。
  String get detail;

  bool get active;

  /// 会话结束（任何原因）时完成，从不出错。
  Future<void> get ended;

  /// 结束后给用户看的说明（为什么结束、远端可能留下什么、接下来怎么办）；还没结束时为 null。
  String? get endNotice;

  /// 幂等。
  Future<void> close();
}

/// Mosh 的 SSH 引导结果：UDP 去哪、带什么 key。
class MoshBootstrapOutcome {
  const MoshBootstrapOutcome(this.udpHost, this.material);

  /// 这次 SSH 实际连上的那个 IP（数字形式）。
  final String udpHost;
  final MoshBootstrapResult material;

  String get authority => udpHost.contains(':')
      ? '[$udpHost]:${material.port}'
      : '$udpHost:${material.port}';
}

class ActiveTerminalSession {
  ActiveTerminalSession({
    required this.id,
    required this.host,
    required this.terminal,
    required this.verifyHostKey,
    required this.keyboardInteractive,
    this.sshClients = const [],
    this.sshSession,
    this.telnetSocket,
    this.routePlan,
    this.tmux,
    this.plugin,
    TerminalBinding? binding,
    List<StreamSubscription<Object?>> outputSubscriptions = const [],
  })  : _binding = binding,
        _outputSubscriptions = outputSubscriptions;

  final String id;
  final HostProfile host;

  /// 这个标签的终端。断线恢复时新旧连接共用它；它归标签（会话控制器）管，
  /// 关连接不销毁它，页面重建也不碰它（GST02）。
  final TerminalSessionAdapter terminal;
  final HostKeyVerifier verifyHostKey;
  final KeyboardInteractiveHandler? keyboardInteractive;
  TerminalInputController get input => terminal.input;

  /// 终端输入交给这条连接的绑定。恢复时新连接一绑定，这条就失效，旧代次再发不出字节。
  final TerminalBinding? _binding;
  final List<SSHClient> sshClients;
  final SSHSession? sshSession;
  final Socket? telnetSocket;

  /// 建这条连接时冻结的路线（含每一跳的主机配置和私钥副本）。断线恢复沿用它：
  /// 自动恢复只能走同一条路线，不能因为用户期间改了配置就悄悄换代理、换身份（NET10，docs/07）。
  /// 手工构造的会话（测试）可能没有，恢复时再按保险库现算。
  final RoutePlan? routePlan;

  /// 这个标签附着的 tmux 客户端（R21）；普通 shell 标签为 null。
  ///
  /// 断线恢复按其中的目标重新附着：远端先核对 uid、socket、server 代次、session ID 和创建时间，
  /// 对不上就停下，不按名字找替身、不新建（TMX04/TMX05）。
  final TmuxClientBinding? tmux;

  /// 由插件承载的终端（Mosh）；SSH、Telnet 标签为 null。
  ///
  /// 有它时 [sshClients] 是空的：Mosh 只在引导时用了一下 SSH，随即关掉，所以这种标签没有 SFTP、监控、端口转发。
  final PluginTerminalLink? plugin;

  /// 远端输出送进 [terminal] 的订阅。恢复时新旧连接共用同一个 terminal，
  /// 旧连接释放时必须先断开这里，旧通道迟到的字节才不会混进新 shell 的画面。
  final List<StreamSubscription<Object?>> _outputSubscriptions;
  bool connected = true;
  bool closedByUser = false;

  /// 自动恢复遇到了只能由用户处理的事（Tailscale check），之后不再自动重试这个标签。
  bool autoRestoreBlocked = false;
  bool _released = false;
  bool _outputDetached = false;
  ServerSystemInfo? systemInfo;
  SessionMonitor? monitor;

  SSHClient? get sshClient => sshClients.isEmpty ? null : sshClients.last;
  bool get isSsh => sshClient != null;
  Future<void> get done =>
      sshSession?.done ??
      telnetSocket?.done ??
      plugin?.ended ??
      Future.value();

  Future<void> ping({Duration timeout = const Duration(seconds: 8)}) async {
    if (!connected) throw StateError('SSH session is disconnected');
    // Mosh 自己管 UDP 上的保活和重传，宿主这边只能看插件会话还在不在。
    if (plugin case final link? when !link.active) {
      throw StateError('Mosh 会话已结束');
    }
    if (sshClients.isNotEmpty) {
      await Future.wait(sshClients.map((client) => client.ping()))
          .timeout(timeout);
      return;
    }
    await telnetSocket?.flush().timeout(timeout);
  }

  /// 释放这条连接的全部网络资源，可以重复调用（LIFE06）。
  ///
  /// 顺序按 docs/03：先关 PTY 通道，再关目标 client，最后逆序关跳板；
  /// 每个 client 关闭时会关掉自己脚下的 socket（第一跳的就是到代理或第一跳的 TCP）。
  /// 外部 SOCKS 服务不归 App 管，这里只关 App 自己开的那条到代理的连接。
  ///
  /// 不断开输出订阅：shell 刚结束时最后几块输出可能还在路上（dartssh2 的 `done` 先于 stdout 结束），
  /// 断线时立刻断订阅会吞掉断线前的最后一屏。换上新连接或关标签时再调 [detachOutput]。
  void abort() {
    monitor?.stop();
    connected = false;
    if (_released) return;
    _released = true;
    sshSession?.close();
    for (final client in sshClients.reversed) {
      client.close();
    }
    telnetSocket?.destroy();
    // Mosh：插件给 mosh-client 发 SIGHUP，它按协议通知服务器关闭；会话已经结束时什么都不做。
    if (plugin != null) unawaited(plugin!.close());
  }

  /// 不再把这条连接的远端输出送进 [terminal]，也不再把终端输入交给它。可以重复调用。
  ///
  /// 恢复时新旧连接共用同一个 terminal：换上新连接前必须先调它，
  /// 旧通道迟到的字节才不会混进新 shell 的画面（NET09）。
  /// 输入绑定只解除自己这一代：新连接已经绑上时什么都不动。
  void detachOutput() {
    if (_outputDetached) return;
    _outputDetached = true;
    _binding?.release();
    for (final subscription in _outputSubscriptions) {
      unawaited(subscription.cancel());
    }
  }

  /// 用户关标签：断开输出和输入、释放网络资源。重复调用无副作用。
  ///
  /// 不销毁 [terminal]：恢复中途被放弃的新连接和标签共用同一个终端，
  /// 终端由会话控制器在标签真正关掉时销毁。
  Future<void> close() async {
    closedByUser = true;
    detachOutput();
    abort();
  }
}

class SshService {
  SshService({
    TcpDialer? dialer,
    this.tailscaleCheckWait = const Duration(minutes: 10),
  }) : _dial = dialer ?? _systemDial;

  final TcpDialer _dial;

  /// 收到 Tailscale check 链接后最多等多久。Tailscale 自己最多挂 30 分钟（tailssh v1.104.0），
  /// 这里取 10 分钟：够开浏览器、登录、确认，又不让一个忘了的连接一直占着。
  final Duration tailscaleCheckWait;
  final _pendingConnections = <String, ConnectionAttempt>{};

  void cancelConnection(String sessionId) {
    _pendingConnections[sessionId]?.cancel();
  }

  /// 建一条终端连接。
  ///
  /// 新开连接传保险库里的 [hosts]、[keys]、[proxyProfiles]，由这里现算路线；
  /// 恢复连接传原来的 [routePlan]，沿用同一条路线，不重新读配置（NET10）。
  ///
  /// [terminal] 由调用方创建并持有（恢复时传标签原来的那个），这里只绑定、送字节，从不创建或销毁它：
  /// 连接层不知道用的是哪个终端引擎（R16）。
  ///
  /// [attempt] 由调用方创建并持有，调用方在这里开始之前就能取消它（比如还在等保险库解锁时）。
  /// 不传就内部新建一个，仍可用 [cancelConnection] 按 [sessionId] 取消。
  /// 失败或取消时，这次尝试已经建好的 socket、每一跳 client、转发通道全部关掉；
  /// 成功时资源所有权移交给返回的会话，之后再取消这个 attempt 不会关掉它，由调用方决定是否关闭。
  Future<ActiveTerminalSession> connect({
    required String sessionId,
    required HostProfile host,
    List<HostProfile> hosts = const [],
    List<SshKeyProfile> keys = const [],
    List<ProxyProfile> proxyProfiles = const [],
    RoutePlan? routePlan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required TerminalSessionAdapter terminal,
    ConnectionPurpose purpose = ConnectionPurpose.fresh,
    ConnectionAttempt? attempt,
    TmuxTarget? tmuxAttach,
  }) async {
    final pending = attempt ?? ConnectionAttempt();
    final previous = _pendingConnections[sessionId];
    if (!identical(previous, pending)) previous?.cancel();
    _pendingConnections[sessionId] = pending;
    try {
      pending.throwIfCancelled();
      if (host.protocol == HostProtocol.mosh) {
        // Mosh 主机走 MoshBootstrapCoordinator（SSH 只用来启动 mosh-server）。走到这里说明调用方漏判了协议：
        // 宁可失败，也不能悄悄给它开一个普通 SSH shell。
        throw UnsupportedError('Mosh 主机要经 Mosh 插件连接，不能按普通 SSH 终端打开。');
      }
      if (host.protocol == HostProtocol.plugin) {
        // 同上：插件主机由 PluginHostConnector 打开，没有 SSH 可连。
        throw UnsupportedError('插件主机要经插件连接，不能按普通 SSH 终端打开。');
      }
      // 路线在任何拨号之前一次算好：配置有问题此时就抛 RouteConfigException，一个连接都没开。
      // 之后全程只用 plan 里的快照，连接中途用户改了主机、跳板或代理，只影响下一次连接（RTE03）。
      final plan = routePlan ??
          resolveRoutePlan(
            host,
            hosts: hosts,
            proxyProfiles: proxyProfiles,
            keys: keys,
          );
      final session = plan.protocol == HostProtocol.telnet
          ? await _connectTelnet(
              sessionId,
              host,
              plan,
              verifyHostKey,
              keyboardInteractive,
              terminal,
              pending,
            )
          : await _connectSsh(
              sessionId,
              host,
              plan,
              verifyHostKey,
              keyboardInteractive,
              terminal,
              purpose,
              pending,
              tmuxAttach,
            );
      pending.handOver();
      return session;
    } catch (_) {
      // 半成品一律关掉：不只是取消，任何一步失败（包括同步抛出的私钥解析错误）
      // 都不能留下一条没人管的 TCP 或 SSH 连接（R08）。
      pending.releasePartial();
      rethrow;
    } finally {
      if (identical(_pendingConnections[sessionId], pending)) {
        _pendingConnections.remove(sessionId);
      }
    }
  }

  /// 测试连接：按和正式连接完全相同的路线、同样的指纹核对逐跳建到目标并登录，
  /// 然后只做一件只读的事——带 PTY 执行 `tty`，拿到远端分配的终端设备名作为「真的有 PTY」的证据，随即全部关掉。
  ///
  /// 不开交互式 shell：那会触发用户 .bashrc 里的自动 tmux 之类（docs/04：测试不得创建 tmux）；
  /// 也从不执行主机配置的启动命令。Telnet 只测到 TCP 连上。
  /// 阶段按 [attempt] 上报；失败时抛出和正式连接相同的错误（RouteHopException 等），取消抛 ConnectionCancelledException。
  Future<ProbeOutcome> probe({
    required HostProfile host,
    List<HostProfile> hosts = const [],
    List<SshKeyProfile> keys = const [],
    List<ProxyProfile> proxyProfiles = const [],
    RoutePlan? routePlan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required ConnectionAttempt attempt,
  }) async {
    try {
      attempt.throwIfCancelled();
      if (host.protocol == HostProtocol.mosh) {
        throw UnsupportedError('Mosh 主机要经 Mosh 插件连接，不能按普通 SSH 终端打开。');
      }
      if (host.protocol == HostProtocol.plugin) {
        throw UnsupportedError('插件主机要经插件连接，不能按普通 SSH 终端打开。');
      }
      final plan = routePlan ??
          resolveRoutePlan(
            host,
            hosts: hosts,
            proxyProfiles: proxyProfiles,
            keys: keys,
          );
      if (plan.protocol == HostProtocol.telnet) {
        final endpoint = plan.target.endpoint;
        attempt.report(ConnectionStage(
          ConnectionStep.dial,
          label: plan.target.host.label,
          detail: endpoint.authority,
        ));
        final socket = await attempt.waitFor<Socket>(
          _dialWithin(endpoint, const Duration(seconds: 15)),
          onCancelled: (value) => value.destroy(),
        );
        attempt.telnetSocket = socket;
        return const ProbeOutcome(tty: null);
      }
      final clients = await _establishSsh(
        plan,
        verifyHostKey,
        keyboardInteractive,
        attempt,
        ConnectionPurpose.probe,
      );
      attempt.report(const ConnectionStage(ConnectionStep.pty));
      final tty = await _atHop(
        plan,
        plan.hops.length - 1,
        '检查终端（PTY）失败',
        () => attempt.waitFor(_remoteTty(clients.last)),
      );
      return ProbeOutcome(tty: tty);
    } finally {
      // 测试连接不交出任何资源：成功、失败、取消都在这里全部关掉。
      attempt.releasePartial();
    }
  }

  /// 带 PTY 执行 `tty`，返回远端终端设备名（如 /dev/pts/3）。没拿到 PTY 时 dartssh2 会抛错。
  Future<String> _remoteTty(SSHClient client) async {
    final session = await client.execute(
      'tty',
      pty: const SSHPtyConfig(type: 'xterm-256color', width: 80, height: 24),
    );
    try {
      final output = await session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 10));
      return output.trim();
    } finally {
      session.close();
    }
  }

  /// Mosh 的 SSH 引导（X09，docs/16 第 2、3 步）：直连目标，先核对主机指纹、再登录，然后只执行一条固定命令
  /// （[MoshBootstrap.command]）拉起 mosh-server，按字节解析出 UDP 端口和会话 key，最后关掉这条 SSH。
  ///
  /// - 只接受直连、没有跳板的路线。别的路线调用方在拨号之前就该拒绝（`moshRouteProblem`），这里再挡一次。
  /// - UDP 目标就是这次 SSH 实际连上的那个 IP（[MoshBootstrapOutcome.udpHost]）：主机名只由系统解析一次，
  ///   SSH 和 UDP 去的是同一台机器（官方 mosh 默认也这样）；命令里的 `-s` 让 mosh-server 也只在这个地址上收 UDP。
  /// - 不装软件、不用 sudo、不重试：远端没有 mosh-server 就照实失败。
  /// - 输出有上限、有期限。原始输出里有 key：解析完就清零，不进日志和报错。
  /// - 成功、失败、取消都不交出 SSH 资源，返回前全部关掉；mosh-server 自己已经脱离了这条 SSH。
  Future<MoshBootstrapOutcome> bootstrapMosh({
    required RoutePlan plan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required ConnectionAttempt attempt,
    (int, int) portRange = MoshBootstrap.defaultPortRange,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      attempt.throwIfCancelled();
      if (plan.entry is! DirectEntry || plan.jumps.isNotEmpty) {
        throw StateError('Mosh 只能直连，不能经代理或跳板机引导');
      }
      final command = MoshBootstrap.command(portRange: portRange);
      final clients = await _establishSsh(
        plan,
        verifyHostKey,
        keyboardInteractive,
        attempt,
        ConnectionPurpose.fresh,
      );
      final peer = attempt.directPeer;
      if (peer == null) {
        throw StateError('拿不到这次 SSH 连上的 IP 地址，不知道 Mosh 的 UDP 该发往哪里');
      }
      final target = plan.target;
      attempt.report(ConnectionStage(
        ConnectionStep.moshServer,
        label: target.host.label,
        detail: target.endpoint.authority,
      ));
      final output = await _atHop(
        plan,
        0,
        '启动 mosh-server 失败',
        () => attempt.waitFor(_runBounded(clients.last, command, timeout)),
      );
      try {
        return MoshBootstrapOutcome(
          peer.address,
          _parseMoshBootstrap(output.bytes, output.exitCode, portRange),
        );
      } finally {
        output.bytes.fillRange(0, output.bytes.length, 0);
      }
    } finally {
      attempt.releasePartial();
    }
  }

  static MoshBootstrapResult _parseMoshBootstrap(
    Uint8List output,
    int? exitCode,
    (int, int) portRange,
  ) {
    try {
      return MoshBootstrap.parse(output, portRange: portRange);
    } on MoshBootstrapException catch (error) {
      // 有的 shell 找不到命令时什么都不打印，只返回 127（POSIX 约定的「命令不存在」）。
      if (error.failure == MoshBootstrapFailure.noConnectLine &&
          exitCode == 127) {
        throw const MoshBootstrapException(MoshBootstrapFailure.serverMissing);
      }
      rethrow;
    }
  }

  /// 不带 PTY 执行 [command]，stdout、stderr 合在一起收，最多收 [MoshBootstrap.maxOutputBytes] + 1 字节
  /// （多出的那 1 字节让解析认出「超长」），收满就关通道不再读。[timeout] 内远端没收尾就放弃。
  ///
  /// 不用 PTY：不触发登录脚本里只在交互式终端才跑的东西（自动 tmux 之类），输出里也没有 PTY 加的回车。
  /// 收到的每一块在拼好之后清零；dartssh2 自己解密用的缓冲清不到。
  Future<({Uint8List bytes, int? exitCode})> _runBounded(
    SSHClient client,
    String command,
    Duration timeout,
  ) async {
    const limit = MoshBootstrap.maxOutputBytes + 1;
    final session = await client.execute(command);
    final chunks = <Uint8List>[];
    var received = 0;
    var open = 2;
    final finished = Completer<void>();
    void finish() {
      if (!finished.isCompleted) finished.complete();
    }

    void add(Uint8List chunk) {
      if (received >= limit) return;
      final take = chunk.length <= limit - received
          ? chunk
          : Uint8List.sublistView(chunk, 0, limit - received);
      chunks.add(take);
      received += take.length;
      if (received >= limit) {
        session.close();
        finish();
      }
    }

    void streamDone() {
      if (--open == 0) finish();
    }

    final subscriptions = [
      session.stdout.listen(add, onDone: streamDone, onError: (_) => streamDone()),
      session.stderr.listen(add, onDone: streamDone, onError: (_) => streamDone()),
    ];
    try {
      await finished.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          '远端 ${timeout.inSeconds} 秒内没有完成 mosh-server 的启动',
        ),
      );
      // 退出码在通道关闭时才到；流已经结束，最多再等一小会儿。
      await session.done.timeout(const Duration(seconds: 2), onTimeout: () {});
      final bytes = Uint8List(received);
      var at = 0;
      for (final chunk in chunks) {
        bytes.setRange(at, at + chunk.length, chunk);
        at += chunk.length;
      }
      return (bytes: bytes, exitCode: session.exitCode);
    } finally {
      for (final chunk in chunks) {
        chunk.fillRange(0, chunk.length, 0);
      }
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      session.close();
    }
  }

  Future<ActiveTerminalSession> _connectSsh(
    String sessionId,
    HostProfile host,
    RoutePlan plan,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    TerminalSessionAdapter terminal,
    ConnectionPurpose purpose,
    ConnectionAttempt pending,
    TmuxTarget? tmuxAttach,
  ) async {
    final clients = await _establishSsh(
      plan,
      verifyHostKey,
      keyboardInteractive,
      pending,
      purpose,
    );
    if (tmuxAttach != null) {
      return _openTmuxAttach(
        sessionId,
        host,
        plan,
        clients,
        verifyHostKey,
        keyboardInteractive,
        terminal,
        pending,
        tmuxAttach,
      );
    }
    return _openShell(
      sessionId,
      host,
      plan,
      clients,
      verifyHostKey,
      keyboardInteractive,
      terminal,
      purpose,
      pending,
    );
  }

  /// 按路线逐跳建到目标，每一跳都验完指纹、登录成功。返回各跳 client，最后一个是目标。
  /// 终端连接和测试连接共用这一段，所以两者走的路线、验指纹的方式完全一样。
  Future<List<SSHClient>> _establishSsh(
    RoutePlan plan,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    ConnectionAttempt pending,
    ConnectionPurpose purpose,
  ) async {
    final hops = plan.hops;
    final clients = <SSHClient>[];
    SSHSocket? transport;
    ConnectionStage stageAt(int index, ConnectionStep step, [String? detail]) =>
        ConnectionStage(
          step,
          hop: index,
          hopCount: hops.length,
          label: hops[index].host.label,
          detail: detail ?? hops[index].endpoint.authority,
        );
    // 每一跳的登录私钥在任何拨号之前解析好（SEC06）：口令不对、私钥被删、内容坏了，
    // 此时一个连接都还没开，报错也指明是哪一跳，不用先连上服务器再被拒。
    final identities = <List<SSHKeyPair>?>[];
    for (var index = 0; index < hops.length; index++) {
      identities.add(await _atHop(
        plan,
        index,
        '读取登录私钥失败',
        () async => loadHopIdentities(hops[index]),
      ));
    }
    for (var index = 0; index < hops.length; index++) {
      final hop = hops[index];
      final timeout = _connectTimeout(hop.host);
      // 只有第一跳由手机拨出（直连或经代理，入口只拨这一次）；后面每一跳都经上一跳的 SSH 转发到达。
      final SSHSocket reached = transport ??
          await _atHop<SSHSocket>(
            plan,
            index,
            plan.entry is ProxyEntry ? '经代理连接失败' : '直连失败',
            () => pending.waitFor<SSHSocket>(
              _openTransport(plan.entry, hop, hops.length, timeout, pending),
              onCancelled: (socket) => socket.destroy(),
            ),
          );
      // 版本行攒齐再交给 dartssh2，且这一段有期限（见 SshBannerDeadlineSocket）。
      final guard = SshBannerDeadlineSocket(reached, timeout);
      transport = guard;
      pending.transport = guard;
      pending.throwIfCancelled();
      pending.report(stageAt(index, ConnectionStep.handshake));
      final watch = SshLoginWatch(
        mode: sshLoginModeOf(hop.host),
        // 自动恢复不替用户做 check（docs/07）；新开连接和测试连接时用户就在跟前。
        allowCheck: purpose != ConnectionPurpose.restore,
        authWait: _authTimeout(hop.host),
        checkWait: tailscaleCheckWait,
        describePrompt: (banner, deadline) => TailscaleCheckPrompt(
          hop: index,
          hopCount: hops.length,
          hostLabel: hop.host.label,
          endpoint: hop.endpoint.authority,
          sourceNode: tailscaleSourceNode(plan, index),
          banner: banner,
          deadline: deadline,
        ),
        onPrompt: (prompt) {
          if (prompt != null) {
            pending.report(stageAt(index, ConnectionStep.check));
          }
          pending.reportCheck(prompt);
        },
      );
      final client = _createClient(
        guard,
        hop,
        identities[index],
        verifyHostKey,
        keyboardInteractive,
        watch,
      );
      clients.add(client);
      pending.clients.add(client);
      // 先等这一跳握手、验指纹、登录全部完成，失败时才分得清是这一跳本身，
      // 还是它往下一跳的转发（JMP02 / JMP04）。指纹没通过时 dartssh2 在认证前就断开。
      await _atHop(
        plan,
        index,
        'SSH 握手或登录失败',
        () => pending.waitFor<void>(watch.authenticated(client)),
        guard: guard,
      );
      if (index < hops.length - 1) {
        final next = hops[index + 1].endpoint;
        pending.report(stageAt(index, ConnectionStep.forward, next.authority));
        transport = await _atHop<SSHForwardChannel>(
          plan,
          index,
          '转发失败（到 ${next.authority}）',
          () => pending.waitFor<SSHForwardChannel>(
            client.forwardLocal(next.host, next.port),
            onCancelled: (socket) => socket.destroy(),
          ),
        );
        pending.transport = transport;
      }
    }
    return clients;
  }

  Future<ActiveTerminalSession> _openShell(
    String sessionId,
    HostProfile host,
    RoutePlan plan,
    List<SSHClient> clients,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    TerminalSessionAdapter terminal,
    ConnectionPurpose purpose,
    ConnectionAttempt pending,
  ) async {
    final hops = plan.hops;
    final target = plan.target.host;
    final client = clients.last;
    pending.report(const ConnectionStage(ConnectionStep.shell));
    final session = await _atHop(
      plan,
      hops.length - 1,
      '打开终端失败',
      () => pending.waitFor(
        client.shell(
          pty:
              const SSHPtyConfig(type: 'xterm-256color', width: 80, height: 24),
          environment: _environment(target),
        ),
        onCancelled: (value) => value.close(),
      ),
    );
    pending.shell = session;
    // 先绑定再收输出：标签在恢复途中被关、终端已释放时，绑定直接失败，一个订阅都不留。
    final binding = terminal.bind(
      session.write,
      resize: session.resizeTerminal,
    );
    // 远端字节原样送进终端，不在网络分包处转成字符串（TER01）。
    // 带 PTY 的会话里远端已把 stderr 并进 stdout，stderr 通道基本是空的；两路共用终端的同一条字节流，
    // 和真实终端只有一条输入流一样。
    final subscriptions = [
      session.stdout.listen(terminal.feed),
      session.stderr.listen(terminal.feed),
    ];
    final startup = target.startupCommand;
    if (startup != null &&
        startup.isNotEmpty &&
        purpose == ConnectionPurpose.fresh) {
      session.write(Uint8List.fromList(utf8.encode('$startup\n')));
    }
    return ActiveTerminalSession(
      id: sessionId,
      host: host,
      terminal: terminal,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
      sshClients: clients,
      sshSession: session,
      routePlan: plan,
      binding: binding,
      outputSubscriptions: subscriptions,
    );
  }

  /// 附着一个 tmux 目标：带 PTY 的 exec 通道直接跑附着脚本（[tmuxAttachScript]），不开交互式 shell、
  /// 不往 shell 里打字，也就不受用户 .bashrc 里自动 tmux 的影响、不进 shell 历史。新开和恢复走同一条路：
  /// 恢复时远端照样先核对目标身份，对不上就以 [TmuxTargetGoneException] 失败，不新建、不按名字附着。
  ///
  /// 握手：脚本核对通过后报一行本客户端的终端设备和 pid，再关回显等 App 回一个换行。
  /// 那一行之前的字节（比如登录脚本的输出）不进终端；App 收到后先绑定终端（把当前尺寸发过去），
  /// 再回换行，tmux 一附着就是正确的大小。
  Future<ActiveTerminalSession> _openTmuxAttach(
    String sessionId,
    HostProfile host,
    RoutePlan plan,
    List<SSHClient> clients,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    TerminalSessionAdapter terminal,
    ConnectionAttempt pending,
    TmuxTarget target,
  ) async {
    final client = clients.last;
    pending.report(const ConnectionStage(ConnectionStep.shell));
    final session = await _atHop(
      plan,
      plan.hops.length - 1,
      '附着 tmux 失败',
      () => pending.waitFor(
        client.execute(
          tmuxAttachCommand(target),
          pty:
              const SSHPtyConfig(type: 'xterm-256color', width: 80, height: 24),
          environment: _environment(plan.target.host),
        ),
        onCancelled: (value) => value.close(),
      ),
    );
    pending.shell = session;

    final greeting = BytesBuilder(copy: false);
    final ready = Completer<({String tty, int pid, Uint8List rest})>();
    void Function(Uint8List chunk)? forward;
    final stdout = session.stdout.listen(
      (chunk) {
        final deliver = forward;
        if (deliver != null) {
          deliver(chunk);
          return;
        }
        if (ready.isCompleted) return;
        greeting.add(chunk);
        final bytes = greeting.toBytes();
        final text = latin1.decode(bytes);
        final at = text.indexOf(tmuxAttachMarker);
        final end = at < 0 ? -1 : text.indexOf(RegExp(r'[\r\n]'), at);
        if (end >= 0) {
          final marker = parseAttachMarker(text.substring(at, end));
          if (marker == null) {
            ready.completeError(
              const TmuxCommandException('远端报回的 tmux 客户端信息无法识别，没有附着'),
            );
            return;
          }
          var restAt = end;
          while (restAt < bytes.length &&
              (bytes[restAt] == 0x0d || bytes[restAt] == 0x0a)) {
            restAt++;
          }
          ready.complete((
            tty: marker.tty,
            pid: marker.pid,
            rest: Uint8List.sublistView(bytes, restAt),
          ));
        } else if (bytes.length > 16 * 1024) {
          ready.completeError(
            const TmuxCommandException('附着前远端输出了太多内容，没有附着'),
          );
        }
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(const _AttachEndedEarly());
        }
      },
      onError: (Object error) {
        if (!ready.isCompleted) ready.completeError(error);
      },
    );
    final ({String tty, int pid, Uint8List rest}) marker;
    try {
      marker = await pending.waitFor(
        ready.future.timeout(const Duration(seconds: 15)),
      );
    } on _AttachEndedEarly {
      await stdout.cancel();
      // 脚本在核对时就退出了：按约定的退出码说清楚（不在了 / 换了用户 / 没有 tmux）。
      await session.done.timeout(const Duration(seconds: 2), onTimeout: () {});
      throw tmuxExitError(session.exitCode, '') ??
          const TmuxCommandException('tmux 附着脚本意外结束');
    } on TimeoutException {
      await stdout.cancel();
      throw const TmuxCommandException('远端 15 秒内没有完成 tmux 附着前的核对，已放弃');
    } catch (_) {
      await stdout.cancel();
      rethrow;
    }
    // 先绑定（新代次一绑定就把终端当前尺寸发过去），再放行 tmux。
    final binding =
        terminal.bind(session.write, resize: session.resizeTerminal);
    forward = terminal.feed;
    if (marker.rest.isNotEmpty) terminal.feed(marker.rest);
    final subscriptions = [stdout, session.stderr.listen(terminal.feed)];
    session.write(Uint8List.fromList(const [0x0a]));
    return ActiveTerminalSession(
      id: sessionId,
      host: host,
      terminal: terminal,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
      sshClients: clients,
      sshSession: session,
      routePlan: plan,
      tmux: TmuxClientBinding(
        target: target,
        clientTty: marker.tty,
        clientPid: marker.pid,
      ),
      binding: binding,
      outputSubscriptions: subscriptions,
    );
  }

  /// 执行路线上第 [index] 跳的一个阶段。失败时换成指明哪台机器、哪一步、什么原因的报错
  /// （[RouteHopException]），不只给一句 dartssh2 的「认证前连接已关闭」。取消原样抛出。
  Future<T> _atHop<T>(
    RoutePlan plan,
    int index,
    String stage,
    Future<T> Function() step, {
    SshBannerDeadlineSocket? guard,
  }) async {
    try {
      return await step();
    } on ConnectionCancelledException {
      rethrow;
    } catch (error) {
      final hop = plan.hops[index];
      final who = index == plan.jumps.length
          ? '目标“${hop.host.label}”'
          : '跳板机“${hop.host.label}”';
      final reason = guard?.expired == true
          ? '${_connectTimeout(hop.host).inSeconds} 秒内没有收到 SSH 版本信息，端口上可能不是 SSH 服务或服务卡住了'
          : _describeSshError(error);
      throw RouteHopException(
        index,
        '$who（${hop.endpoint.authority}）$stage：$reason',
        error,
        relayed: index > 0 || plan.entry is ProxyEntry,
      );
    }
  }

  static String _describeSshError(Object error) => switch (error) {
        SSHHostkeyError() ||
        SSHAuthAbortError(reason: SSHHostkeyError()) =>
          '主机指纹没有通过校验，已在发送任何登录信息之前断开',
        SSHAuthFailError() => '登录被拒绝：用户名、密码或私钥不对',
        SSHAuthAbortError() => '登录完成前连接被对方关闭：对方可能不是 SSH 服务，或者中途断开了',
        SSHChannelOpenError(:final description) => '对方拒绝打开转发通道（$description）',
        SshIdentityException(:final message) => message,
        _ => '$error',
      };

  SSHClient _createClient(
    SSHSocket socket,
    RouteHop hop,
    List<SSHKeyPair>? identities,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    SshLoginWatch watch,
  ) {
    // 登录身份只取这一跳自己的（用户名、密码、私钥），和代理账号无关。
    final host = hop.host;
    Future<bool> verify(String type, Uint8List fingerprint) async {
      final accepted =
          await verifyHostKey(host, type, utf8.decode(fingerprint));
      if (accepted) watch.hostKeyAccepted();
      return accepted;
    }

    if (watch.mode == SshLoginMode.tailscale) {
      // Tailscale SSH：不给 dartssh2 任何私钥、密码、键盘交互回调，它就只剩 none 一种方法可发
      // （dartssh2 2.22.5 `_startAuthentication`）。密码和私钥哪怕存着也不发：
      // tailssh 收到密码或公钥时根本不看内容，照样按 tailnet 策略放行（tailssh.go ServerConfig）。
      return SSHClient(
        socket,
        username: host.username,
        printDebug: watch.debug,
        onUserauthBanner: watch.banner,
        keepAliveInterval: Duration(
          seconds: (host.data['keepaliveInterval'] as num?)?.toInt() ?? 10,
        ),
        onVerifyHostKey: verify,
      );
    }
    var passwordAnswered = false;
    return SSHClient(
      socket,
      username: host.username,
      identities: identities,
      onPasswordRequest:
          host.authMethod == HostAuthMethod.key || host.password == null
              ? null
              : () => host.password,
      onUserInfoRequest: (request) async {
        if (keyboardInteractive != null) {
          return keyboardInteractive(
            request.name,
            request.instruction,
            request.prompts
                .map((prompt) => (text: prompt.promptText, echo: prompt.echo))
                .toList(),
          );
        }
        // 没有界面可问（测试、以后的后台探测）：只在明确问密码时填一次保存的密码，
        // 验证码、PIN、新密码之类一律不答（见 savedPasswordAnswer）。
        final answer = savedPasswordAnswer(
          request.prompts
              .map((prompt) => (text: prompt.promptText, echo: prompt.echo))
              .toList(),
          host.password,
          alreadyAnswered: passwordAnswered,
        );
        if (answer != null && answer.isNotEmpty) passwordAnswered = true;
        return answer;
      },
      printDebug: watch.debug,
      onUserauthBanner: watch.banner,
      keepAliveInterval: Duration(
        seconds: (host.data['keepaliveInterval'] as num?)?.toInt() ?? 10,
      ),
      authTimeout: _authTimeout(host),
      onVerifyHostKey: verify,
    );
  }

  Duration _authTimeout(HostProfile host) => Duration(
        seconds:
            (host.data['sshAuthReadyTimeoutSeconds'] as num?)?.toInt() ?? 30,
      );

  Duration _connectTimeout(HostProfile host) => Duration(
        seconds:
            (host.data['sshTcpConnectTimeoutSeconds'] as num?)?.toInt() ?? 15,
      );

  Map<String, String> _environment(HostProfile host) {
    final result = <String, String>{};
    for (final value
        in host.data['environmentVariables'] as List? ?? const []) {
      if (value is Map && value['name'] != null) {
        result[value['name'].toString()] = value['value']?.toString() ?? '';
      }
    }
    return result;
  }

  /// 建手机上的第一条连接：直连 [first]，或者先连代理再让代理 CONNECT 到 [first]。
  /// 路线已经校验过，这里不再判断配置是否有效；握手细节见 transport/proxy_transport.dart。
  Future<SSHSocket> _openTransport(
    RouteEntry entry,
    RouteHop firstHop,
    int hopCount,
    Duration timeout,
    ConnectionAttempt pending,
  ) async {
    final first = firstHop.endpoint;
    final proxy = switch (entry) {
      DirectEntry() => null,
      ProxyEntry value => value,
    };
    if (proxy == null) {
      pending.report(ConnectionStage(
        ConnectionStep.dial,
        hopCount: hopCount,
        label: firstHop.host.label,
        detail: first.authority,
      ));
      final socket = await _dialWithin(first, timeout);
      pending.directPeer = _peerOf(socket);
      return DirectSshSocket(socket);
    }
    // 只显示代理端点，不显示代理账号。
    pending.report(ConnectionStage(
      ConnectionStep.proxy,
      hopCount: hopCount,
      label: firstHop.host.label,
      detail: proxy.endpoint.authority,
    ));
    final socket = await _dialWithin(proxy.endpoint, timeout);
    if (pending.isCancelled) {
      socket.destroy();
      throw const ConnectionCancelledException();
    }
    // 握手期间登记这条 socket：用户取消时立刻关掉它（SOX03），不用等握手期限走完。
    pending.handshakeSocket = socket;
    try {
      return await proxyHandshake(socket, proxy, first, deadline: timeout);
    } finally {
      if (identical(pending.handshakeSocket, socket)) {
        pending.handshakeSocket = null;
      }
    }
  }

  /// 已连上的 socket 的对端 IP。测试替身可能不支持，拿不到就是 null。
  static InternetAddress? _peerOf(Socket socket) {
    try {
      return socket.remoteAddress;
    } on Object {
      return null;
    }
  }

  /// TCP 拨号加一层硬期限：拨号器自己的 timeout 之外再兜底，注入的拨号器不守时也不会无限等（NET07）。
  /// 期限到了之后才连上的 socket 会被立刻关掉，不会漏成一条没人管的连接。
  Future<Socket> _dialWithin(Endpoint endpoint, Duration timeout) {
    final attempt = _dial(endpoint.host, endpoint.port, timeout: timeout);
    return attempt.timeout(
      timeout,
      onTimeout: () {
        unawaited(
          attempt.then((late) => late.destroy(), onError: (Object _) {}),
        );
        throw ConnectStageException(
          'TCP 连接超时（${endpoint.authority}，${timeout.inSeconds} 秒）',
        );
      },
    );
  }

  Future<ActiveTerminalSession> _connectTelnet(
    String sessionId,
    HostProfile host,
    RoutePlan plan,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    TerminalSessionAdapter terminal,
    ConnectionAttempt pending,
  ) async {
    final endpoint = plan.target.endpoint;
    pending.report(ConnectionStage(
      ConnectionStep.dial,
      label: plan.target.host.label,
      detail: endpoint.authority,
    ));
    final socket = await pending.waitFor(
      _dialWithin(endpoint, const Duration(seconds: 15)),
      onCancelled: (value) => value.destroy(),
    );
    pending.telnetSocket = socket;
    pending.throwIfCancelled();
    final binding = terminal.bind(socket.add);
    final output = socket.listen(
      (bytes) {
        final visible = <int>[];
        for (var i = 0; i < bytes.length; i++) {
          if (bytes[i] == 255 && i + 2 < bytes.length) {
            final command = bytes[i + 1];
            final option = bytes[i + 2];
            socket.add([255, command == 253 ? 252 : 254, option]);
            i += 2;
          } else {
            visible.add(bytes[i]);
          }
        }
        terminal.feed(Uint8List.fromList(visible));
      },
      onError: (Object _) {},
    );
    return ActiveTerminalSession(
      id: sessionId,
      host: host,
      terminal: terminal,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
      telnetSocket: socket,
      routePlan: plan,
      binding: binding,
      outputSubscriptions: [output],
    );
  }
}

const _connectionCancelledMarker = Object();

class _PendingConnectionResult<T> {
  const _PendingConnectionResult(this.value);
  final T value;
}

/// 一次连接尝试（新开或恢复）的取消令牌和半成品清单。
///
/// 由调用方创建：这样调用方在 [SshService.connect] 真正开始拨号之前（比如还在等保险库解锁）
/// 就能取消它，取消后 connect 一开头就放弃，不会先连上再关（R08）。
///
/// [generation] 是调用方分配的代次号，单调递增。调用方拿它判断一个结果是不是「当前这一次」的；
/// 不是的一律关掉——迟到的结果不能复活已经取消、关闭或被替换的连接（NET09）。
class ConnectionAttempt {
  ConnectionAttempt({this.generation = 0, this.onStage, this.onCheckPrompt});

  final int generation;

  /// 阶段回调。只在尝试还有效时调用，按发生顺序；取消后、移交后都不再调用。
  void Function(ConnectionStage stage)? onStage;

  /// Tailscale check 要用户处理时回调；处理完（成功、失败、超时）回调 null。
  /// 和 [onStage] 一样，取消后、移交后都不再调用。
  void Function(TailscaleCheckPrompt? prompt)? onCheckPrompt;

  final cancelled = Completer<void>();
  final clients = <SSHClient>[];
  SSHSocket? transport;

  /// 直连时手机这条 TCP 实际连上的 IP（主机名由系统解析后的结果）。经代理时没有：手机只连了代理。
  /// Mosh 的 UDP 就发往它（[SshService.bootstrapMosh]）。
  InternetAddress? directPeer;
  Socket? telnetSocket;
  SSHSession? shell;

  /// 正在和代理握手的 socket。握手还没完成时它还不是 [transport]，不单独登记的话，
  /// 取消后它要等握手期限走完才会被关。
  Socket? handshakeSocket;

  /// 资源已经交给返回的会话。之后取消只标记失效，不再关这些资源——它们归会话所有。
  bool _handedOver = false;
  ConnectionStage? _stage;
  TailscaleCheckPrompt? _checkPrompt;

  bool get isCancelled => cancelled.isCompleted;
  ConnectionStage? get stage => _stage;
  TailscaleCheckPrompt? get checkPrompt => _checkPrompt;

  void report(ConnectionStage stage) {
    if (isCancelled || _handedOver) return;
    _stage = stage;
    onStage?.call(stage);
  }

  void reportCheck(TailscaleCheckPrompt? prompt) {
    if (isCancelled || _handedOver) return;
    _checkPrompt = prompt;
    onCheckPrompt?.call(prompt);
  }

  /// 使这次尝试失效，并立刻关掉它已经建好的一切。可以重复调用。
  void cancel() {
    if (cancelled.isCompleted) return;
    cancelled.complete();
    releasePartial();
  }

  void handOver() => _handedOver = true;

  /// 关掉这次尝试已建好、还没交出去的资源：从 PTY 往外，目标 client 到第一跳逆序关，
  /// 再关还没被 client 接管的 socket。外部代理服务本身不动。可以重复调用。
  void releasePartial() {
    if (_handedOver) return;
    shell?.close();
    for (final client in clients.reversed) {
      client.close();
    }
    transport?.destroy();
    handshakeSocket?.destroy();
    telnetSocket?.destroy();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const ConnectionCancelledException();
  }

  Future<T> waitFor<T>(
    Future<T> operation, {
    void Function(T value)? onCancelled,
  }) async {
    throwIfCancelled();
    final Object winner;
    try {
      winner = await Future.any<Object>([
        operation.then<Object>(_PendingConnectionResult<T>.new),
        cancelled.future.then<Object>((_) => _connectionCancelledMarker),
      ]);
    } catch (_) {
      // cancel() 会顺手关掉正在用的 socket，由此引发的「连接被关闭」可能比取消信号先到。
      // 用户点的是取消，就报取消，不报这个副作用。
      if (isCancelled) throw const ConnectionCancelledException();
      rethrow;
    }
    if (identical(winner, _connectionCancelledMarker)) {
      unawaited(
        operation.then<void>((value) {
          onCancelled?.call(value);
        }).catchError((Object _) {}),
      );
      throw const ConnectionCancelledException();
    }
    return (winner as _PendingConnectionResult<T>).value;
  }
}

/// 附着脚本在报出客户端信息之前就结束了（核对没通过）。只在 [SshService] 内部用来换成具体的说法。
class _AttachEndedEarly implements Exception {
  const _AttachEndedEarly();
}
