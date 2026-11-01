import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/tailscale_catalog_import.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/credential_identity.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/security_key.dart';
import 'package:shun/infrastructure/ssh/ssh_client_defaults.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';

import 'fixtures/docker_fixture.dart';
import 'support/soft_authenticator.dart';

// R69 / CRD01–CRD03：选了凭据的主机在真 OpenSSH 上登录。主机数据都按编辑器保存时的写法来（[useCredentialOn]），
// 主机自己的用户名是错的：登得进去只能是用了凭据里的。界面怎么出这份数据在 login_choice_test 里测。
// 依赖 tool/fixture-environment，没起 fixture 时整组 skip。不含 Tailscale SSH：那要真 tailnet。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = DockerFixture.load();
  final skip = fixture == null ? DockerFixture.skipReason : false;

  HostProfile edge([Map<String, Object?> extra = const {}]) => HostProfile({
        'id': 'edge',
        'label': 'edge',
        'hostname': fixture!.edgeHost,
        'port': fixture.edgePort,
        'username': 'nobody-here',
        'authMethod': 'password',
        'protocol': 'ssh',
        ...extra,
      });

  /// 编辑器选凭据并保存后的主机。原来的密码和私钥引用要被清掉。
  HostProfile usingCredential(
    Map<String, dynamic> identity, [
    Map<String, Object?> before = const {'password': 'old-host-password'},
  ]) {
    final host = edge(before);
    useCredentialOn(host.data, IdentityProfile(identity));
    return host;
  }

  Map<String, dynamic> credential(Map<String, dynamic> fields) => {
        'id': 'i',
        'label': 'i',
        ...fields,
      };

  final asked = <String>[];
  Future<ActiveTerminalSession> connect(
    HostProfile host, {
    List<Map<String, dynamic>> identities = const [],
    List<SshKeyProfile> keys = const [],
    List<ProxyProfile> proxies = const [],
    String? answer,
    SshService? service,
  }) =>
      (service ?? SshService()).connect(
        terminal: GhosttyTerminalAdapter(),
        sessionId: 'crd',
        host: host,
        hosts: [host],
        keys: keys,
        identities: identities,
        proxyProfiles: proxies,
        verifyHostKey: (_, __, fingerprint) async =>
            fingerprint == fixture!.edgeFingerprint ||
            fingerprint == fixture.targetFingerprint,
        keyboardInteractive: (_, __, prompts) async {
          asked.addAll(prompts.map((prompt) => prompt.text));
          return answer == null ? null : [answer];
        },
      );

  Future<String> run(ActiveTerminalSession session, String command) =>
      session.sshClient!.run(command).then((out) => utf8.decode(out).trim());

  Future<List<String>> edgeLog() async {
    final result = await Process.run('docker', [
      'compose',
      '-f',
      'tool/fixture-environment/compose.yaml',
      'logs',
      '--no-color',
      'ssh-edge',
    ]);
    return const LineSplitter().convert('${result.stdout}');
  }

  SshKeyProfile plainKey() => SshKeyProfile(
      {'id': 'k', 'label': 'k', 'privateKey': fixture!.privateKeyPem});

  setUp(asked.clear);

  group('CRD01 凭据在真 OpenSSH 上登录', () {
    test('用户名密码直接填：填了不问；没填当场问', () async {
      final saved = await connect(
        edge({'username': fixture!.user, 'password': fixture.password}),
      );
      addTearDown(saved.close);
      expect(await run(saved, 'whoami'), fixture.user);
      expect(asked, isEmpty);

      final asking = await connect(
        edge({'username': fixture.user}),
        answer: fixture.password,
      );
      addTearDown(asking.close);
      expect(await run(asking, 'whoami'), fixture.user);
      expect(asked, hasLength(1));
    }, skip: skip);

    test('密码凭据：用凭据里的用户名密码，主机上原来那个密码不发', () async {
      final identity = credential({
        'username': fixture!.user,
        'authMethod': 'password',
        'password': fixture.password,
      });
      final before = await edgeLog();
      final session =
          await connect(usingCredential(identity), identities: [identity]);
      addTearDown(session.close);
      expect(await run(session, 'whoami'), fixture.user);
      expect(asked, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final lines = (await edgeLog()).sublist(before.length);
      expect(lines.where((line) => line.contains('Failed password')), isEmpty);
    }, skip: skip);

    test('凭据没存密码：连接时问，不拿主机上的旧密码去试', () async {
      final identity = credential({
        'username': fixture!.user,
        'authMethod': 'password',
      });
      final before = await edgeLog();
      final session = await connect(
        usingCredential(identity),
        identities: [identity],
        answer: fixture.password,
      );
      addTearDown(session.close);
      expect(await run(session, 'whoami'), fixture.user);
      expect(asked, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final lines = (await edgeLog()).sublist(before.length);
      expect(lines.where((line) => line.contains('Failed password')), isEmpty,
          reason: '旧密码没清掉的话，这里会有一次密码错误');
    }, skip: skip);

    test('SSH 密钥凭据', () async {
      final identity = credential({
        'username': fixture!.user,
        'authMethod': 'key',
        'keyId': 'k',
      });
      final session = await connect(
        usingCredential(identity),
        identities: [identity],
        keys: [plainKey()],
      );
      addTearDown(session.close);
      expect(await run(session, 'whoami'), fixture.user);
      expect(asked, isEmpty);
    }, skip: skip);

    test('带口令的密钥凭据：口令对能登录，错了在拨号前报清楚', () async {
      final f = fixture!;
      final dir = await Directory.systemTemp.createTemp('shun-crd01-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/id')..writeAsStringSync(f.privateKeyPem);
      await Process.run('chmod', ['600', file.path]);
      final encrypted = await Process.run('ssh-keygen',
          ['-q', '-p', '-P', '', '-N', 'right-pass', '-f', file.path]);
      expect(encrypted.exitCode, 0, reason: '${encrypted.stderr}');
      SshKeyProfile key(String passphrase) => SshKeyProfile({
            'id': 'k',
            'label': 'k',
            'privateKey': file.readAsStringSync(),
            'passphrase': passphrase,
          });
      final identity = credential({
        'username': f.user,
        'authMethod': 'key',
        'keyId': 'k',
      });
      final session = await connect(
        usingCredential(identity),
        identities: [identity],
        keys: [key('right-pass')],
      );
      addTearDown(session.close);
      expect(await run(session, 'whoami'), f.user);

      await expectLater(
        connect(
          usingCredential(identity),
          identities: [identity],
          keys: [key('wrong-pass')],
        ),
        throwsA(predicate((Object e) => '$e'.contains('私钥口令不对'))),
      );
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('密钥 + 密码凭据：服务器要两步都过', () async {
      final identity = credential({
        'username': 'twostep',
        'authMethod': 'key',
        'keyId': 'k',
        'password': fixture!.password,
      });
      final session = await connect(
        usingCredential(identity),
        identities: [identity],
        keys: [plainKey()],
      );
      addTearDown(session.close);
      expect(await run(session, 'whoami'), 'twostep');
    }, skip: skip);

    test('安全密钥凭据（软件认证器）：只碰一次钥匙', () async {
      final f = fixture!;
      final dir = await Directory.systemTemp.createTemp('shun-crd01-sk-');
      addTearDown(() => dir.delete(recursive: true));
      final authenticator =
          await SoftAuthenticator.create(dir, skEd25519Type);
      const marker = 'shun-crd01-test';
      Future<void> onEdge(String command) async {
        final client = SSHClient(
          await SSHSocket.connect(f.edgeHost, f.edgePort),
          username: f.user,
          onPasswordRequest: () => f.password,
        );
        try {
          await client.authenticated;
          await client.run(command);
        } finally {
          client.closeQuietly();
        }
      }

      final line = '${authenticator.stub.type} '
          '${base64.encode(authenticator.stub.publicKey)} $marker';
      await onEdge(
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$line' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys",
      );
      addTearDown(
        () => onEdge("sed -i '/$marker/d' ~/.ssh/authorized_keys"),
      );
      final identity = credential({
        'username': f.user,
        'authMethod': 'key',
        'keyId': 'sk',
      });
      final session = await connect(
        usingCredential(identity),
        identities: [identity],
        keys: [
          SshKeyProfile({
            'id': 'sk',
            'label': 'sk',
            'privateKey': authenticator.stub.toPem(),
          }),
        ],
        service: SshService()..securityKeySigner = authenticator.call,
      );
      addTearDown(session.close);
      expect(await run(session, 'whoami'), f.user);
      expect(authenticator.requests, hasLength(1));
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('改了凭据，引用它的主机下次连接就用新的：密码改错就登不进，换用户就是新用户', () async {
      final f = fixture!;
      final host = usingCredential(credential({
        'username': f.user,
        'authMethod': 'password',
        'password': f.password,
      }));
      await expectLater(
        connect(host, identities: [
          credential({
            'username': f.user,
            'authMethod': 'password',
            'password': 'wrong',
          }),
        ]),
        throwsA(predicate((Object e) => '$e'.contains('登录被拒绝'))),
      );
      final session = await connect(
        host,
        identities: [
          credential({
            'username': 'twostep',
            'authMethod': 'key',
            'keyId': 'k',
            'password': f.password,
          }),
        ],
        keys: [plainKey()],
      );
      addTearDown(session.close);
      expect(await run(session, 'whoami'), 'twostep');
    }, skip: skip);
  });

  group('CRD02 旧保险库不迁移', () {
    // 先公钥再密码的账号：登得进去就说明主机自带的密码和私钥都用上了。
    HostProfile legacy() => edge({
          'username': 'twostep',
          'authMethod': 'auto',
          'password': fixture!.password,
          'identityFileId': 'k',
        });

    test('不操作直接连；存成凭据再连，主机上的副本清掉；换回用户名密码', () async {
      final f = fixture!;
      final untouched = await connect(legacy(), keys: [plainKey()]);
      addTearDown(untouched.close);
      expect(await run(untouched, 'whoami'), 'twostep');

      // 「存为凭据」的预填（host_editor 的 _saveAsCredential）。
      final saved = credential({
        'username': 'twostep',
        'authMethod': 'key',
        'keyId': 'k',
        'password': f.password,
      });
      final host = legacy();
      useCredentialOn(host.data, IdentityProfile(saved));
      expect(host.data.containsKey('password'), isFalse);
      expect(host.data.containsKey('identityFileId'), isFalse);
      expect(jsonEncode(host.data), isNot(contains(f.password)));
      final viaCredential = await connect(
        host,
        identities: [saved],
        keys: [plainKey()],
      );
      addTearDown(viaCredential.close);
      expect(await run(viaCredential, 'whoami'), 'twostep');

      final back = HostProfile({
        ...host.data,
        'username': f.user,
        'authMethod': 'password',
        'password': f.password,
      })
        ..data.remove('identityId');
      final plain = await connect(back, identities: [saved]);
      addTearDown(plain.close);
      expect(await run(plain, 'whoami'), f.user);
    }, skip: skip);

    test('删了凭据：主机只剩自己的用户名，连接时问密码，不挂着不动', () async {
      final identity = credential({
        'username': fixture!.user,
        'authMethod': 'password',
        'password': fixture.password,
      });
      final host = usingCredential(identity);
      final session = await connect(
        host,
        identities: const [],
        answer: fixture.password,
      );
      addTearDown(session.close);
      expect(await run(session, 'whoami'), fixture.user);
      expect(asked, hasLength(1));
    }, skip: skip);
  });

  group('CRD03 代理和 Tailscale 导入', () {
    ProxyProfile proxy(String credentialId) => ProxyProfile({
          'id': 'p',
          'label': 'office',
          proxyIdentityKey: credentialId,
          'config': {
            'type': 'socks5',
            'host': fixture!.socksAuthHost,
            'port': fixture.socksAuthPort,
          },
        });
    HostProfile target() => HostProfile({
          'id': 'target',
          'label': 'target',
          'hostname': fixture!.targetName,
          'port': fixture.targetPort,
          'username': fixture.user,
          'password': fixture.password,
          'authMethod': 'password',
          'protocol': 'ssh',
          'proxyProfileId': 'p',
        });

    test('代理选凭据：经真 dante 到目标；凭据密码改错就被代理拒绝', () async {
      Map<String, dynamic> socks(String password) => credential({
            'username': fixture!.socksUser,
            'authMethod': 'password',
            'password': password,
          });
      final session = await connect(
        target(),
        identities: [socks(fixture!.socksPassword)],
        proxies: [proxy('i')],
      );
      addTearDown(session.close);
      expect(await run(session, 'hostname'), 'target');

      await expectLater(
        connect(
          target(),
          identities: [socks('wrong')],
          proxies: [proxy('i')],
        ),
        throwsA(anything),
      );
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('Tailscale 默认凭据：导入的主机引用它，没填过用户名也能登上', () async {
      final identity = credential({
        'username': fixture!.user,
        'authMethod': 'password',
        'password': fixture.password,
      });
      final result = buildCatalogImport(
        cache: CatalogCache(
          catalogId: 'ts',
          tailnet: '-',
          devices: {
            '1': CatalogDeviceRecord(
              firstSeenAt: DateTime.utc(2026),
              lastListedAt: DateTime.utc(2026),
              device: const TailscaleDevice(
                id: '1',
                name: 'nas.tail.ts.net',
                hostname: 'nas',
                addresses: ['100.64.0.1'],
              ),
            ),
          },
        ),
        deviceIds: const ['1'],
        options: const CatalogImportDefaults(identityId: 'i').options(),
        vault: VaultData.fromJson({
          'hosts': const [],
          'identities': [identity],
        }),
        newId: () => 'h',
      );
      final imported = result.hosts.single;
      expect(imported.data.containsKey('password'), isFalse);
      // 地址换成测试环境：不碰真 tailnet，测的是导入出来的这份登录配置。
      imported.data['hostname'] = fixture.edgeHost;
      imported.data['port'] = fixture.edgePort;
      imported.data['protocol'] = 'ssh';
      final session = await connect(imported, identities: [identity]);
      addTearDown(session.close);
      expect(await run(session, 'whoami'), fixture.user);
      expect(asked, isEmpty);
    }, skip: skip);
  });
}
