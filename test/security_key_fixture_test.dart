import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/connection_lifecycle.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/security_key.dart';
import 'package:shun/infrastructure/ssh/ssh_client_defaults.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';

import 'fixtures/docker_fixture.dart';
import 'support/soft_authenticator.dart';
import 'support/test_terminal.dart';

// SKY01：软件认证器按 CTAP2 算法签名，经真 OpenSSH 登录，sshd 说了算。
// 只证明格式和流程；真钥匙的触摸、PIN、NFC、USB 是 SKY02–SKY04，这里过了不算它们过。
// 依赖 tool/fixture-environment，没起 fixture 时整组 skip。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = DockerFixture.load();
  final skip = fixture == null ? DockerFixture.skipReason : false;
  late Directory dir;
  late SoftAuthenticator ed25519;
  late SoftAuthenticator ecdsa;

  Future<T> withPasswordClient<T>(
    String host,
    int port,
    Future<T> Function(SSHClient client) body,
  ) async {
    final socket = await SSHSocket.connect(host, port);
    final client = SSHClient(
      socket,
      username: fixture!.user,
      onPasswordRequest: () => fixture.password,
    );
    try {
      await client.authenticated;
      return await body(client);
    } finally {
      client.closeQuietly();
    }
  }

  /// 把测试密钥写进 authorized_keys。走跳板的测试还要写进目标机，所以经 edge 转发。
  Future<void> editAuthorizedKeys(String command) async {
    final f = fixture!;
    await withPasswordClient(f.edgeHost, f.edgePort, (client) async {
      await client.run(command);
      final forward = await client.forwardLocal(f.targetName, f.targetPort);
      final target = SSHClient(
        forward,
        username: f.user,
        onPasswordRequest: () => f.password,
      );
      try {
        await target.authenticated;
        await target.run(command);
      } finally {
        target.closeQuietly();
      }
    });
  }

  const marker = 'shun-sky01-test';

  setUpAll(() async {
    if (fixture == null) return;
    dir = await Directory.systemTemp.createTemp('shun-sky01-');
    ed25519 = await SoftAuthenticator.create(dir, skEd25519Type);
    ecdsa = await SoftAuthenticator.create(dir, skEcdsaType);
    final lines = [ed25519, ecdsa]
        .map((key) =>
            '${key.stub.type} ${base64.encode(key.stub.publicKey)} $marker')
        .join(r'\n');
    await editAuthorizedKeys(
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '$lines\\n' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys",
    );
  });
  tearDownAll(() async {
    if (fixture == null) return;
    await editAuthorizedKeys("sed -i '/$marker/d' ~/.ssh/authorized_keys");
    await dir.delete(recursive: true);
  });

  SshKeyProfile keyOf(SoftAuthenticator authenticator) => SshKeyProfile({
        'id': 'sk',
        'label': 'sk',
        'privateKey': authenticator.stub.toPem(),
      });

  HostProfile edge() => HostProfile({
        'id': 'edge',
        'label': 'edge',
        'hostname': fixture!.edgeHost,
        'port': fixture.edgePort,
        'username': fixture.user,
        'authMethod': 'key',
        'identityFileId': 'sk',
        'protocol': 'ssh',
      });

  Future<ProbeOutcome> probe(
    SoftAuthenticator authenticator, {
    ConnectionAttempt? attempt,
  }) {
    final ssh = SshService()..securityKeySigner = authenticator.call;
    final host = edge();
    return ssh.probe(
      host: host,
      hosts: [host],
      keys: [keyOf(authenticator)],
      verifyHostKey: (_, __, ___) async => true,
      attempt: attempt ?? ConnectionAttempt(),
    );
  }

  group('SKY01 真 OpenSSH', () {
    test('Ed25519-SK 和 ECDSA-SK 都能登录，只碰一次钥匙', () async {
      for (final key in [ed25519, ecdsa]) {
        key.requests.clear();
        final outcome = await probe(key);
        expect(outcome.tty, isNotNull);
        expect(key.requests, hasLength(1));
        expect(key.requests.single.hostLabel, 'edge');
        expect(key.requests.single.username, fixture!.user);
      }
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('签完改任何一个字节，sshd 都拒绝', () async {
      final cases =
          <String, SecurityKeyAssertion Function(SecurityKeyAssertion)>{
        'flags': (value) => SecurityKeyAssertion(
              authenticatorData: Uint8List.fromList(value.authenticatorData)
                ..[32] ^= 0x04,
              signature: value.signature,
            ),
        'counter': (value) => SecurityKeyAssertion(
              authenticatorData: Uint8List.fromList(value.authenticatorData)
                ..[36] ^= 0x01,
              signature: value.signature,
            ),
        'signature': (value) => SecurityKeyAssertion(
              authenticatorData: value.authenticatorData,
              signature: Uint8List.fromList(value.signature)..[10] ^= 0x01,
            ),
      };
      try {
        for (final entry in cases.entries) {
          ed25519.tamper = entry.value;
          await expectLater(
            probe(ed25519),
            throwsA(anything),
            reason: '改 ${entry.key} 不该通过',
          );
        }
      } finally {
        ed25519.tamper = null;
      }
      // rpId 的摘要不上线，sshd 自己按公钥里的 application 算：钥匙按别的 rpId 签，它也算不对。
      ed25519.signingApplication = 'ssh:other';
      try {
        await expectLater(probe(ed25519), throwsA(anything));
      } finally {
        ed25519.signingApplication = null;
      }
    }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

    test('签名多一个字节：绕过我们自己的检查直接发，sshd 也拒绝', () async {
      final f = fixture!;
      Future<SSHClient> login(int extra) async => SSHClient(
            await SSHSocket.connect(f.edgeHost, f.edgePort),
            username: f.user,
            identities: [
              SSHIdentity.custom(
                type: ed25519.stub.type,
                publicKey: SSHRawHostKey(ed25519.stub.publicKey),
                signer: (data) async {
                  final assertion = await ed25519.call(
                    SecurityKeySignRequest(
                      key: ed25519.stub,
                      data: data,
                      hostLabel: 'edge',
                      username: f.user,
                    ),
                  );
                  return SSHRawSignature(
                    Uint8List.fromList([
                      ...encodeSecurityKeySignature(ed25519.stub, assertion),
                      ...List<int>.filled(extra, 0),
                    ]),
                  );
                },
              ),
            ],
          );

      // 对照：同样的路子不多字节能过，下面的拒绝才算数。
      final good = await login(0);
      await good.authenticated;
      good.closeQuietly();

      final bad = await login(1);
      await expectLater(bad.authenticated, throwsA(isA<SSHAuthFailError>()));
      bad.closeQuietly();
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('跳板和目标各碰一次：每一跳分别确认', () async {
      final f = fixture!;
      ed25519.requests.clear();
      final jump = edge();
      final target = HostProfile({
        'id': 'target',
        'label': 'target',
        'hostname': f.targetName,
        'port': f.targetPort,
        'username': f.user,
        'authMethod': 'key',
        'identityFileId': 'sk',
        'protocol': 'ssh',
        'hostChain': {
          'hostIds': ['edge'],
        },
      });
      final ssh = SshService()..securityKeySigner = ed25519.call;
      final outcome = await ssh.probe(
        host: target,
        hosts: [jump, target],
        keys: [keyOf(ed25519)],
        verifyHostKey: (_, __, ___) async => true,
        attempt: ConnectionAttempt(),
      );
      expect(outcome.tty, isNotNull);
      expect(
          ed25519.requests.map((value) => value.hostLabel), ['edge', 'target']);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('服务器不认这把钥匙：不碰钥匙，直接换下一种', () async {
      final stranger = await SoftAuthenticator.create(dir, skEd25519Type);
      await expectLater(probe(stranger), throwsA(anything));
      expect(stranger.requests, isEmpty, reason: '探测被拒就不该让人碰');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('用户取消：报取消，不算网络问题，不重试', () async {
      ed25519.requests.clear();
      ed25519.failWith =
          const SecurityKeyException(SecurityKeyFailure.cancelled);
      try {
        final Object error = await probe(ed25519).then<Object>(
          (_) => fail('取消了还能登录'),
          onError: (Object error) => error,
        );
        expect('$error', contains('取消了安全密钥签名'));
        expect(isTransientConnectionError(error), isFalse);
        expect(ed25519.requests, hasLength(1));
      } finally {
        ed25519.failWith = null;
      }
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('自动恢复（restore）：不碰钥匙，停下说要人来', () async {
      ed25519.requests.clear();
      final ssh = SshService()..securityKeySigner = ed25519.call;
      final host = edge();
      final Object error = await ssh
          .connect(
            sessionId: 'sky01-restore',
            host: host,
            hosts: [host],
            keys: [keyOf(ed25519)],
            verifyHostKey: (_, __, ___) async => true,
            terminal: newTestTerminal(),
            purpose: ConnectionPurpose.restore,
          )
          .then<Object>(
            (_) => fail('恢复时不该登录成功'),
            onError: (Object error) => error,
          );
      expect(ed25519.requests, isEmpty);
      expect('$error', contains('自动恢复不会替你碰'));
      expect(isTransientConnectionError(error), isFalse);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
  });
}
