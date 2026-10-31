import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 手机之间局域网互传（R62）：一台出二维码（地址、端口、一次性 256 位密钥），另一台扫码后直连拿走。
///
/// 密钥只经屏幕传，不走网络，熵也够，所以不用 PBKDF2、不用配对口令协议（PAKE）。dart:io 没有预共享密钥的 TLS，
/// 自签证书又得在手机上现算，就在裸 TCP 上走下面这几步（裸 socket 也避开了 `usesCleartextTraffic`）：
///
///     C→S  magic + 客户端随机数
///     S→C  服务端随机数 + MAC("server")   接收方先确认对方有密钥
///     C→S  MAC("client")                  发送方确认对方有密钥，没有就连密文都不给
///     S→C  长度 + AES-256-GCM 密文
///     C→S  MAC("done")                    解密成功才发，发送方收到就关服务、废密钥
///
/// MAC 里有双方的随机数，录下来重放没用。没有前向保密：有人录了流量、事后又拿到二维码，就能解开。
/// 二维码页防截屏，密钥只在内存里、关服务就丢，就不再多加一层密钥交换。

/// 二维码没扫就过期的时间。留够走到另一台手机、打开页面就行，不让端口长期开着。
const lanTransferValidFor = Duration(minutes: 5);

const _qrPrefix = 'shun-lan:1:';
const _keyLength = 32;
const _nonceLength = 32;
const _macLength = 32;
const _ivLength = 12;
const _tagLength = 16;
const _maxBlob = 64 * 1024 * 1024;
const _maxConnections = 8;
const _handshakeTimeout = Duration(seconds: 6);
const _dataTimeout = Duration(seconds: 30);
const _connectTimeout = Duration(seconds: 6);
final _magic = ascii.encode('SHUNLAN1');
final _aad = ascii.encode('shun-lan-1');

/// 连不上：地址不通，或者连上了却没回应。
///
/// VPN 接管局域网时是后一种：本地的 tun 栈先把 TCP 握手答应下来，之后没有任何数据。
class LanTransferUnreachable implements Exception {
  const LanTransferUnreachable();
}

/// 连上的不是出这张二维码的手机（或者它已经换了密钥）。
class LanTransferWrongPeer implements Exception {
  const LanTransferWrongPeer();
}

/// 内容校验没过。
class LanTransferDamaged implements Exception {
  const LanTransferDamaged();
}

class _Closed implements Exception {
  const _Closed();
}

/// 二维码里的东西。
class LanPairing {
  const LanPairing({
    required this.addresses,
    required this.port,
    required this.key,
    required this.expiresAt,
  });

  final List<String> addresses;
  final int port;
  final List<int> key;

  /// 只用来把「连不上」说清楚：两台手机的钟可能不准，不拿它拒绝连接。
  final DateTime expiresAt;

  String encode() => [
        '$_qrPrefix${base64Url.encode(key).replaceAll('=', '')}',
        '$port',
        '${expiresAt.millisecondsSinceEpoch ~/ 1000}',
        addresses.join(','),
      ].join(':');

  /// 扫到的内容不对就返回 null。
  ///
  /// 地址只收局域网的 IPv4：二维码是别人送到眼前的，不能让它指挥手机去连互联网上的任意地址。
  static LanPairing? tryParse(String text) {
    if (!text.startsWith(_qrPrefix)) return null;
    final parts = text.substring(_qrPrefix.length).split(':');
    if (parts.length != 4) return null;
    final List<int> key;
    try {
      key = base64Url.decode(base64Url.normalize(parts[0]));
    } on FormatException {
      return null;
    }
    final port = int.tryParse(parts[1]);
    final expires = int.tryParse(parts[2]);
    final addresses = parts[3].split(',');
    if (key.length != _keyLength ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        expires == null ||
        !addresses.every(isLanAddress)) {
      return null;
    }
    return LanPairing(
      addresses: addresses,
      port: port,
      key: key,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expires * 1000),
    );
  }
}

/// 私有 IPv4 地址。100.64.0.0/10 不算：那是运营商 NAT 和 Tailscale 的段，不是局域网。
bool isLanAddress(String address) {
  final parsed = InternetAddress.tryParse(address);
  if (parsed == null || parsed.type != InternetAddressType.IPv4) return false;
  final [a, b, ..._] = parsed.rawAddress;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

final _vpnInterface = RegExp(r'^(tun|tap|ppp|wg|ipsec|utun)');
final _notLanInterface = RegExp(r'^(rmnet|ccmni|pdp|wwan|clat|v4-|dummy|lo)');

/// 这台手机在局域网上的地址。按接口名排除 VPN 和蜂窝：那些地址另一台手机连不到，放进二维码只会拖慢报错。
Future<List<String>> lanAddresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  return [
    for (final interface in interfaces)
      if (!_vpnInterface.hasMatch(interface.name) &&
          !_notLanInterface.hasMatch(interface.name))
        for (final address in interface.addresses)
          if (isLanAddress(address.address)) address.address,
  ];
}

/// 这台手机是不是开着 VPN。只用来把「连不上」说清楚。
Future<bool> vpnInterfaceUp() async {
  final interfaces = await NetworkInterface.list();
  return interfaces.any((interface) => _vpnInterface.hasMatch(interface.name));
}

class _Keys {
  const _Keys(this.auth, this.data);
  final SecretKey auth;
  final SecretKey data;

  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: _keyLength);

  static Future<_Keys> derive(List<int> key) async => _Keys(
        await _hkdf.deriveKey(
          secretKey: SecretKey(key),
          nonce: const [],
          info: ascii.encode('shun-lan-1 auth'),
        ),
        await _hkdf.deriveKey(
          secretKey: SecretKey(key),
          nonce: const [],
          info: ascii.encode('shun-lan-1 data'),
        ),
      );

  Future<List<int>> mac(String label, List<int> nonces) async {
    final mac = await Hmac.sha256().calculateMac(
      [...ascii.encode(label), ...nonces],
      secretKey: auth,
    );
    return mac.bytes;
  }
}

Uint8List _random(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var index = 0; index < a.length; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}

// 加解密是纯 Dart，几兆的保险库在主 isolate 上会卡界面，放后台。
Future<Uint8List> _seal(List<int> plain, List<int> dataKey) =>
    Isolate.run(() async {
      final iv = _random(_ivLength);
      final box = await AesGcm.with256bits().encrypt(
        plain,
        secretKey: SecretKey(dataKey),
        nonce: iv,
        aad: _aad,
      );
      return Uint8List.fromList([...iv, ...box.cipherText, ...box.mac.bytes]);
    });

Future<Uint8List> _open(Uint8List blob, List<int> dataKey) =>
    Isolate.run(() async {
      if (blob.length < _ivLength + _tagLength) {
        throw const LanTransferDamaged();
      }
      try {
        final plain = await AesGcm.with256bits().decrypt(
          SecretBox(
            blob.sublist(_ivLength, blob.length - _tagLength),
            nonce: blob.sublist(0, _ivLength),
            mac: Mac(blob.sublist(blob.length - _tagLength)),
          ),
          secretKey: SecretKey(dataKey),
          aad: _aad,
        );
        return Uint8List.fromList(plain);
      } on SecretBoxAuthenticationError {
        throw const LanTransferDamaged();
      }
    });

/// 从 socket 里按字节数读。
class _Reader {
  _Reader(Stream<Uint8List> source) : _source = StreamIterator(source);

  final StreamIterator<Uint8List> _source;
  var _pending = Uint8List(0);

  Future<Uint8List> read(int count, Duration timeout) async {
    final out = BytesBuilder(copy: false);
    while (out.length < count) {
      if (_pending.isEmpty) {
        if (!await _source.moveNext().timeout(timeout)) throw const _Closed();
        _pending = _source.current;
      }
      final take = min(count - out.length, _pending.length);
      out.add(Uint8List.sublistView(_pending, 0, take));
      _pending = Uint8List.sublistView(_pending, take);
    }
    return out.takeBytes();
  }

  Future<void> cancel() => _source.cancel();
}

enum LanSendOutcome {
  /// 对方收到并解开了。
  delivered,

  /// 没人来拿，到时间了。
  expired,

  /// 页面自己关的。
  closed,
}

/// 发送方。服务只在它活着时监听；[close] 之后端口关掉、密钥作废。
class LanTransferSender {
  LanTransferSender._(this.pairing, this._keys, this._blob, this._servers) {
    for (final server in _servers) {
      server.listen(_accept, onError: (Object _) {});
    }
    _expiry = Timer(
      pairing.expiresAt.difference(DateTime.now()),
      () => _finish(LanSendOutcome.expired),
    );
  }

  /// 只在 [addresses] 上监听，不绑所有接口：VPN、蜂窝那一侧的人连不进来。
  ///
  /// 绑不上的地址从二维码里去掉；一个都绑不上就把异常抛给调用方。
  static Future<LanTransferSender> start(
    List<int> plain, {
    required List<String> addresses,
    Duration validFor = lanTransferValidFor,
  }) async {
    final key = _random(_keyLength);
    final keys = await _Keys.derive(key);
    final blob = await _seal(plain, await keys.data.extractBytes());
    final servers = <ServerSocket>[];
    final bound = <String>[];
    Object? firstError;
    for (final address in addresses) {
      try {
        servers.add(await ServerSocket.bind(
          address,
          servers.isEmpty ? 0 : servers.first.port,
        ));
        bound.add(address);
      } on SocketException catch (error) {
        firstError ??= error;
      }
    }
    if (servers.isEmpty) {
      throw firstError ?? const LanTransferUnreachable();
    }
    return LanTransferSender._(
      LanPairing(
        addresses: bound,
        port: servers.first.port,
        key: key,
        expiresAt: DateTime.now().add(validFor),
      ),
      keys,
      blob,
      servers,
    );
  }

  final LanPairing pairing;
  final _Keys _keys;
  final Uint8List _blob;
  final List<ServerSocket> _servers;
  final _sockets = <Socket>{};
  final _outcome = Completer<LanSendOutcome>();
  late final Timer _expiry;
  var _sending = false;

  /// 传完、过期或者被关掉。
  Future<LanSendOutcome> get outcome => _outcome.future;

  Future<void> close() => _finish(LanSendOutcome.closed);

  Future<void> _finish(LanSendOutcome outcome) async {
    if (_outcome.isCompleted) return;
    _outcome.complete(outcome);
    _expiry.cancel();
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
    await Future.wait(_servers.map((server) => server.close()));
  }

  void _accept(Socket socket) {
    // 同时在握手的连接有上限：同一个局域网里的人不能靠开一堆连接吃光内存。
    if (_outcome.isCompleted || _sockets.length >= _maxConnections) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
    unawaited(_serve(socket).whenComplete(() {
      _sockets.remove(socket);
      socket.destroy();
    }));
  }

  /// 没密钥的连接不结束服务：局域网里谁都能连上来，关掉的话随便一个端口扫描就让互传失败。
  Future<void> _serve(Socket socket) async {
    final reader = _Reader(socket);
    try {
      final hello = await reader.read(
        _magic.length + _nonceLength,
        _handshakeTimeout,
      );
      if (!_same(hello.sublist(0, _magic.length), _magic)) return;
      final serverNonce = _random(_nonceLength);
      final nonces = [...hello.sublist(_magic.length), ...serverNonce];
      socket
        ..add(serverNonce)
        ..add(await _keys.mac('server', nonces));
      await socket.flush().timeout(_handshakeTimeout);
      final proof = await reader.read(_macLength, _handshakeTimeout);
      if (!_same(proof, await _keys.mac('client', nonces)) || _sending) return;
      _sending = true;
      try {
        socket
          ..add((ByteData(4)..setUint32(0, _blob.length)).buffer.asUint8List())
          ..add(_blob);
        await socket.flush().timeout(_dataTimeout);
        final done = await reader.read(_macLength, _dataTimeout);
        if (_same(done, await _keys.mac('done', nonces))) {
          await _finish(LanSendOutcome.delivered);
        }
      } finally {
        _sending = false;
      }
    } on _Closed {
      return;
    } on TimeoutException {
      return;
    } on SocketException {
      return;
    } finally {
      await reader.cancel();
    }
  }
}

/// 接收方：同时试二维码里的每个地址，先拿到内容的算数。
///
/// 全失败时，有一个地址说得出原因（不是同一台、内容坏了）就报那个，都不通才报 [LanTransferUnreachable]。
Future<Uint8List> receiveLanTransfer(
  LanPairing pairing, {
  Duration connectTimeout = _connectTimeout,
  Duration handshakeTimeout = _handshakeTimeout,
}) {
  final result = Completer<Uint8List>();
  var pending = pairing.addresses.length;
  Object failure = const LanTransferUnreachable();
  for (final address in pairing.addresses) {
    unawaited(_fetch(address, pairing, connectTimeout, handshakeTimeout).then(
      (plain) {
        if (!result.isCompleted) result.complete(plain);
      },
      onError: (Object error) {
        if (error is! LanTransferUnreachable) failure = error;
        pending--;
        if (pending == 0 && !result.isCompleted) result.completeError(failure);
      },
    ));
  }
  return result.future;
}

Future<Uint8List> _fetch(
  String address,
  LanPairing pairing,
  Duration connectTimeout,
  Duration handshakeTimeout,
) async {
  final Socket socket;
  try {
    socket =
        await Socket.connect(address, pairing.port, timeout: connectTimeout);
  } on SocketException {
    throw const LanTransferUnreachable();
  }
  final reader = _Reader(socket);
  var verified = false;
  try {
    final keys = await _Keys.derive(pairing.key);
    final clientNonce = _random(_nonceLength);
    socket
      ..add(_magic)
      ..add(clientNonce);
    await socket.flush().timeout(handshakeTimeout);
    final reply =
        await reader.read(_nonceLength + _macLength, handshakeTimeout);
    final nonces = [...clientNonce, ...reply.sublist(0, _nonceLength)];
    if (!_same(reply.sublist(_nonceLength), await keys.mac('server', nonces))) {
      throw const LanTransferWrongPeer();
    }
    verified = true;
    socket.add(await keys.mac('client', nonces));
    await socket.flush().timeout(handshakeTimeout);
    final header = await reader.read(4, _dataTimeout);
    final length = ByteData.sublistView(header).getUint32(0);
    if (length > _maxBlob) throw const LanTransferDamaged();
    final blob = await reader.read(length, _dataTimeout);
    final plain = await _open(blob, await keys.data.extractBytes());
    socket.add(await keys.mac('done', nonces));
    // 等它刷出去：发送方就靠这一条知道传完了，没收到会一直显示在等。
    await socket.flush().timeout(handshakeTimeout);
    await socket.close().timeout(handshakeTimeout, onTimeout: () => socket);
    return plain;
  } on _Closed {
    // 证明过身份之后才断的算传坏了，之前断的算没连上。
    throw verified
        ? const LanTransferDamaged()
        : const LanTransferUnreachable();
  } on TimeoutException {
    throw verified
        ? const LanTransferDamaged()
        : const LanTransferUnreachable();
  } on SocketException {
    throw verified
        ? const LanTransferDamaged()
        : const LanTransferUnreachable();
  } finally {
    await reader.cancel();
    socket.destroy();
  }
}
