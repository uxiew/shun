import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/sync/lan_transfer.dart';

// SYN04 的协议部分：真 socket，走本机回环。两台手机、真局域网、VPN 这些要真机，在 SYN04 里单记。

const loopback = ['127.0.0.1'];
final plain = utf8.encode('{"hosts":[{"password":"HOST-SECRET"}]}');

Future<LanTransferSender> startSender({
  List<int>? content,
  Duration validFor = lanTransferValidFor,
}) async {
  final sender = await LanTransferSender.start(
    content ?? plain,
    addresses: loopback,
    validFor: validFor,
  );
  addTearDown(sender.close);
  return sender;
}

LanPairing withKey(LanPairing pairing, List<int> key) => LanPairing(
      addresses: pairing.addresses,
      port: pairing.port,
      key: key,
      expiresAt: pairing.expiresAt,
    );

/// 把所有流量收下来，给「网络上有人在看」和「改一个字节」用。
class Relay {
  Relay._(this.server, this.target, this.tamperAfter) {
    server.listen((client) async {
      final upstream = await Socket.connect('127.0.0.1', target);
      upstream.listen(
        (data) {
          final out = Uint8List.fromList(data);
          final offset = tamperAfter - toClient.length;
          if (tamperAfter >= 0 && offset >= 0 && offset < out.length) {
            out[offset] ^= 0xff;
          }
          toClient.add(data);
          client.add(out);
        },
        onDone: client.destroy,
        onError: (Object _) => client.destroy(),
      );
      client.listen(
        (data) {
          toServer.add(data);
          upstream.add(data);
        },
        onDone: upstream.destroy,
        onError: (Object _) => upstream.destroy(),
      );
    });
  }

  static Future<Relay> start(int target, {int tamperAfter = -1}) async {
    final relay = Relay._(
      await ServerSocket.bind('127.0.0.1', 0),
      target,
      tamperAfter,
    );
    addTearDown(relay.server.close);
    return relay;
  }

  final ServerSocket server;
  final int target;
  final int tamperAfter;
  final toClient = BytesBuilder();
  final toServer = BytesBuilder();

  LanPairing pairing(LanPairing real) => LanPairing(
        addresses: real.addresses,
        port: server.port,
        key: real.key,
        expiresAt: real.expiresAt,
      );
}

void main() {
  group('二维码内容', () {
    final sample = LanPairing(
      addresses: const ['192.168.1.5', '10.0.0.2'],
      port: 40123,
      key: List<int>.generate(32, (index) => index),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(1767225600000),
    );

    test('编出来再解回去一样', () {
      final parsed = LanPairing.tryParse(sample.encode())!;
      expect(parsed.addresses, sample.addresses);
      expect(parsed.port, sample.port);
      expect(parsed.key, sample.key);
      expect(parsed.expiresAt, sample.expiresAt);
    });

    test('短到扫得出来：两个地址不到 110 字符', () {
      expect(sample.encode().length, lessThan(110));
    });

    test('别的二维码、缺字段、密钥长度不对、端口不对：都认不出来', () {
      final good = sample.encode();
      final key = good.split(':')[2];
      for (final text in [
        '',
        'https://example.com',
        'shun-lan:2:$key:1:1:192.168.1.5',
        'shun-lan:1:$key:1:1',
        'shun-lan:1:AAAA:1:1:192.168.1.5',
        'shun-lan:1:***:1:1:192.168.1.5',
        'shun-lan:1:$key:0:1:192.168.1.5',
        'shun-lan:1:$key:70000:1:192.168.1.5',
        'shun-lan:1:$key:x:1:192.168.1.5',
        'shun-lan:1:$key:1:x:192.168.1.5',
      ]) {
        expect(LanPairing.tryParse(text), isNull, reason: text);
      }
    });

    test('二维码不能指挥手机去连局域网以外的地址', () {
      final key = sample.encode().split(':')[2];
      for (final address in [
        '8.8.8.8',
        '127.0.0.1',
        '100.100.1.1',
        '172.32.0.1',
        '::1',
        'example.com',
        '',
        '192.168.1.5,8.8.8.8',
      ]) {
        expect(
          LanPairing.tryParse('shun-lan:1:$key:22:1:$address'),
          isNull,
          reason: address,
        );
      }
    });

    test('isLanAddress 只认私有 IPv4 三段', () {
      for (final address in [
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.1',
        '192.168.0.1'
      ]) {
        expect(isLanAddress(address), isTrue, reason: address);
      }
      for (final address in [
        '172.15.0.1',
        '192.169.0.1',
        '11.0.0.1',
        '100.64.0.1'
      ]) {
        expect(isLanAddress(address), isFalse, reason: address);
      }
    });
  });

  group('传输', () {
    test('扫了码的拿到原文；发送方知道传完了，端口关掉', () async {
      final sender = await startSender();
      final received = await receiveLanTransfer(sender.pairing);
      expect(received, plain);
      expect(await sender.outcome, LanSendOutcome.delivered);
      await expectLater(
        Socket.connect('127.0.0.1', sender.pairing.port),
        throwsA(isA<SocketException>()),
      );
    });

    test('密钥只用一次：传完后同一张二维码再扫拿不到', () async {
      final sender = await startSender();
      await receiveLanTransfer(sender.pairing);
      await expectLater(
        receiveLanTransfer(sender.pairing),
        throwsA(isA<LanTransferUnreachable>()),
      );
    });

    test('错密钥：报不是同一台，拿不到密文；发送方继续等，正主还能拿', () async {
      final sender = await startSender();
      final relay = await Relay.start(sender.pairing.port);
      final wrong = withKey(relay.pairing(sender.pairing), List.filled(32, 7));
      await expectLater(
        receiveLanTransfer(wrong),
        throwsA(isA<LanTransferWrongPeer>()),
      );
      // 握手只回了随机数和 MAC：没有 4 字节长度，没有密文。
      expect(relay.toClient.length, 64);
      expect(await receiveLanTransfer(sender.pairing), plain);
    });

    test('知道协议但没密钥的客户端：证明不了就拿不到密文', () async {
      final sender = await startSender();
      final socket = await Socket.connect('127.0.0.1', sender.pairing.port);
      addTearDown(socket.destroy);
      final got = BytesBuilder();
      final closed = Completer<void>();
      socket.listen(got.add, onDone: closed.complete);
      socket
        ..add(ascii.encode('SHUNLAN1'))
        ..add(List.filled(32, 1));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      socket.add(List.filled(32, 2));
      await closed.future.timeout(const Duration(seconds: 5));
      expect(got.length, 64, reason: '只有随机数和 MAC');
    });

    test('握手不对的连接（端口扫描）不会打断互传', () async {
      final sender = await startSender();
      for (var i = 0; i < 3; i++) {
        final socket = await Socket.connect('127.0.0.1', sender.pairing.port);
        socket.add(utf8.encode('GET / HTTP/1.1\r\n\r\n${'x' * 64}'));
        await socket.flush();
        socket.destroy();
      }
      expect(await receiveLanTransfer(sender.pairing), plain);
    });

    test('网络上看得到的字节里没有原文和密钥', () async {
      final sender = await startSender();
      final relay = await Relay.start(sender.pairing.port);
      expect(await receiveLanTransfer(relay.pairing(sender.pairing)), plain);
      final wire = latin1.decode([
        ...relay.toClient.toBytes(),
        ...relay.toServer.toBytes(),
      ]);
      expect(wire, isNot(contains('HOST-SECRET')));
      expect(wire, isNot(contains(latin1.decode(sender.pairing.key))));
    });

    test('密文被改一个字节：报内容校验没过，发送方不算传完', () async {
      final sender = await startSender();
      // 64 字节握手 + 4 字节长度之后是密文。
      final relay = await Relay.start(sender.pairing.port, tamperAfter: 80);
      await expectLater(
        receiveLanTransfer(relay.pairing(sender.pairing)),
        throwsA(isA<LanTransferDamaged>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      var finished = false;
      unawaited(sender.outcome.then((_) => finished = true));
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      expect(await receiveLanTransfer(sender.pairing), plain);
    });

    test('过期就关端口，扫不到', () async {
      final sender = await startSender(
        validFor: const Duration(milliseconds: 100),
      );
      expect(await sender.outcome, LanSendOutcome.expired);
      await expectLater(
        receiveLanTransfer(sender.pairing),
        throwsA(isA<LanTransferUnreachable>()),
      );
    });

    test('页面关掉就关端口', () async {
      final sender = await startSender();
      await sender.close();
      expect(await sender.outcome, LanSendOutcome.closed);
      await expectLater(
        Socket.connect('127.0.0.1', sender.pairing.port),
        throwsA(isA<SocketException>()),
      );
    });

    test('端口没人听：报连不上', () async {
      final free = await ServerSocket.bind('127.0.0.1', 0);
      final port = free.port;
      await free.close();
      await expectLater(
        receiveLanTransfer(LanPairing(
          addresses: loopback,
          port: port,
          key: List.filled(32, 0),
          expiresAt: DateTime.now(),
        )),
        throwsA(isA<LanTransferUnreachable>()),
      );
    });

    test('连上了却没回应（VPN 的本地栈就这样）：报连不上，不卡住', () async {
      final blackhole = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(blackhole.close);
      final held = <Socket>[];
      blackhole.listen(held.add);
      addTearDown(() {
        for (final socket in held) {
          socket.destroy();
        }
      });
      await expectLater(
        receiveLanTransfer(
          LanPairing(
            addresses: loopback,
            port: blackhole.port,
            key: List.filled(32, 0),
            expiresAt: DateTime.now(),
          ),
          handshakeTimeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<LanTransferUnreachable>()),
      );
    });

    test('一个地址不通、一个通：照样拿到', () async {
      final sender = await startSender();
      // 不通的那个用 127.0.0.2：同端口没人听。
      final received = await receiveLanTransfer(LanPairing(
        addresses: const ['127.0.0.2', '127.0.0.1'],
        port: sender.pairing.port,
        key: sender.pairing.key,
        expiresAt: sender.pairing.expiresAt,
      ));
      expect(received, plain);
    });

    test('几兆的内容也传得完', () async {
      final big = Uint8List(4 * 1024 * 1024);
      for (var i = 0; i < big.length; i += 4096) {
        big[i] = i & 0xff;
      }
      final sender = await startSender(content: big);
      expect(await receiveLanTransfer(sender.pairing), big);
      expect(await sender.outcome, LanSendOutcome.delivered);
    });

    test('绑不上的地址从二维码里去掉，一个都绑不上就报错', () async {
      final sender = await LanTransferSender.start(
        plain,
        addresses: const ['192.0.2.1', '127.0.0.1'],
      );
      addTearDown(sender.close);
      expect(sender.pairing.addresses, loopback);
      await expectLater(
        LanTransferSender.start(plain, addresses: const ['192.0.2.1']),
        throwsA(isA<SocketException>()),
      );
      await expectLater(
        LanTransferSender.start(plain, addresses: const []),
        throwsA(isA<LanTransferUnreachable>()),
      );
    });
  });
}
