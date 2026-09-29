import 'dart:io';

/// "直连陷阱"：扮演一个本来就能直连到达的目标，只数有多少连接进来。
///
/// 代理出错时如果 App 偷偷回退直连，就会打到这里，[accepted] 变成非零。
/// 进来的连接会先收到一行 SSH banner，让回退看起来"像是成功了"，
/// 这样测试抓的是最危险的情形，而不是一个本来就连不上的端口。
class TrapServer {
  TrapServer._(this._server) {
    _server.listen((socket) {
      accepted++;
      socket.add('SSH-2.0-DirectTrap\r\n'.codeUnits);
      socket.destroy();
    });
  }

  static Future<TrapServer> start() async =>
      TrapServer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  int accepted = 0;

  String get host => '127.0.0.1';
  int get port => _server.port;

  Future<void> close() => _server.close();
}

/// 记录 App 发起的每一次 TCP 拨号（host:port），再交给系统真正去连。
///
/// 本机 DNS 可能是 fake-ip（任何名字都能"解析"），所以证明"没有本地解析目标名/没有直连"
/// 只能看 App 实际拨了哪些端点，不能看 DNS 是否失败。
class RecordingDialer {
  final dials = <String>[];

  Future<Socket> call(String host, int port, {Duration? timeout}) {
    dials.add('$host:$port');
    return Socket.connect(host, port, timeout: timeout);
  }
}
