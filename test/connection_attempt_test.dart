import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:xterm2/xterm.dart';

import 'fixtures/net/socks5_fixture.dart';

// R08：一次连接尝试的资源所有权——取消/失败关掉半成品、成功后归会话、会话关闭可重复调用。
void main() {
  final host = HostProfile.create(
    id: 'h1',
    label: 'web',
    hostname: 'web.example.com',
    username: 'root',
  );
  Future<bool> accept(HostProfile _, String __, String ___) async => true;

  group('ConnectionAttempt 所有权', () {
    test('取消关掉半成品；移交之后再取消不关会话的资源', () {
      final cancelled = ConnectionAttempt();
      final halfBuilt = _RecordingSocket();
      cancelled.transport = halfBuilt;
      cancelled.cancel();
      cancelled.cancel();
      expect(halfBuilt.destroyed, 1);

      final delivered = ConnectionAttempt();
      final owned = _RecordingSocket();
      delivered.transport = owned;
      delivered.handOver();
      delivered.cancel();
      expect(delivered.isCancelled, isTrue);
      expect(owned.destroyed, 0, reason: '交出去的资源归会话，由会话自己关');
    });

    test('私钥坏了：拨号之前就按这一跳报错，服务器一个连接都收不到', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var accepted = 0;
      server.listen((socket) {
        accepted++;
        socket.destroy();
      });
      final target = HostProfile({
        'id': 'bad-key',
        'label': 'bad-key',
        'hostname': '127.0.0.1',
        'port': server.port,
        'username': 'u',
        'protocol': 'ssh',
        'authMethod': 'key',
        'identityFileId': 'k1',
      });
      final key = SshKeyProfile(
          {'id': 'k1', 'label': 'k1', 'privateKey': 'not a private key'});
      final stages = <ConnectionStep>[];
      final attempt = ConnectionAttempt(onStage: (s) => stages.add(s.step));
      Object? error;
      try {
        await SshService().connect(
          sessionId: 'bad-key',
          host: target,
          hosts: [target],
          keys: [key],
          verifyHostKey: accept,
          attempt: attempt,
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<RouteHopException>());
      expect('$error', contains('读取登录私钥失败'));
      expect('$error', isNot(contains('not a private key')),
          reason: '报错不带私钥原文');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(accepted, 0, reason: '私钥有问题时不该先去连服务器');
      expect(stages, isEmpty);
    });

    test('经代理：阶段依次是经代理、握手；取消后不再上报，握手中的连接被关', () async {
      final ssh = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(ssh.close);
      final serverSide = Completer<Socket>();
      ssh.listen(serverSide.complete); // 接了连接一字节不回，卡在 SSH 版本行
      final proxy = await Socks5Fixture.start(
          names: {'stall.internal': (host: '127.0.0.1', port: ssh.port)});
      addTearDown(proxy.close);
      final target = HostProfile({
        'id': 'stall',
        'label': 'stall',
        'hostname': 'stall.internal',
        'port': 22,
        'username': 'u',
        'protocol': 'ssh',
        'proxyConfig': {'type': 'socks5', 'host': proxy.host, 'port': proxy.port},
      });
      final stages = <ConnectionStep>[];
      final attempt = ConnectionAttempt(onStage: (s) => stages.add(s.step));
      final outcome = SshService()
          .connect(
            sessionId: 'stall',
            host: target,
            hosts: [target],
            verifyHostKey: accept,
            attempt: attempt,
          )
          .then<Object?>((_) => null, onError: (Object e) => e);
      final upstream = await serverSide.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(stages, [ConnectionStep.proxy, ConnectionStep.handshake]);

      attempt.cancel();
      expect(await outcome, isA<ConnectionCancelledException>());
      attempt.report(const ConnectionStage(ConnectionStep.shell));
      expect(stages, [ConnectionStep.proxy, ConnectionStep.handshake]);
      // App 关的是自己到代理的那条连接，代理随之关掉它到上游的那条。
      await upstream.drain<void>().timeout(const Duration(seconds: 2));
    });

    test('ActiveTerminalSession 的 close / abort 可以重复调用', () async {
      final session = ActiveTerminalSession(
        id: 's',
        host: host,
        terminal: Terminal(),
        verifyHostKey: accept,
        keyboardInteractive: null,
      );
      session.abort();
      session.abort();
      await session.close();
      await session.close();
      session.detachOutput();
      expect(session.connected, isFalse);
      expect(session.closedByUser, isTrue);
    });
  });
}

class _RecordingSocket implements SSHSocket {
  int destroyed = 0;

  @override
  void destroy() => destroyed++;

  @override
  Future<void> close() async => destroyed++;

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> flush() async {}

  @override
  StreamSink<List<int>> get sink => throw UnimplementedError();

  @override
  Stream<Uint8List> get stream => const Stream.empty();
}
