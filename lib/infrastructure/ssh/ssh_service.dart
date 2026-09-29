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
  }) : input = input ?? TerminalInputController();

  final String id;
  final HostProfile host;
  final Terminal terminal;
  final HostKeyVerifier verifyHostKey;
  final KeyboardInteractiveHandler? keyboardInteractive;
  final TerminalInputController input;
  final List<SSHClient> sshClients;
  final SSHSession? sshSession;
  final Socket? telnetSocket;
  bool connected = true;
  bool closedByUser = false;
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

  void abort() {
    monitor?.stop();
    connected = false;
    sshSession?.close();
    for (final client in sshClients.reversed) {
      client.close();
    }
    telnetSocket?.destroy();
  }

  Future<void> close() async {
    monitor?.stop();
    closedByUser = true;
    connected = false;
    sshSession?.close();
    for (final client in sshClients.reversed) {
      client.close();
    }
    await telnetSocket?.close();
    input.dispose();
  }
}

class SshService {
  SshService({TcpDialer? dialer}) : _dial = dialer ?? _systemDial;

  final TcpDialer _dial;
  final _pendingConnections = <String, _PendingConnection>{};

  void cancelConnection(String sessionId) {
    _pendingConnections[sessionId]?.cancel();
  }

  Future<ActiveTerminalSession> connect({
    required String sessionId,
    required HostProfile host,
    required List<HostProfile> hosts,
    required List<SshKeyProfile> keys,
    required List<ProxyProfile> proxyProfiles,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    Terminal? terminal,
    ConnectionPurpose purpose = ConnectionPurpose.fresh,
  }) async {
    _pendingConnections.remove(sessionId)?.cancel();
    final pending = _PendingConnection();
    _pendingConnections[sessionId] = pending;
    try {
      if (host.protocol == HostProtocol.mosh) {
        throw UnsupportedError('Mosh 需要平台原生 UDP 运行时，当前版本尚未启用。');
      }
      // 路线在任何拨号之前一次算好：配置有问题此时就抛 RouteConfigException，一个连接都没开。
      // 之后全程只用 plan 里的快照，连接中途用户改了主机、跳板或代理，只影响下一次连接（RTE03）。
      final plan = resolveRoutePlan(
        host,
        hosts: hosts,
        proxyProfiles: proxyProfiles,
        keys: keys,
      );
      if (plan.protocol == HostProtocol.telnet) {
        return await _connectTelnet(
          sessionId,
          host,
          plan.target.endpoint,
          verifyHostKey,
          keyboardInteractive,
          terminal,
          pending,
        );
      }

      final hops = plan.hops;
      final clients = <SSHClient>[];
      SSHSocket? transport;
      try {
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
                  _openTransport(plan.entry, hop.endpoint, timeout, pending),
                  onCancelled: (socket) => socket.destroy(),
                ),
              );
          // 版本行攒齐再交给 dartssh2，且这一段有期限（见 SshBannerDeadlineSocket）。
          final guard = SshBannerDeadlineSocket(reached, timeout);
          transport = guard;
          pending.transport = guard;
          pending.throwIfCancelled();
          final client = _createClient(
            guard,
            hop,
            verifyHostKey,
            keyboardInteractive,
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
        final session = await _atHop(
          plan,
          hops.length - 1,
          '打开终端失败',
          () => pending.waitFor(
            client.shell(
              pty: const SSHPtyConfig(
                  type: 'xterm-256color', width: 80, height: 24),
              environment: _environment(target),
            ),
            onCancelled: (value) => value.close(),
          ),
        );
        final output = terminal ?? Terminal(maxLines: 10000);
        final input = TerminalInputController();
        output.onOutput = (value) => session.write(
              Uint8List.fromList(utf8.encode(input.consume(value))),
            );
        output.onResize = (width, height, pixelWidth, pixelHeight) {
          session.resizeTerminal(width, height, pixelWidth, pixelHeight);
        };
        decodeTerminalText(session.stdout).listen(output.write);
        decodeTerminalText(session.stderr).listen(output.write);
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
        );
      } catch (_) {
        for (final client in clients.reversed) {
          client.close();
        }
        rethrow;
      }
    } finally {
      if (identical(_pendingConnections[sessionId], pending)) {
        _pendingConnections.remove(sessionId);
      }
    }
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
    Endpoint first,
    Duration timeout,
    _PendingConnection pending,
  ) async {
    final proxy = switch (entry) {
      DirectEntry() => null,
      ProxyEntry value => value,
    };
    if (proxy == null) {
      return DirectSshSocket(await _dialWithin(first, timeout));
    }
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
    Endpoint endpoint,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    Terminal? existingTerminal,
    _PendingConnection pending,
  ) async {
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
    decodeTerminalText(text.stream).listen(terminal.write);
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

class _PendingConnection {
  final cancelled = Completer<void>();
  final clients = <SSHClient>[];
  SSHSocket? transport;
  Socket? telnetSocket;

  /// 正在和代理握手的 socket。握手还没完成时它还不是 [transport]，不单独登记的话，
  /// 取消后它要等握手期限走完才会被关。
  Socket? handshakeSocket;

  bool get isCancelled => cancelled.isCompleted;

  void cancel() {
    if (cancelled.isCompleted) return;
    cancelled.complete();
    telnetSocket?.destroy();
    handshakeSocket?.destroy();
    transport?.destroy();
    for (final client in clients.reversed) {
      client.close();
    }
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
