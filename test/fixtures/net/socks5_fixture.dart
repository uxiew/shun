import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 故意做坏的方式。正常路径用 [Socks5Fault.none]。
enum Socks5Fault {
  none,

  /// 方法选择回 0xFF（没有可接受的认证方式）。
  rejectAllMethods,

  /// 收到问候后直接断开。
  closeAfterGreeting,

  /// 收到问候后永远不回：测握手超时。
  stallAfterGreeting,

  /// 选中无认证（0x00），即使客户端提供了用户名密码——测"要求密码时不能接受无认证"。
  forceNoAuth,

  /// CONNECT 回复非零状态码（见 [Socks5Fixture.connectReplyCode]）。
  connectError,
}

/// 一次 SOCKS5 会话里代理实际看到的东西。
class Socks5Attempt {
  List<int> offeredMethods = const [];
  int? selectedMethod;
  String? username;
  String? password;
  int? addressType;
  String? requestedHost;
  int? requestedPort;
}

/// 进程内 SOCKS5 服务器（只绑 127.0.0.1），用来精确控制和记录握手。
///
/// 目标名只按 [names] 表解析，表里没有的一律回 0x04（主机不可达），
/// 所以"目标名只有代理能解析"在这里是确定成立的，不受本机 DNS（比如 fake-ip）影响。
class Socks5Fixture {
  Socks5Fixture._(this._server, this.fault, this.username, this.password,
      this.names, this.fragmentDelay, this.connectReplyCode);

  static Future<Socks5Fixture> start({
    Socks5Fault fault = Socks5Fault.none,
    String? username,
    String? password,
    Map<String, ({String host, int port})> names = const {},
    Duration? fragmentDelay,
    int connectReplyCode = 0x05,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = Socks5Fixture._(server, fault, username, password, names,
        fragmentDelay, connectReplyCode);
    server.listen(fixture._handle);
    return fixture;
  }

  final ServerSocket _server;
  final Socks5Fault fault;

  /// 非空时要求用户名密码认证（方法 0x02）。
  final String? username;
  final String? password;
  final Map<String, ({String host, int port})> names;

  /// 非空时，代理发给客户端的每个握手字节单独一个 TCP 包、间隔这么久——测分片与半包。
  final Duration? fragmentDelay;
  final int connectReplyCode;

  final attempts = <Socks5Attempt>[];
  final _open = <Socket>[];

  int get port => _server.port;
  String get host => '127.0.0.1';

  Future<void> close() async {
    for (final socket in _open) {
      socket.destroy();
    }
    await _server.close();
  }

  Future<void> _send(Socket socket, List<int> bytes) async {
    final delay = fragmentDelay;
    if (delay == null) {
      socket.add(bytes);
      await socket.flush();
      return;
    }
    for (final byte in bytes) {
      socket.add([byte]);
      await socket.flush();
      await Future<void>.delayed(delay);
    }
  }

  Future<void> _handle(Socket client) async {
    _open.add(client);
    final attempt = Socks5Attempt();
    attempts.add(attempt);
    final reader = _Reader(client);
    try {
      final head = await reader.take(2);
      if (head[0] != 5) return client.destroy();
      attempt.offeredMethods = await reader.take(head[1]);
      switch (fault) {
        case Socks5Fault.closeAfterGreeting:
          return client.destroy();
        case Socks5Fault.stallAfterGreeting:
          return; // 不回、不关，直到 close()。
        case Socks5Fault.rejectAllMethods:
          await _send(client, [5, 0xff]);
          return client.destroy();
        default:
      }
      final wantAuth = username != null && fault != Socks5Fault.forceNoAuth;
      final method = wantAuth ? 2 : 0;
      if (!attempt.offeredMethods.contains(method) &&
          fault != Socks5Fault.forceNoAuth) {
        await _send(client, [5, 0xff]);
        return client.destroy();
      }
      attempt.selectedMethod = method;
      await _send(client, [5, method]);
      if (method == 2) {
        final ver = await reader.take(2);
        attempt.username = utf8.decode(await reader.take(ver[1]));
        final passLength = (await reader.take(1)).first;
        attempt.password = utf8.decode(await reader.take(passLength));
        final ok = attempt.username == username && attempt.password == password;
        await _send(client, [1, ok ? 0 : 1]);
        if (!ok) return client.destroy();
      }
      final request = await reader.take(4);
      attempt.addressType = request[3];
      switch (request[3]) {
        case 1:
          attempt.requestedHost = (await reader.take(4)).join('.');
        case 3:
          final length = (await reader.take(1)).first;
          attempt.requestedHost = utf8.decode(await reader.take(length));
        case 4:
          attempt.requestedHost = InternetAddress.fromRawAddress(
                  Uint8List.fromList(await reader.take(16)))
              .address;
      }
      final portBytes = await reader.take(2);
      attempt.requestedPort = portBytes[0] << 8 | portBytes[1];
      if (fault == Socks5Fault.connectError) {
        await _send(client, [5, connectReplyCode, 0, 1, 0, 0, 0, 0, 0, 0]);
        return client.destroy();
      }
      final upstreamAddress = names[attempt.requestedHost];
      if (upstreamAddress == null) {
        await _send(client, [5, 4, 0, 1, 0, 0, 0, 0, 0, 0]);
        return client.destroy();
      }
      final upstream =
          await Socket.connect(upstreamAddress.host, upstreamAddress.port);
      _open.add(upstream);
      await _send(client, [5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
      // 回复之后立刻转发：上游的 SSH banner 可能和 SOCKS 回复落在同一个包里，
      // 这正是客户端必须把余留字节交给 SSH 的场景。
      reader.drainTo(upstream);
      upstream.listen(client.add,
          onDone: client.destroy, onError: (_) => client.destroy());
    } catch (_) {
      client.destroy();
    }
  }
}

/// 从 socket 按需精确读取字节；握手结束后把剩余数据转给上游。
class _Reader {
  _Reader(Socket socket) {
    _subscription = socket.listen(
      (data) {
        final sink = _sink;
        if (sink != null) {
          sink.add(data);
          return;
        }
        _buffer.addAll(data);
        _wake();
      },
      onDone: () {
        _done = true;
        _sink?.destroy();
        _wake();
      },
      onError: (_) {
        _done = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final _buffer = <int>[];
  Completer<void>? _waiter;
  bool _done = false;
  Socket? _sink;

  void _wake() {
    _waiter?.complete();
    _waiter = null;
  }

  Future<List<int>> take(int count) async {
    while (_buffer.length < count) {
      if (_done) throw const SocketException('client closed');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }

  void drainTo(Socket upstream) {
    _sink = upstream;
    if (_buffer.isNotEmpty) upstream.add(List.of(_buffer));
    _buffer.clear();
    if (_done) upstream.destroy();
  }

  Future<void> cancel() => _subscription.cancel();
}
