import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';

/// 代理握手失败。消息直接给用户看，不含代理口令。
///
/// 不用 SocketException：它的 toString 带 `SocketException:` 前缀和 OS 错误码，界面上看不懂。
class ProxyHandshakeException implements IOException {
  const ProxyHandshakeException(this.message, {this.transient = false});

  final String message;

  /// 过一会儿再试可能就好了：超时、握手中途断开、代理报目标暂时连不上（R22）。
  /// 断线自动恢复只重试这一类；认证失败、规则不允许、对方不是代理这些，再试多少次都一样，要人来改。
  final bool transient;

  @override
  String toString() => message;
}

/// 某个网络阶段在期限内没完成：TCP 没连上，或 SSH 服务一个字节都没回。
class ConnectStageException implements IOException {
  const ConnectStageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 在已经连上代理的 [socket] 上做握手，让代理 CONNECT 到 [target]。
///
/// - 整个握手有总期限 [deadline]，不是每收到一个字节就重新计时，慢速半包也会按时失败。
/// - 失败或超时都会先销毁 [socket] 再抛 [ProxyHandshakeException]。
/// - 成功后返回的 SSHSocket 会先吐出握手时多读到的字节（代理回复和 SSH 版本行可能在同一个包里），
///   每个字节只交给 SSH 一次。
Future<SSHSocket> proxyHandshake(
  Socket socket,
  ProxyEntry proxy,
  Endpoint target, {
  required Duration deadline,
}) async {
  final cursor = _SocketCursor(socket);
  try {
    final handshake = switch (proxy.type) {
      ProxyType.http => _http(socket, cursor, proxy, target),
      ProxyType.socks5 => _socks5(socket, cursor, proxy, target),
    };
    await handshake.timeout(
      deadline,
      onTimeout: () => throw ProxyHandshakeException(
        '代理握手超时（${proxy.endpoint.authority}，${deadline.inSeconds} 秒）',
        transient: true,
      ),
    );
    return _ProxiedSshSocket(socket, cursor);
  } catch (_) {
    socket.destroy();
    rethrow;
  }
}

Future<void> _http(
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
  final status = match?.group(1);
  if (status == '200') return;
  if (status == '407') {
    throw ProxyHandshakeException(
      proxy.username?.isNotEmpty == true
          ? 'HTTP 代理认证失败（407）：用户名或密码不对'
          : 'HTTP 代理要求认证（407），但没有配置用户名和密码',
    );
  }
  // 502/503/504：代理连不上目标或自己忙，目标重启、网络抖动时会有，过一会儿可能就好了。
  throw ProxyHandshakeException(
    'HTTP 代理连接失败：${header.split('\r\n').first}',
    transient: status == '502' || status == '503' || status == '504',
  );
}

/// SOCKS5（RFC 1928 / 1929），只做 CONNECT。
///
/// 认证不降级（A02 / NET05）：配了用户名就只提供「用户名密码」一种方法，
/// 代理若选「无认证」直接拒绝——以前两种都提供，代理选无认证也照连，
/// 用户以为走的是要口令的那台代理，实际可能是别人冒充的。
/// 没配用户名就只提供「无认证」，代理要口令时明确报错，而不是乱发一个空口令。
Future<void> _socks5(
  Socket socket,
  _SocketCursor cursor,
  ProxyEntry proxy,
  Endpoint target,
) async {
  final wantsAuth = proxy.username?.isNotEmpty == true;
  socket.add(wantsAuth ? const [5, 1, 2] : const [5, 1, 0]);
  await socket.flush();

  final choice = await cursor.readExact(2);
  if (choice[0] != 5) {
    throw ProxyHandshakeException('对方不是 SOCKS5 代理（版本字节 ${choice[0]}）');
  }
  switch ((choice[1], wantsAuth)) {
    case (2, true):
      final user = utf8.encode(proxy.username!);
      final pass = utf8.encode(proxy.password ?? '');
      if (user.length > 255 || pass.length > 255) {
        throw const ProxyHandshakeException('SOCKS5 代理用户名或密码过长（各不能超过 255 字节）');
      }
      socket.add([1, user.length, ...user, pass.length, ...pass]);
      await socket.flush();
      final auth = await cursor.readExact(2);
      if (auth[0] != 1) {
        throw ProxyHandshakeException('SOCKS5 代理的认证回复格式不对（版本字节 ${auth[0]}）');
      }
      if (auth[1] != 0) {
        throw const ProxyHandshakeException('SOCKS5 代理认证失败：用户名或密码不对');
      }
    case (0, false):
      break;
    case (0, true):
      throw const ProxyHandshakeException(
        'SOCKS5 代理选择了「无认证」，但你配置了用户名和密码。为防止降级到未认证的代理，已拒绝连接',
      );
    case (2, false):
      throw const ProxyHandshakeException('SOCKS5 代理要求用户名和密码，但没有配置');
    case (0xff, _):
      throw const ProxyHandshakeException('SOCKS5 代理不接受我们提供的认证方式');
    case (final method, _):
      throw ProxyHandshakeException('SOCKS5 代理选了没有提供的认证方式，已拒绝（方式 $method）');
  }

  // 按地址类型编码（NET04）：域名交给代理解析，手机不提前解析目标名。
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
  if (reply[0] != 5) {
    throw ProxyHandshakeException('SOCKS5 代理的连接回复格式不对（版本字节 ${reply[0]}）');
  }
  if (reply[1] != 0) {
    // 1 内部错误、3/4 网络或主机不可达、5 目标拒绝（sshd 正在重启）、6 转发超时：可能是暂时的。
    // 2 规则不允许、7/8 不支持：再试也一样。
    throw ProxyHandshakeException(
      socks5ReplyMessage(reply[1]),
      transient: const {1, 3, 4, 5, 6}.contains(reply[1]),
    );
  }
  if (reply[2] != 0) {
    throw ProxyHandshakeException('SOCKS5 代理的连接回复格式不对（保留字节 ${reply[2]}）');
  }
  final boundLength = switch (reply[3]) {
    1 => 4,
    4 => 16,
    3 => (await cursor.readExact(1)).first,
    final type => throw ProxyHandshakeException('SOCKS5 代理返回了未知地址类型（$type）'),
  };
  await cursor.readExact(boundLength + 2);
}

/// SOCKS5 CONNECT 失败码的说明（NET08）。按 RFC 1928 逐个区分，
/// 尤其「主机不可达」不能一律说成 DNS 失败：目标关机、防火墙、代理那边的路由都会这样。
String socks5ReplyMessage(int code) => switch (code) {
      1 => 'SOCKS5 代理内部错误（状态码 1）',
      2 => 'SOCKS5 代理的规则不允许连接这个目标（状态码 2）',
      3 => 'SOCKS5 代理报告目标网络不可达（状态码 3）',
      4 => 'SOCKS5 代理报告目标主机不可达（状态码 4）：可能是目标关机、被防火墙拦截或代理那边没有路由，不一定是域名解析问题',
      5 => '目标拒绝连接（SOCKS5 状态码 5）：目标端口上可能没有 SSH 服务',
      6 => 'SOCKS5 代理转发超时（状态码 6）',
      7 => 'SOCKS5 代理不支持 CONNECT 命令（状态码 7）',
      8 => 'SOCKS5 代理不支持这种目标地址类型（状态码 8）',
      _ => 'SOCKS5 代理返回了未知状态码（$code）',
    };

/// 直连 socket 的 SSHSocket 包装，和 dartssh2 自带的等价；
/// 自己包是为了让直连也走可注入的拨号器，所有拨号都能被记录。
class DirectSshSocket implements SSHSocket {
  DirectSshSocket(this._socket);

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

/// 包在每一跳 SSH 连接外面，管「版本行」（`SSH-2.0-…\r\n`）这一段。做两件事：
///
/// 1. **攒齐再交**：第一个换行之前的字节先攒着，凑成完整一行再一次交给 dartssh2。
///    dartssh2 2.22.5 只要某次收到的数据里没有换行就直接报 `Version exchange not terminated` 断开，
///    不等下一个包。版本行被网络拆成两个 TCP 包（经代理时代理回复和半截版本行粘在一起很常见）
///    就会连不上——实测把版本行分两次、隔 100 ms 发，13 ms 后连接就被断了。
/// 2. **期限**：[deadline] 内没等到换行就断开（NET07）。只管这一段，收到换行就停表：
///    不用 dartssh2 自带的 handshakeTimeout，它把主机指纹确认弹窗的时间也算进去，
///    用户看指纹慢一点就会被判超时（docs/04 要求两者分开）。
///    也不能只看「收到任意字节」：代理多发一份回复之类的垃圾字节里没有换行，又会无限卡住（NET06）。
class SshBannerDeadlineSocket implements SSHSocket {
  SshBannerDeadlineSocket(this._inner, Duration deadline) {
    _timer = Timer(deadline, () {
      expired = true;
      _inner.destroy();
    });
  }

  /// 攒到这么多还没换行，就不再攒、原样交给 dartssh2（它自己会判不合法），内存有上限。
  static const _maxBanner = 16 * 1024;

  final SSHSocket _inner;
  late final Timer _timer;
  final _pending = BytesBuilder(copy: false);
  var _released = false;

  /// 期限到了、连接是被这里断开的。调用方据此把 dartssh2 的「认证前连接已关闭」换成看得懂的原因。
  bool expired = false;

  @override
  Stream<Uint8List> get stream => _inner.stream.transform(
        StreamTransformer.fromHandlers(
          handleData: (chunk, sink) {
            if (_released) return sink.add(chunk);
            _pending.add(chunk);
            if (!chunk.contains(10) && _pending.length < _maxBanner) return;
            _released = true;
            _timer.cancel();
            sink.add(_pending.takeBytes());
          },
          handleDone: (sink) {
            if (!_released && _pending.isNotEmpty) {
              sink.add(_pending.takeBytes());
            }
            sink.close();
          },
        ),
      );

  @override
  StreamSink<List<int>> get sink => _inner.sink;

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() {
    _timer.cancel();
    return _inner.close();
  }

  @override
  void destroy() {
    _timer.cancel();
    _inner.destroy();
  }

  @override
  Future<void> flush() => _inner.flush();
}

class _ProxiedSshSocket implements SSHSocket {
  _ProxiedSshSocket(this._socket, this._cursor);

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

/// 从 socket 按需精确读取字节。多读到的留在缓冲里，握手结束后原样交给 SSH。
class _SocketCursor {
  _SocketCursor(Socket socket) : _iterator = StreamIterator(socket);

  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = [];

  Future<List<int>> readExact(int length) async {
    while (_buffer.length < length) {
      await _next();
    }
    final result = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return result;
  }

  Future<List<int>> readUntil(List<int> marker,
      {required int maxLength}) async {
    while (true) {
      final index = _indexOf(_buffer, marker);
      if (index >= 0) {
        final end = index + marker.length;
        final result = _buffer.sublist(0, end);
        _buffer.removeRange(0, end);
        return result;
      }
      if (_buffer.length >= maxLength) {
        throw const ProxyHandshakeException('代理响应头过长');
      }
      await _next();
    }
  }

  Future<void> _next() async {
    final bool hasMore;
    try {
      hasMore = await _iterator.moveNext();
    } on SocketException {
      throw const ProxyHandshakeException('代理在握手完成前断开了连接', transient: true);
    }
    if (!hasMore) {
      throw const ProxyHandshakeException('代理在握手完成前关闭了连接', transient: true);
    }
    _buffer.addAll(_iterator.current);
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
