import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/connection_diagnosis.dart';
import 'package:shun/application/connection_lifecycle.dart';
import 'package:shun/infrastructure/ssh/ssh_client_defaults.dart';

/// 只发版本行和 KEXINIT 的假服务器，算法列表由测试定。谈不拢的判断在客户端，不需要真的换密钥。
Future<ServerSocket> _legacyServer({
  String kex = 'curve25519-sha256',
  String hostKey = 'ssh-ed25519',
  String cipher = 'aes128-ctr',
  String mac = 'hmac-sha2-256',
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    socket.listen((_) {}, onError: (_) {}, onDone: socket.destroy);
    socket.add(utf8.encode('SSH-2.0-legacy\r\n'));
    socket.add(_kexInitPacket([
      kex,
      hostKey,
      cipher,
      cipher,
      mac,
      mac,
      'none',
      'none',
      '',
      '',
    ]));
  });
  return server;
}

Uint8List _kexInitPacket(List<String> nameLists) {
  final payload = BytesBuilder()
    ..addByte(20)
    ..add(List<int>.filled(16, 0));
  for (final list in nameLists) {
    final bytes = utf8.encode(list);
    payload
      ..add(_uint32(bytes.length))
      ..add(bytes);
  }
  payload
    ..addByte(0)
    ..add(_uint32(0));
  final body = payload.toBytes();
  // RFC 4253 第 6 节：总长度是 8 的倍数，填充至少 4 字节。
  var padding = 8 - (5 + body.length) % 8;
  if (padding < 4) padding += 8;
  return (BytesBuilder()
        ..add(_uint32(1 + body.length + padding))
        ..addByte(padding)
        ..add(body)
        ..add(List<int>.filled(padding, 0)))
      .toBytes();
}

List<int> _uint32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

Future<Object?> _connectError(ServerSocket server) async {
  final socket = await SSHSocket.connect('127.0.0.1', server.port);
  final client = SSHClient(
    socket,
    username: 'x',
    algorithms: shunSshAlgorithms,
    onPasswordRequest: () => 'x',
  );
  try {
    await client.authenticated.timeout(const Duration(seconds: 5));
    return null;
  } catch (error) {
    return error;
  } finally {
    client.closeQuietly();
    await server.close();
  }
}

void main() {
  group('加密算法顺序（R58）', () {
    test('chacha20 排第一，GCM 排最后：GCM 纯 Dart 实现只有 1 MB/s', () {
      final names = shunSshAlgorithms.cipher.map((c) => c.name).toList();
      expect(names.first, 'chacha20-poly1305@openssh.com');
      expect(names.sublist(names.length - 2), [
        'aes128-gcm@openssh.com',
        'aes256-gcm@openssh.com',
      ]);
    });

    test('不带 CBC', () {
      final names = shunSshAlgorithms.cipher.map((c) => c.name);
      expect(names.where((name) => name.endsWith('-cbc')), isEmpty);
    });
  });

  group('服务器只认旧算法时说得清原因（R58）', () {
    for (final (name, server) in <(String, Future<ServerSocket> Function())>[
      ('只有 CBC 加密', () => _legacyServer(cipher: 'aes128-cbc')),
      (
        '只有 SHA-1 密钥交换',
        () => _legacyServer(kex: 'diffie-hellman-group14-sha1')
      ),
      ('只有 ssh-rsa 主机密钥', () => _legacyServer(hostKey: 'ssh-rsa')),
    ]) {
      test(name, () async {
        final error = await _connectError(await server());
        expect(error, isA<SSHAuthAbortError>());
        expect(isAlgorithmMismatch(error), isTrue, reason: '$error');
        expect(
          classifyConnectionFailure(error!),
          ConnectionFailureKind.noCommonAlgorithm,
        );
        expect(connectionHint(error), contains('已淘汰'));
        // 再试多少次都一样，自动恢复不该一直撞。
        expect(isTransientConnectionError(error), isFalse);
      });
    }

    test('别的登录前断开不算，照样自动恢复', () {
      final error = SSHAuthAbortError(
        'Connection closed before authentication',
        SSHSocketError('reset'),
      );
      expect(isAlgorithmMismatch(error), isFalse);
      expect(isTransientConnectionError(error), isTrue);
    });
  });
}
