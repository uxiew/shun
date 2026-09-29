import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/models/server_stats.dart';
import '../transport/proxy_transport.dart';
import 'server_monitor_service.dart';

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
  const RouteHopException(this.hop, this.message, this.cause);

  /// 从 0 数的跳序号；等于跳板数时就是目标。
  final int hop;
  final String message;

  /// 原始错误，给测试和日志用；界面只显示 [message]。
  final Object cause;

  @override
  String toString() => message;
}

/// 这次连接是用户新开的，还是断线后的恢复。
///
/// 只有 [fresh] 会执行主机的 startupCommand。恢复时重跑它等于替用户再执行一遍命令——
/// 对托管终端（startupCommand 就是那条管理命令）尤其危险（A04 / REG02）。
enum ConnectionPurpose { fresh, restore }

enum ConnectionStep { dial, proxy, handshake, forward, shell }

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
      ConnectionStep.forward => '$prefix“$label”：转发到下一跳（$detail）',
      ConnectionStep.shell => '正在打开终端',
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

/// Applies one-shot toolbar modifiers to the next system-keyboard input.
/// This bridges Flutter's soft keyboard and the terminal toolbar, which do
/// not share hardware modifier state on Android or iOS.
class TerminalInputController extends ChangeNotifier {
  Set<String> modifiers = const {};

  void setModifiers(Iterable<String> value) {
    final next = Set<String>.unmodifiable(value);
    if (setEquals(next, modifiers)) return;
    modifiers = next;
    notifyListeners();
  }

  void clearModifiers() => setModifiers(const {});

  String consume(String value) {
    final active = modifiers;
    if (active.isEmpty || value.isEmpty) return value;
    modifiers = const {};
    notifyListeners();
    final shift = active.contains('shift');
    final alt = active.contains('alt');
    final ctrl = active.contains('ctrl');
    final parameter = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
    var result = value;
    if (result.length == 3 &&
        result.startsWith('\x1b[') &&
        'ABCDHF'.contains(result[2])) {
      result = '\x1b[1;$parameter${result[2]}';
    } else {
      if (shift && result.length == 1) result = result.toUpperCase();
      if (ctrl && result.length == 1) {
        final code = result.toUpperCase().codeUnitAt(0);
        if (code >= 64 && code <= 95) {
          result = String.fromCharCode(code & 0x1f);
        }
      }
      if (alt) result = '\x1b$result';
    }
    return result;
  }
}

class ActiveTerminalSession {
  ActiveTerminalSession({
    required this.id,
    required this.host,
    required this.terminal,
    required this.verifyHostKey,
    required this.keyboardInteractive,
    TerminalInputController? input,
    this.sshClients = const [],
    this.sshSession,
    this.telnetSocket,
    this.routePlan,
    List<StreamSubscription<Object?>> outputSubscriptions = const [],
  })  : input = input ?? TerminalInputController(),
        _outputSubscriptions = outputSubscriptions;

  final String id;
  final HostProfile host;
  final Terminal terminal;
  final HostKeyVerifier verifyHostKey;
  final KeyboardInteractiveHandler? keyboardInteractive;
  final TerminalInputController input;
  final List<SSHClient> sshClients;
  final SSHSession? sshSession;
  final Socket? telnetSocket;

  /// 建这条连接时冻结的路线（含每一跳的主机配置和私钥副本）。断线恢复沿用它：
  /// 自动恢复只能走同一条路线，不能因为用户期间改了配置就悄悄换代理、换身份（NET10，docs/07）。
  /// 手工构造的会话（测试）可能没有，恢复时再按保险库现算。
  final RoutePlan? routePlan;

  /// 远端输出写进 [terminal] 的订阅。恢复时新旧连接共用同一个 terminal，
  /// 旧连接释放时必须先断开这里，旧通道迟到的字节才不会混进新 shell 的画面。
  final List<StreamSubscription<Object?>> _outputSubscriptions;
  bool connected = true;
  bool closedByUser = false;
  bool _released = false;
  bool _outputDetached = false;
  bool _inputDisposed = false;
  ServerSystemInfo? systemInfo;
  SessionMonitor? monitor;

  SSHClient? get sshClient => sshClients.isEmpty ? null : sshClients.last;
  bool get isSsh => sshClient != null;
  Future<void> get done =>
      sshSession?.done ?? telnetSocket?.done ?? Future.value();

  Future<void> ping({Duration timeout = const Duration(seconds: 8)}) async {
    if (!connected) throw StateError('SSH session is disconnected');
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
  }

  /// 不再把这条连接的远端输出写进 [terminal]。可以重复调用。
  ///
  /// 恢复时新旧连接共用同一个 terminal：换上新连接前必须先调它，
  /// 旧通道迟到的字节才不会混进新 shell 的画面（NET09）。
  void detachOutput() {
    if (_outputDetached) return;
    _outputDetached = true;
    for (final subscription in _outputSubscriptions) {
      unawaited(subscription.cancel());
    }
  }

  /// 用户关标签：断开输出、释放网络资源、销毁输入控制器。重复调用无副作用。
  ///
  /// [abort] 不销毁输入控制器：断线后页面可能还挂着它，销毁了再触碰会在 debug 下断言失败。
  Future<void> close() async {
    closedByUser = true;
    detachOutput();
    abort();
    if (_inputDisposed) return;
    _inputDisposed = true;
    input.dispose();
  }
}

class SshService {
  SshService({TcpDialer? dialer}) : _dial = dialer ?? _systemDial;

  final TcpDialer _dial;
  final _pendingConnections = <String, ConnectionAttempt>{};

  void cancelConnection(String sessionId) {
    _pendingConnections[sessionId]?.cancel();
  }

  /// 建一条终端连接。
  ///
  /// 新开连接传保险库里的 [hosts]、[keys]、[proxyProfiles]，由这里现算路线；
  /// 恢复连接传原来的 [routePlan]，沿用同一条路线，不重新读配置（NET10）。
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
    Terminal? terminal,
    ConnectionPurpose purpose = ConnectionPurpose.fresh,
    ConnectionAttempt? attempt,
  }) async {
    final pending = attempt ?? ConnectionAttempt();
    final previous = _pendingConnections[sessionId];
    if (!identical(previous, pending)) previous?.cancel();
    _pendingConnections[sessionId] = pending;
    try {
      pending.throwIfCancelled();
      if (host.protocol == HostProtocol.mosh) {
        throw UnsupportedError('Mosh 需要平台原生 UDP 运行时，当前版本尚未启用。');
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

  Future<ActiveTerminalSession> _connectSsh(
    String sessionId,
    HostProfile host,
    RoutePlan plan,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    Terminal? terminal,
    ConnectionPurpose purpose,
    ConnectionAttempt pending,
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
      // 私钥解析是同步的，坏私钥或口令不对会在这里抛；也按这一跳报错。
      final client = await _atHop(
        plan,
        index,
        '读取登录私钥失败',
        () async => _createClient(guard, hop, verifyHostKey, keyboardInteractive),
      );
      clients.add(client);
      pending.clients.add(client);
      // 先等这一跳握手、验指纹、登录全部完成，失败时才分得清是这一跳本身，
      // 还是它往下一跳的转发（JMP02 / JMP04）。指纹没通过时 dartssh2 在认证前就断开。
      await _atHop(
        plan,
        index,
        'SSH 握手或登录失败',
        () => pending.waitFor<void>(client.authenticated),
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

    final target = plan.target.host;
    final client = clients.last;
    pending.report(const ConnectionStage(ConnectionStep.shell));
    final session = await _atHop(
      plan,
      hops.length - 1,
      '打开终端失败',
      () => pending.waitFor(
        client.shell(
          pty: const SSHPtyConfig(type: 'xterm-256color', width: 80, height: 24),
          environment: _environment(target),
        ),
        onCancelled: (value) => value.close(),
      ),
    );
    pending.shell = session;
    final output = terminal ?? Terminal(maxLines: 10000);
    final input = TerminalInputController();
    output.onOutput = (value) => session.write(
          Uint8List.fromList(utf8.encode(input.consume(value))),
        );
    output.onResize = (width, height, pixelWidth, pixelHeight) {
      session.resizeTerminal(width, height, pixelWidth, pixelHeight);
    };
    final subscriptions = [
      decodeTerminalText(session.stdout).listen(output.write),
      decodeTerminalText(session.stderr).listen(output.write),
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
      terminal: output,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
      input: input,
      sshClients: clients,
      sshSession: session,
      routePlan: plan,
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
        _ => '$error',
      };

  SSHClient _createClient(
    SSHSocket socket,
    RouteHop hop,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
  ) {
    // 登录身份只取这一跳自己的（用户名、密码、私钥），和代理账号无关。
    final host = hop.host;
    final identity = hop.key;
    final identities = identity == null || identity.privateKey.isEmpty
        ? null
        : SSHKeyPair.fromPem(identity.privateKey, identity.passphrase);
    return SSHClient(
      socket,
      username: host.username,
      identities:
          host.authMethod == HostAuthMethod.password ? null : identities,
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
        return request.prompts
            .map((prompt) => prompt.echo ? '' : (host.password ?? ''))
            .toList();
      },
      keepAliveInterval: Duration(
        seconds: (host.data['keepaliveInterval'] as num?)?.toInt() ?? 10,
      ),
      authTimeout: Duration(
        seconds:
            (host.data['sshAuthReadyTimeoutSeconds'] as num?)?.toInt() ?? 30,
      ),
      onVerifyHostKey: (type, fingerprint) => verifyHostKey(
        host,
        type,
        utf8.decode(fingerprint),
      ),
    );
  }

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
      return DirectSshSocket(await _dialWithin(first, timeout));
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
    Terminal? existingTerminal,
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
    final terminal = existingTerminal ?? Terminal(maxLines: 10000);
    final input = TerminalInputController();
    terminal.onOutput =
        (value) => socket.add(utf8.encode(input.consume(value)));
    // 同一个解码器跨 chunk 使用：多字节字符被网络切开时，前半截留到下一块再拼。
    final text = StreamController<List<int>>();
    final output = decodeTerminalText(text.stream).listen(terminal.write);
    socket.listen(
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
        text.add(visible);
      },
      onDone: text.close,
      onError: (Object _) => text.close(),
    );
    return ActiveTerminalSession(
      id: sessionId,
      host: host,
      terminal: terminal,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
      input: input,
      telnetSocket: socket,
      routePlan: plan,
      outputSubscriptions: [output],
    );
  }
}

/// 把远端字节流解成终端文本，整个流共用一个 UTF-8 解码器。
///
/// 以前每个网络 chunk 单独 `utf8.decode`：一个汉字（3 字节）或 emoji（4 字节）
/// 恰好被切在两个 chunk 之间时，两半各自变成 U+FFFD（�），中文输出随机乱码（A03 / TER01）。
/// xterm2 只收 String，所以这里仍要解码；换 Ghostty 后终端直接吃原始字节，不再经过这一步。
///
/// 用 bind 而不是 `bytes.transform(...)`：dartssh2 的 stdout 运行时是 `Stream<Uint8List>`，
/// transform 会因泛型协变在运行时报
/// `Utf8Decoder is not a subtype of StreamTransformer<Uint8List, String>`。
Stream<String> decodeTerminalText(Stream<List<int>> bytes) =>
    const Utf8Decoder(allowMalformed: true).bind(bytes);

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
  ConnectionAttempt({this.generation = 0, this.onStage});

  final int generation;

  /// 阶段回调。只在尝试还有效时调用，按发生顺序；取消后、移交后都不再调用。
  void Function(ConnectionStage stage)? onStage;

  final cancelled = Completer<void>();
  final clients = <SSHClient>[];
  SSHSocket? transport;
  Socket? telnetSocket;
  SSHSession? shell;

  /// 正在和代理握手的 socket。握手还没完成时它还不是 [transport]，不单独登记的话，
  /// 取消后它要等握手期限走完才会被关。
  Socket? handshakeSocket;

  /// 资源已经交给返回的会话。之后取消只标记失效，不再关这些资源——它们归会话所有。
  bool _handedOver = false;
  ConnectionStage? _stage;

  bool get isCancelled => cancelled.isCompleted;
  ConnectionStage? get stage => _stage;

  void report(ConnectionStage stage) {
    if (isCancelled || _handedOver) return;
    _stage = stage;
    onStage?.call(stage);
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
