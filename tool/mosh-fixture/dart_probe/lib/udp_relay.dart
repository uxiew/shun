import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 夹在客户端和 mosh-server 之间的 UDP 中继，模拟丢包、重复、乱序、篡改、重放和反射。
///
/// 客户端连 [port]；中继用另一个套接字把包转给服务器。服务器只看到中继的地址，
/// 和真实 NAT 后的手机一样。所有经过的包都记下来，测试可以拿去重放或反射。
class UdpRelay {
  UdpRelay._(this._front, this._back, this._server, this._serverPort) {
    _front.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = _front.receive()) != null) {
        _client = d!.address;
        _clientPort = d.port;
        _forward(d.data, toServer: true);
      }
    });
    _back.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = _back.receive()) != null) {
        _forward(d!.data, toServer: false);
      }
    });
  }

  static Future<UdpRelay> start(InternetAddress server, int serverPort) async {
    final front = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final back = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    return UdpRelay._(front, back, server, serverPort);
  }

  final RawDatagramSocket _front;
  final RawDatagramSocket _back;
  final InternetAddress _server;
  final int _serverPort;
  InternetAddress? _client;
  int? _clientPort;

  int get port => _front.port;

  final List<Uint8List> clientToServer = [];
  final List<Uint8List> serverToClient = [];

  /// 返回 true 表示丢掉这个包。参数：方向、包。
  bool Function(bool toServer, Uint8List packet)? drop;

  /// 返回非 null 表示把包换成这个（篡改）。
  Uint8List? Function(bool toServer, Uint8List packet)? mutate;

  /// 每个包发几次（重复）。
  int copies = 1;

  /// 乱序：攒够 [reorderWindow] 个包后倒序发出。1 表示不乱序。
  int reorderWindow = 1;
  final List<(bool, Uint8List)> _held = [];

  int dropped = 0;

  void _forward(Uint8List packet, {required bool toServer}) {
    (toServer ? clientToServer : serverToClient).add(
      Uint8List.fromList(packet),
    );
    if (drop?.call(toServer, packet) ?? false) {
      dropped++;
      return;
    }
    final out = mutate?.call(toServer, packet) ?? packet;
    if (reorderWindow > 1) {
      _held.add((toServer, out));
      if (_held.length < reorderWindow) return;
      for (final (dir, p) in _held.reversed) {
        _send(p, toServer: dir);
      }
      _held.clear();
      return;
    }
    _send(out, toServer: toServer);
  }

  void _send(Uint8List packet, {required bool toServer}) {
    for (var i = 0; i < copies; i++) {
      if (toServer) {
        _back.send(packet, _server, _serverPort);
      } else if (_client != null) {
        _front.send(packet, _client!, _clientPort!);
      }
    }
  }

  /// 往客户端注入任意包（重放旧的服务器包，或把客户端自己发的包反射回去）。
  void injectToClient(Uint8List packet) {
    if (_client == null) throw StateError('客户端还没发过包');
    _front.send(packet, _client!, _clientPort!);
  }

  void injectToServer(Uint8List packet) =>
      _back.send(packet, _server, _serverPort);

  void close() {
    _front.close();
    _back.close();
  }
}

/// 等到 [condition] 成立或超时。超时返回 false，不抛错，测试自己断言。
Future<bool> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return true;
}
