import 'dart:async';
import 'dart:io';

/// "剧本"代理：每个进来的连接交给 [script] 处理，想回什么字节、何时停、何时断都由测试决定。
///
/// Socks5Fixture 扮演的是守规矩的代理；这个用来造不守规矩的——版本字节错、长度伪造、
/// 提前断开、半包卡住、回复和 SSH 版本行粘在一起——测客户端能不能有界失败。
/// 只绑 127.0.0.1。
class ScriptedProxy {
  ScriptedProxy._(this._server, this._script) {
    _server.listen((socket) {
      final conn = ScriptedConn._(socket);
      connections.add(conn);
      unawaited(
        _script(conn).catchError((Object _) {}).whenComplete(() {}),
      );
    });
  }

  static Future<ScriptedProxy> start(
    Future<void> Function(ScriptedConn conn) script,
  ) async =>
      ScriptedProxy._(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        script,
      );

  final ServerSocket _server;
  final Future<void> Function(ScriptedConn conn) _script;
  final connections = <ScriptedConn>[];

  String get host => '127.0.0.1';
  int get port => _server.port;

  Future<void> close() async {
    for (final conn in connections) {
      conn.socket.destroy();
    }
    await _server.close();
  }
}

class ScriptedConn {
  ScriptedConn._(this.socket) {
    socket.listen(
      (data) {
        _buffer.addAll(data);
        _wake();
      },
      onDone: _markGone,
      onError: (Object _) => _markGone(),
    );
  }

  final Socket socket;
  final _buffer = <int>[];
  Completer<void>? _waiter;
  final _gone = Completer<void>();

  /// 客户端关闭或销毁了这条连接。用来检查"失败/取消时 socket 真的被关掉了"。
  Future<void> get clientGone => _gone.future;
  bool get isGone => _gone.isCompleted;

  void _markGone() {
    if (!_gone.isCompleted) _gone.complete();
    _wake();
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  /// 精确读 [length] 个客户端发来的字节；客户端先断了就抛 StateError。
  Future<List<int>> read(int length) async {
    while (_buffer.length < length) {
      if (isGone) throw StateError('客户端已断开');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final result = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return result;
  }

  /// 读 SOCKS5 问候，返回客户端提供的认证方法。
  Future<List<int>> readGreeting() async {
    final head = await read(2);
    return read(head[1]);
  }

  /// 读 RFC 1929 用户名密码子协商，返回 (用户名, 密码)。
  Future<(String, String)> readAuth() async {
    final ver = await read(2);
    final user = String.fromCharCodes(await read(ver[1]));
    final passLength = (await read(1)).first;
    return (user, String.fromCharCodes(await read(passLength)));
  }

  /// 读 CONNECT 请求，返回 (地址类型, 地址原始字节)。
  Future<(int, List<int>)> readConnect() async {
    final head = await read(4);
    final address = switch (head[3]) {
      1 => await read(4),
      4 => await read(16),
      _ => await read((await read(1)).first),
    };
    await read(2);
    return (head[3], address);
  }

  /// 发字节；[chunks] 给出时按这些长度切开，每块之间停 [gap]，模拟分片和粘包。
  Future<void> send(
    List<int> bytes, {
    List<int>? chunks,
    Duration gap = const Duration(milliseconds: 2),
  }) async {
    if (chunks == null) {
      socket.add(bytes);
      await socket.flush();
      return;
    }
    var offset = 0;
    for (final size in chunks) {
      socket.add(bytes.sublist(offset, offset + size));
      await socket.flush();
      offset += size;
      await Future<void>.delayed(gap);
    }
    assert(offset == bytes.length);
  }

  /// 一直不回、不关：模拟卡住的代理。
  Future<void> stall() => clientGone;
}
