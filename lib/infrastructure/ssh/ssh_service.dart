import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/models/server_stats.dart';
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
          // 只有第一跳由手机拨出（直连或经代理）；后面每一跳都经上一跳的 SSH 转发到达。
          final activeTransport = transport ??
              await pending.waitFor<SSHSocket>(
                _openTransport(
                  plan.entry,
                  hop.endpoint,
                  timeout: _connectTimeout(hop.host),
                ),
                onCancelled: (socket) => socket.destroy(),
              );
          transport = activeTransport;
          pending.transport = activeTransport;
          pending.throwIfCancelled();
          final client = _createClient(
            activeTransport,
            hop,
            verifyHostKey,
            keyboardInteractive,
          );
          clients.add(client);
          pending.clients.add(client);
          pending.throwIfCancelled();
          if (index < hops.length - 1) {
            final next = hops[index + 1].endpoint;
            transport = await pending.waitFor<SSHForwardChannel>(
              client.forwardLocal(next.host, next.port),
              onCancelled: (socket) => socket.destroy(),
            );
            pending.transport = transport;
          }
        }

        final target = plan.target.host;
        final client = clients.last;
        final session = await pending.waitFor(
          client.shell(
            pty: const SSHPtyConfig(
                type: 'xterm-256color', width: 80, height: 24),
            environment: _environment(target),
          ),
          onCancelled: (value) => value.close(),
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
  /// 路线已经校验过，这里不再判断配置是否有效。
  Future<SSHSocket> _openTransport(
    RouteEntry entry,
    Endpoint first, {
    required Duration timeout,
  }) async {
    final proxy = switch (entry) {
      DirectEntry() => null,
      ProxyEntry value => value,
    };
    if (proxy == null) {
      return _DirectSshSocket(
        await _dial(first.host, first.port, timeout: timeout),
      );
    }
    final socket = await _dial(
      proxy.endpoint.host,
      proxy.endpoint.port,
      timeout: timeout,
    );
    final cursor = _SocketCursor(socket);
    try {
      // 握手总截止时间。以前只有 TCP 建连有超时，代理接受连接后不回话就会永远卡住（NET03）。
      final handshake = switch (proxy.type) {
        ProxyType.http => _connectHttpProxy(socket, cursor, proxy, first),
        ProxyType.socks5 => _connectSocksProxy(socket, cursor, proxy, first),
      };
      await handshake.timeout(
        timeout,
        onTimeout: () => throw SocketException(
          '代理握手超时（${proxy.endpoint.authority}，${timeout.inSeconds} 秒）',
        ),
      );
      return _ProxySshSocket(socket, cursor);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  Future<void> _connectHttpProxy(
    Socket socket,
    _SocketCursor cursor,
    ProxyEntry proxy,
    Endpoint target,
  ) async {
    // IPv6 要加方括号：以前拼成 `::1:22`，代理分不清哪段是端口（NET04）。
    final authority = target.authority;
    final auth = proxy.username?.isNotEmpty == true
        ? 'Proxy-Authorization: Basic ${base64Encode(utf8.encode('${proxy.username}:${proxy.password ?? ''}'))}\r\n'
        : '';
    socket.write(
      'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n$auth'
      'Proxy-Connection: keep-alive\r\n\r\n',
    );
    await socket.flush();
    final header = utf8.decode(
      await cursor.readUntil(const [13, 10, 13, 10], maxLength: 32768),
      allowMalformed: true,
    );
    final match = RegExp(r'^HTTP/\d(?:\.\d)?\s+(\d{3})').firstMatch(header);
    if (match == null || match.group(1) != '200') {
      throw SocketException('HTTP 代理连接失败：${header.split('\r\n').first}');
    }
  }

  Future<void> _connectSocksProxy(
    Socket socket,
    _SocketCursor cursor,
    ProxyEntry proxy,
    Endpoint target,
  ) async {
    final hasAuth = proxy.username?.isNotEmpty == true;
    socket.add(hasAuth ? [5, 2, 0, 2] : [5, 1, 0]);
    await socket.flush();
    final greeting = await cursor.readExact(2);
    if (greeting[0] != 5 || greeting[1] == 255) {
      throw const SocketException('SOCKS5 代理拒绝认证方式');
    }
    if (greeting[1] == 2) {
      final user = utf8.encode(proxy.username ?? '');
      final pass = utf8.encode(proxy.password ?? '');
      if (user.length > 255 || pass.length > 255) {
        throw const SocketException('SOCKS5 代理用户名或密码过长');
      }
      socket.add([1, user.length, ...user, pass.length, ...pass]);
      await socket.flush();
      final auth = await cursor.readExact(2);
      if (auth[1] != 0) throw const SocketException('SOCKS5 代理认证失败');
    } else if (greeting[1] != 0) {
      throw const SocketException('SOCKS5 代理认证方式不受支持');
    }
    // 按地址类型编码（NET04）：以前 IP 字面量也当域名（ATYP 3）发，IPv6 还会带上冒号原样发出。
    // 域名交给代理解析，手机不提前解析目标名。
    final address = switch (target.kind) {
      EndpointKind.ipv4 => [1, ...InternetAddress(target.host).rawAddress],
      EndpointKind.ipv6 => [4, ...InternetAddress(target.host).rawAddress],
      EndpointKind.domain => [
          3,
          target.host.length,
          ...ascii.encode(target.host),
        ],
    };
    socket.add([5, 1, 0, ...address, target.port >> 8, target.port & 0xff]);
    await socket.flush();
    final reply = await cursor.readExact(4);
    if (reply[0] != 5 || reply[1] != 0) {
      throw SocketException('SOCKS5 代理连接失败，状态码 ${reply[1]}');
    }
    final addressLength = switch (reply[3]) {
      1 => 4,
      3 => (await cursor.readExact(1)).first,
      4 => 16,
      _ => throw const SocketException('SOCKS5 返回了未知地址类型'),
    };
    await cursor.readExact(addressLength + 2);
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
      _dial(
        endpoint.host,
        endpoint.port,
        timeout: const Duration(seconds: 15),
      ),
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

  bool get isCancelled => cancelled.isCompleted;

  void cancel() {
    if (cancelled.isCompleted) return;
    cancelled.complete();
    telnetSocket?.destroy();
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
    final winner = await Future.any<Object>([
      operation.then<Object>(_PendingConnectionResult<T>.new),
      cancelled.future.then<Object>((_) => _connectionCancelledMarker),
    ]);
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

class _SocketCursor {
  _SocketCursor(Socket socket) : _iterator = StreamIterator(socket);

  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = [];

  Future<List<int>> readExact(int length) async {
    await _fill(length);
    final result = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return result;
  }

  Future<List<int>> readUntil(
    List<int> marker, {
    required int maxLength,
  }) async {
    while (true) {
      final index = _indexOf(_buffer, marker);
      if (index >= 0) {
        final end = index + marker.length;
        final result = _buffer.sublist(0, end);
        _buffer.removeRange(0, end);
        return result;
      }
      if (_buffer.length >= maxLength) {
        throw const SocketException('代理响应头过长');
      }
      if (!await _iterator.moveNext()) {
        throw const SocketException('代理在握手完成前关闭了连接');
      }
      _buffer.addAll(_iterator.current);
    }
  }

  Future<void> _fill(int length) async {
    while (_buffer.length < length) {
      if (!await _iterator.moveNext()) {
        throw const SocketException('代理在握手完成前关闭了连接');
      }
      _buffer.addAll(_iterator.current);
    }
  }

  Stream<Uint8List> remainingStream() async* {
    if (_buffer.isNotEmpty) {
      yield Uint8List.fromList(_buffer);
      _buffer.clear();
    }
    while (await _iterator.moveNext()) {
      yield _iterator.current;
    }
  }

  static int _indexOf(List<int> source, List<int> marker) {
    for (var index = 0; index <= source.length - marker.length; index++) {
      var matches = true;
      for (var offset = 0; offset < marker.length; offset++) {
        if (source[index + offset] != marker[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) return index;
    }
    return -1;
  }
}

/// 直连 socket 的 SSHSocket 包装，和 dartssh2 自带的等价；
/// 自己包是为了让直连也走 [TcpDialer]，所有拨号都能被记录。
class _DirectSshSocket implements SSHSocket {
  _DirectSshSocket(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}

class _ProxySshSocket implements SSHSocket {
  _ProxySshSocket(this._socket, this._cursor);

  final Socket _socket;
  final _SocketCursor _cursor;

  @override
  Stream<Uint8List> get stream => _cursor.remainingStream();

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}
