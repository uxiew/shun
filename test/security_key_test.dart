import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/connection_diagnosis.dart';
import 'package:shun/application/connection_lifecycle.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/security_key.dart';
import 'package:shun/domain/ssh_key_type.dart';
import 'package:shun/infrastructure/ssh/ssh_client_defaults.dart';
import 'package:shun/infrastructure/ssh/ssh_identity.dart';

import 'support/soft_authenticator.dart';

// R59：句柄文件读写、签名打包、公钥解析。文件格式拿真的 ssh-keygen 对照，它不用钥匙就能读写这种文件。
// 登录能不能过 sshd 这一关在 test/security_key_fixture_test.dart。
void main() {
  final hasKeygen = Process.runSync('which', ['ssh-keygen']).exitCode == 0;
  late Directory dir;
  late SoftAuthenticator ed25519;
  late SoftAuthenticator ecdsa;

  setUpAll(() async {
    if (!hasKeygen) return;
    dir = await Directory.systemTemp.createTemp('shun-sk-');
    ed25519 = await SoftAuthenticator.create(
      dir,
      skEd25519Type,
      comment: 'phone key',
    );
    ecdsa = await SoftAuthenticator.create(
      dir,
      skEcdsaType,
      application: 'ssh:work',
      flags: skFlagUserPresence | skFlagUserVerification | skFlagResident,
    );
  });
  tearDownAll(() async {
    if (hasKeygen) await dir.delete(recursive: true);
  });

  final skip = hasKeygen ? false : '没有 ssh-keygen';

  String written(String name, String pem) {
    final file = File('${dir.path}/$name')..writeAsStringSync(pem);
    Process.runSync('chmod', ['600', file.path]);
    return file.path;
  }

  group('句柄文件', () {
    test('写出来的文件真 ssh-keygen 认，公钥一字不差', () {
      for (final key in [ed25519, ecdsa]) {
        final path = written('stub-${key.stub.type}', key.stub.toPem());
        final result = Process.runSync('ssh-keygen', ['-y', '-f', path]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final parts = '${result.stdout}'.trim().split(' ');
        expect(parts[0], key.stub.type);
        expect(parts[1], base64.encode(key.stub.publicKey));
      }
    }, skip: skip);

    test('真 ssh-keygen 重写过的文件能读回全部字段', () {
      for (final key in [ed25519, ecdsa]) {
        final path = written('rewrite-${key.stub.type}', key.stub.toPem());
        final rewrite = Process.runSync(
          'ssh-keygen',
          ['-q', '-p', '-P', '', '-N', '', '-f', path],
        );
        expect(rewrite.exitCode, 0, reason: '${rewrite.stderr}');
        final parsed = SecurityKeyStub.parse(File(path).readAsStringSync());
        expect(parsed.type, key.stub.type);
        expect(parsed.publicKey, key.stub.publicKey);
        expect(parsed.application, key.stub.application);
        expect(parsed.flags, key.stub.flags);
        expect(parsed.keyHandle, key.stub.keyHandle);
        expect(parsed.comment, key.stub.comment);
      }
    }, skip: skip);

    test('带口令的文件：口令对能读，错了、没存都说得清', () {
      final path = written('encrypted', ed25519.stub.toPem());
      final encrypt = Process.runSync(
        'ssh-keygen',
        ['-q', '-p', '-P', '', '-N', 'right-pass', '-f', path],
      );
      expect(encrypt.exitCode, 0, reason: '${encrypt.stderr}');
      final pem = File(path).readAsStringSync();

      // 不要口令也认得出是安全密钥、读得出公钥：这两样在文件的明文段。
      expect(SecurityKeyStub.isStubPem(pem), isTrue);
      expect(sshKeyTypeOf(pem), 'ED25519-SK');
      expect(
        SecurityKeyStub.publicKeyLineOf(pem)!.split(' ').take(2).join(' '),
        ed25519.stub.publicKeyLine.split(' ').take(2).join(' '),
      );

      RouteHop hop(String? passphrase) => hopWith(pem, passphrase: passphrase);
      final identity = loadHopIdentities(hop('right-pass'))!.single;
      expect(identity.type, skEd25519Type);
      expect(identity.toPublicKey().encode(), ed25519.stub.publicKey);
      expect(
        () => loadHopIdentities(hop('wrong')),
        throwsA(
          isA<SshIdentityException>().having(
            (error) => error.message,
            'message',
            contains('口令不对'),
          ),
        ),
      );
      expect(
        () => loadHopIdentities(hop(null)),
        throwsA(
          isA<SshIdentityException>().having(
            (error) => error.message,
            'message',
            contains('没有保存口令'),
          ),
        ),
      );
    }, skip: skip);

    test('普通私钥、坏文件都不算安全密钥', () {
      final path = '${dir.path}/plain';
      Process.runSync('ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-f',
        path,
      ]);
      expect(SecurityKeyStub.isStubPem(File(path).readAsStringSync()), isFalse);
      expect(SecurityKeyStub.isStubPem('not a key'), isFalse);
      expect(
        SecurityKeyStub.isStubPem(
          '-----BEGIN OPENSSH PRIVATE KEY-----\n!!!\n'
          '-----END OPENSSH PRIVATE KEY-----',
        ),
        isFalse,
      );
    }, skip: skip);

    test('截断的文件报「已损坏」，不把内容带进消息', () {
      final pem = ed25519.stub.toPem();
      final lines = const LineSplitter().convert(pem.trim());
      final body = base64.decode(lines.sublist(1, lines.length - 1).join());
      final broken = [
        lines.first,
        base64.encode(body.sublist(0, body.length - 40)),
        lines.last,
      ].join('\n');
      expect(
        () => SecurityKeyStub.parse(broken),
        throwsA(
          isA<SecurityKeyStubException>().having(
            (error) => error.message,
            'message',
            '安全密钥文件内容已损坏',
          ),
        ),
      );
    }, skip: skip);

    test('标志位', () {
      expect(ed25519.stub.userPresenceRequired, isTrue);
      expect(ed25519.stub.userVerificationRequired, isFalse);
      expect(ecdsa.stub.userVerificationRequired, isTrue);
      expect(securityKeyVaultType(skEd25519Type), 'ED25519-SK');
      expect(securityKeyVaultType(skEcdsaType), 'ECDSA-SK');
    }, skip: skip);
  });

  group('签名打包（PROTOCOL.u2f）', () {
    final authData = Uint8List.fromList([
      ...List.filled(32, 0xAB),
      0x05,
      0x00,
      0x00,
      0x01,
      0x02,
    ]);

    test('Ed25519：类型名 + 签名 + flags + counter', () {
      final bytes = encodeSecurityKeySignature(
        ed25519.stub,
        SecurityKeyAssertion(
          authenticatorData: authData,
          signature: Uint8List.fromList(List.filled(64, 7)),
        ),
      );
      final expected = [
        0, 0, 0, skEd25519Type.length, ...utf8.encode(skEd25519Type), //
        0, 0, 0, 64, ...List.filled(64, 7),
        0x05, 0x00, 0x00, 0x01, 0x02,
      ];
      expect(bytes, expected);
    }, skip: skip);

    test('ECDSA：DER 拆成两个 mpint，保留开头的 0', () {
      final r = [0x00, 0x80, 1, 2];
      final s = [0x7F, 3];
      final der = Uint8List.fromList([
        0x30, r.length + s.length + 4, 0x02, r.length, ...r, //
        0x02, s.length, ...s,
      ]);
      final bytes = encodeSecurityKeySignature(
        ecdsa.stub,
        SecurityKeyAssertion(authenticatorData: authData, signature: der),
      );
      final expected = [
        0, 0, 0, skEcdsaType.length, ...utf8.encode(skEcdsaType), //
        0, 0, 0, 4 + r.length + 4 + s.length,
        0, 0, 0, r.length, ...r,
        0, 0, 0, s.length, ...s,
        0x05, 0x00, 0x00, 0x01, 0x02,
      ];
      expect(bytes, expected);
    }, skip: skip);

    test('钥匙回的东西不对就报错，不发给服务器', () {
      void rejects(SecurityKeyStub key, Uint8List auth, Uint8List signature) {
        expect(
          () => encodeSecurityKeySignature(
            key,
            SecurityKeyAssertion(authenticatorData: auth, signature: signature),
          ),
          throwsA(
            isA<SecurityKeyException>().having(
              (error) => error.failure,
              'failure',
              SecurityKeyFailure.transport,
            ),
          ),
        );
      }

      final good = Uint8List.fromList(List.filled(64, 7));
      // 37 字节以外：带了扩展数据。
      rejects(ed25519.stub, Uint8List(38), good);
      rejects(ed25519.stub, authData, Uint8List(63));
      // DER 多一个字节、不是 SEQUENCE。
      rejects(
        ecdsa.stub,
        authData,
        Uint8List.fromList([0x30, 0x06, 0x02, 0x01, 1, 0x02, 0x01, 2, 0xFF]),
      );
      rejects(ecdsa.stub, authData, Uint8List.fromList([0x31, 0x00]));
      rejects(ecdsa.stub, authData, Uint8List(0));
    }, skip: skip);

    test('要触摸的钥匙回了「没碰过」：当场报错，不拿去让服务器拒绝', () {
      final noPresence = Uint8List.fromList(authData)..[32] = 0x04;
      expect(
        () => encodeSecurityKeySignature(
          ed25519.stub,
          SecurityKeyAssertion(
            authenticatorData: noPresence,
            signature: Uint8List(64),
          ),
        ),
        throwsA(isA<SecurityKeyException>()),
      );
    }, skip: skip);
  });

  group('钥匙给的公钥', () {
    test('注册结果里取出句柄和公钥，后面跟扩展数据也不怕', () {
      final credentialId = List.generate(20, (index) => index);
      final cose = [0xA4, 0x01, 0x01, 0x03, 0x27, 0x20, 0x06, 0x21, 0x58, 0x20];
      final authData = Uint8List.fromList([
        ...List.filled(37, 1),
        ...List.filled(16, 2), // aaguid
        0, credentialId.length, ...credentialId, //
        ...cose, ...List.filled(32, 9),
        0xA1, 0x61, 0x78, 0x01, // 扩展数据
      ]);
      final parsed = CoseKey.fromAttestedData(authData);
      expect(parsed.credentialId, credentialId);
      expect(parsed.key.sshType, skEd25519Type);
      expect(parsed.key.x, List.filled(32, 9));
    });

    test('SSH 用不了的算法（比如 RS256）说不支持', () {
      final rsa =
          Uint8List.fromList([0xA2, 0x01, 0x03, 0x03, 0x39, 0x01, 0x00]);
      expect(
        () => CoseKey.parse(rsa),
        throwsA(
          isA<SecurityKeyException>().having(
            (error) => error.failure,
            'failure',
            SecurityKeyFailure.unsupported,
          ),
        ),
      );
    });

    test('被截断的注册结果报通信失败', () {
      expect(
        () => CoseKey.fromAttestedData(Uint8List(40)),
        throwsA(isA<SecurityKeyException>()),
      );
    });
  });

  group('登录身份', () {
    test('安全密钥不做自签自验，签名时才问钥匙，还会先探测', () async {
      final hop = hopWith(ed25519.stub.toPem());
      final seen = <SecurityKeySignRequest>[];
      final identity = loadHopIdentities(
        hop,
        securityKeySigner: (request) async {
          seen.add(request);
          return ed25519.signRaw(request.data);
        },
      )!
          .single;
      expect(seen, isEmpty, reason: '解析时不能碰钥匙');
      expect(identity.shouldProbe, isTrue, reason: '服务器不认这把钥匙时不能让人白碰一次');
      expect(identity.toPublicKey().encode(), ed25519.stub.publicKey);

      final data = Uint8List.fromList([1, 2, 3]);
      final signature = await identity.sign(data);
      expect(seen.single.data, data);
      expect(seen.single.hostLabel, 'web');
      expect(seen.single.username, 'deploy');
      final bytes = signature.encode();
      expect(
        utf8.decode(bytes.sublist(4, 4 + skEd25519Type.length)),
        skEd25519Type,
      );
    }, skip: skip);

    test('没有界面可问（自动恢复）：签名时报要人来，不静默碰钥匙', () async {
      final identity = loadHopIdentities(hopWith(ed25519.stub.toPem()))!.single;
      await expectLater(
        Future.sync(() => identity.sign(Uint8List(1))),
        throwsA(isA<SecurityKeyNeedsUser>()),
      );
    }, skip: skip);

    test('普通私钥照旧', () {
      final path = '${dir.path}/plain-2';
      Process.runSync('ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-f',
        path,
      ]);
      final identity =
          loadHopIdentities(hopWith(File(path).readAsStringSync()))!.single;
      expect(identity, isA<SSHKeyPair>());
    }, skip: skip);
  });

  group('错误', () {
    SSHAuthAbortError wrapped(Object cause) =>
        SSHAuthAbortError('x', SSHInternalError(cause));

    test('钥匙的错不是网络问题：不自动重试，诊断说清楚', () {
      for (final cause in <Object>[
        const SecurityKeyNeedsUser(),
        const SecurityKeyException(SecurityKeyFailure.cancelled),
        const SecurityKeyException(SecurityKeyFailure.timeout),
      ]) {
        final error = wrapped(cause);
        expect(securityKeyCauseOf(error), cause);
        expect(isTransientConnectionError(error), isFalse);
      }
      expect(
        securityKeyCauseOf(SSHAuthAbortError('x', SSHInternalError('other'))),
        isNull,
      );
      expect(securityKeyCauseOf(StateError('other')), isNull);
    });

    test('诊断归类成「安全密钥」，不再指向网络', () {
      final kind = classifyConnectionFailure(
        wrapped(const SecurityKeyException(SecurityKeyFailure.timeout)),
      );
      expect(kind, ConnectionFailureKind.securityKey);
      expect(failureLabel(kind), '安全密钥');
    });

    test('每种失败都有一句人话，PIN 还剩几次写出来', () {
      for (final failure in SecurityKeyFailure.values) {
        expect('${SecurityKeyException(failure)}', isNotEmpty);
      }
      expect(
        '${const SecurityKeyException(SecurityKeyFailure.pinInvalid, pinRetries: 3)}',
        contains('3'),
      );
    });
  });
}

RouteHop hopWith(String privateKey, {String? passphrase}) {
  final host = HostProfile({
    'id': 'h',
    'label': 'web',
    'hostname': 'web.example.com',
    'port': 22,
    'username': 'deploy',
    'authMethod': 'key',
    'identityFileId': 'k',
    'protocol': 'ssh',
  });
  return resolveRoutePlan(
    host,
    hosts: [host],
    proxyProfiles: const [],
    keys: [
      SshKeyProfile({
        'id': 'k',
        'label': 'k',
        'privateKey': privateKey,
        if (passphrase != null) 'passphrase': passphrase,
      }),
    ],
  ).target;
}
