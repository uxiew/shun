import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/vault_secrets.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';

// REG03：假秘密不从 toString、报错、导出里漏出去；导出→导入在同一台设备上不丢凭据；
// 改了登录目标的导入文件拿不到本机保存的密码；受管字段和不认识的字段原样保留。
const hostPw = 'HOST-PW-1f3a';
const telnetPw = 'TELNET-PW-9c2e';
const inlineProxyPw = 'INLINE-PROXY-PW-77b1';
const profileProxyPw = 'PROFILE-PROXY-PW-5d04';
const privateKey = '-----BEGIN OPENSSH PRIVATE KEY-----\nKEY-MATERIAL-0e8f\n'
    '-----END OPENSSH PRIVATE KEY-----';
const passphrase = 'KEY-PASS-a61c';
// 桌面端的字段（R26 F25 补上）：身份里的密码、主机的 TOTP 种子（otpauth 链接里的 secret）。
const identityPw = 'IDENTITY-PW-3b9d';
const totpUri = 'otpauth://totp/web?secret=TOTPSEED4K2Q';
const allSecrets = [
  hostPw,
  telnetPw,
  inlineProxyPw,
  profileProxyPw,
  'KEY-MATERIAL-0e8f',
  passphrase,
  identityPw,
  'TOTPSEED4K2Q',
];

VaultData sampleVault() => VaultData.fromJson({
      'hosts': [
        {
          'id': 'h1',
          'label': 'web',
          'hostname': 'web.example.com',
          'port': 22,
          'username': 'deploy',
          'protocol': 'ssh',
          'password': hostPw,
          'telnetPassword': telnetPw,
          'identityFileId': 'k1',
          'proxyConfig': {
            'type': 'socks5',
            'host': '127.0.0.1',
            'port': 1080,
            'username': 'proxy-user',
            'password': inlineProxyPw,
          },
          'managedSource': {'provider': 'tailscale', 'deviceId': 'n1'},
          'x-desktop-only': {'keep': true},
          'identityId': 'i1',
          'totp': {'uri': totpUri, 'label': 'web'},
        },
      ],
      'keys': [
        {
          'id': 'k1',
          'label': 'laptop',
          'privateKey': privateKey,
          'passphrase': passphrase,
          'x-key-extra': 'keep',
        },
      ],
      'proxyProfiles': [
        {
          'id': 'p1',
          'label': 'office',
          'config': {
            'type': 'socks5',
            'host': 'proxy.example.com',
            'port': 1080,
            'username': 'office',
            'password': profileProxyPw,
          },
        },
      ],
      'snippets': [],
      'customGroups': ['Home'],
      'knownHosts': [
        {'hostname': 'web.example.com', 'port': 22, 'fingerprint': 'SHA256:x'},
      ],
      'desktopPluginData': {'preserved': true},
      'identities': [
        {
          'id': 'i1',
          'label': 'ops',
          'username': 'ops',
          'authMethod': 'password',
          'password': identityPw,
          'created': 1,
        },
      ],
    });

void expectNoSecrets(String text, {String? where}) {
  for (final secret in allSecrets) {
    expect(text, isNot(contains(secret)), reason: '${where ?? ''} 漏了 $secret');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('默认文本脱敏', () {
    test('HostProfile.toString 只有 id、名称、协议', () {
      final host = sampleVault().hosts.single;
      expect('$host', 'HostProfile(id: h1, label: web, ssh)');
      expectNoSecrets('$host');
      expect('$host', isNot(contains('deploy')));
    });

    test('连不上时的报错不带密码和代理口令', () async {
      final host = HostProfile({
        ...sampleVault().hosts.single.toJson(),
        'identityFileId': null,
        'proxyConfig': null,
        'hostname': '127.0.0.1',
        'port': 1,
        'sshTcpConnectTimeoutSeconds': 1,
      });
      Object? error;
      try {
        await SshService().connect(
          terminal: GhosttyTerminalAdapter(),
          sessionId: 's',
          host: host,
          hosts: [host],
          verifyHostKey: (_, __, ___) async => true,
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<RouteHopException>());
      expectNoSecrets('$error', where: '报错');
    });

    test('路线配置错误的报错不带口令', () {
      final host = HostProfile({
        ...sampleVault().hosts.single.toJson(),
        'proxyProfileId': 'p1', // 同时引用代理配置又自带代理 → 拒绝
      });
      Object? error;
      try {
        resolveRoutePlan(host,
            hosts: [host],
            proxyProfiles: sampleVault().proxyProfiles,
            keys: []);
      } catch (e) {
        error = e;
      }
      expect(error, isA<RouteConfigException>());
      expectNoSecrets('$error', where: '路线报错');
    });
  });

  group('去掉凭据', () {
    test('全部凭据去掉，受管字段和不认识的字段原样保留，原对象不被改动', () {
      final vault = sampleVault();
      final clean = vaultWithoutSecrets(vault);
      final text = jsonEncode(clean.toJson());
      expectNoSecrets(text, where: '去凭据后的 JSON');
      final host = clean.hosts.single.data;
      expect(
          host['managedSource'], {'provider': 'tailscale', 'deviceId': 'n1'});
      expect(host['x-desktop-only'], {'keep': true});
      expect((host['proxyConfig'] as Map)['username'], 'proxy-user');
      expect(clean.keys.single.data['x-key-extra'], 'keep');
      expect(clean.extras['knownHosts'], isNotEmpty);
      expect(clean.extras['desktopPluginData'], {'preserved': true});
      expect((clean.extras['identities'] as List).single, {
        'id': 'i1',
        'label': 'ops',
        'username': 'ops',
        'authMethod': 'password',
        'created': 1
      });
      expect(host['totp'], {'label': 'web'});
      // 原对象还带着凭据（它是内存里正在用的保险库）。
      expect(vault.hosts.single.password, hostPw);
      expect((vault.hosts.single.data['proxyConfig'] as Map)['password'],
          inlineProxyPw);
      expect(vault.keys.single.privateKey, privateKey);
      expect(((vault.extras['identities'] as List).single as Map)['password'],
          identityPw);
    });
  });

  group('导入时沿用本机凭据', () {
    test('同一条目、登录目标没变：沿用；文件自带凭据的以文件为准', () {
      final local = sampleVault();
      final merged = keepLocalSecrets(vaultWithoutSecrets(local), local);
      final host = merged.hosts.single;
      expect(host.password, hostPw);
      expect(host.data['telnetPassword'], telnetPw);
      expect((host.data['proxyConfig'] as Map)['password'], inlineProxyPw);
      expect(merged.keys.single.privateKey, privateKey);
      expect(merged.keys.single.passphrase, passphrase);
      expect((merged.proxyProfiles.single.data['config'] as Map)['password'],
          profileProxyPw);
      expect(((merged.extras['identities'] as List).single as Map)['password'],
          identityPw);
      expect((host.data['totp'] as Map)['uri'], totpUri);

      final withOwn = VaultData.fromJson(
          jsonDecode(jsonEncode(vaultWithoutSecrets(local).toJson()))
              as Map<String, dynamic>);
      withOwn.hosts.single.data['password'] = 'FROM-FILE';
      expect(
          keepLocalSecrets(withOwn, local).hosts.single.password, 'FROM-FILE');
    });

    test('文件把地址、端口、用户名或代理改了：不沿用，密码不会被发给另一台机器', () {
      final local = sampleVault();
      for (final change in <Map<String, Object>>[
        {'hostname': 'evil.example.com'},
        {'port': 2222},
        {'username': 'root'},
        {'protocol': 'telnet'},
      ]) {
        final incoming = vaultWithoutSecrets(local);
        incoming.hosts.single.data.addAll(change);
        final merged = keepLocalSecrets(incoming, local);
        expect(merged.hosts.single.password, isNull, reason: '$change');
        expect(merged.hosts.single.data['telnetPassword'], isNull,
            reason: '$change');
      }
      final movedProxy = vaultWithoutSecrets(local);
      movedProxy.hosts.single.data['proxyConfig'] = {
        ...movedProxy.hosts.single.data['proxyConfig'] as Map,
        'host': 'evil-proxy.example.com',
      };
      movedProxy.proxyProfiles.single.data['config'] = {
        ...movedProxy.proxyProfiles.single.data['config'] as Map,
        'username': 'someone-else',
      };
      final merged = keepLocalSecrets(movedProxy, local);
      expect(
          (merged.hosts.single.data['proxyConfig'] as Map)['password'], isNull);
      expect((merged.proxyProfiles.single.data['config'] as Map)['password'],
          isNull);
      expect(merged.hosts.single.password, hostPw, reason: '主机本身没变，主机密码照样沿用');

      // 身份换了用户名或登录方式：不是同一个身份了，不沿用。
      for (final change in <Map<String, Object>>[
        {'username': 'root'},
        {'authMethod': 'key'},
      ]) {
        final incoming = vaultWithoutSecrets(local);
        ((incoming.extras['identities'] as List).single as Map).addAll(change);
        final merged = keepLocalSecrets(incoming, local);
        expect(
            ((merged.extras['identities'] as List).single as Map)['password'],
            isNull,
            reason: '$change');
      }
    });

    test('真实存储往返：保存 → 导出 → 导入同一文件 → 重新加载，凭据都还在', () async {
      final secrets = <String, String>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(
                  'plugins.it_nomads.com/flutter_secure_storage'),
              (call) async {
        final args = (call.arguments as Map?) ?? const {};
        final key = args['key'] as String?;
        switch (call.method) {
          case 'write':
            secrets[key!] = args['value'] as String;
          case 'read':
            return secrets[key];
          case 'delete':
            secrets.remove(key);
          case 'readAll':
            return Map<String, String>.from(secrets);
          case 'containsKey':
            return secrets.containsKey(key);
        }
        return null;
      });
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      final controller = VaultController(repository);
      addTearDown(controller.dispose);
      await controller.replace(sampleVault());

      final exported = VaultData.fromJson(jsonDecode(jsonEncode(
              vaultWithoutSecrets(await controller.ready()).toJson()))
          as Map<String, dynamic>);
      await controller
          .replace(keepLocalSecrets(exported, await controller.ready()));

      final reloaded = await (await VaultRepository.open()).loadVault();
      expect(reloaded.hosts.single.password, hostPw);
      expect(reloaded.keys.single.privateKey, privateKey);
      expect((reloaded.proxyProfiles.single.data['config'] as Map)['password'],
          profileProxyPw);
      expect(
          ((reloaded.extras['identities'] as List).single as Map)['password'],
          identityPw);
      expect((reloaded.hosts.single.data['totp'] as Map)['uri'], totpUri);
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expectNoSecrets('${prefs.get(key)}', where: '偏好 $key');
      }

      // 删掉身份：安全存储里它的密码跟着删。
      final withoutIdentity = await controller.ready();
      withoutIdentity.extras['identities'] = <Object>[];
      await controller.replace(withoutIdentity);
      expect(secrets.keys, isNot(contains('identity.i1.password')));
    });

    test('老版本明文存进普通存储的身份密码、TOTP 种子：打开时搬进安全存储，普通存储里抹掉', () async {
      final secrets = <String, String>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(
                  'plugins.it_nomads.com/flutter_secure_storage'),
              (call) async {
        final args = (call.arguments as Map?) ?? const {};
        final key = args['key'] as String?;
        switch (call.method) {
          case 'write':
            secrets[key!] = args['value'] as String;
          case 'read':
            return secrets[key];
          case 'delete':
            secrets.remove(key);
        }
        return null;
      });
      // R26 F25 之前的版本：去凭据时不认这两样，导入桌面端文件后原样写进了偏好。
      final old = vaultWithoutSecrets(sampleVault()).toJson();
      ((old['identities'] as List).single as Map)['password'] = identityPw;
      ((old['hosts'] as List).single as Map)['totp'] = {
        'uri': totpUri,
        'label': 'web'
      };
      SharedPreferences.setMockInitialValues(
          {'shun_vault_v1': jsonEncode(old)});
      final repository = await VaultRepository.open();
      final loaded = await repository.loadVault();
      expect(((loaded.extras['identities'] as List).single as Map)['password'],
          identityPw);
      expect((loaded.hosts.single.data['totp'] as Map)['uri'], totpUri);
      expect(secrets['identity.i1.password'], identityPw);
      expect(secrets['host.h1.totpUri'], totpUri);
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expectNoSecrets('${prefs.get(key)}', where: '偏好 $key');
      }
      final again = await (await VaultRepository.open()).loadVault();
      expect(((again.extras['identities'] as List).single as Map)['password'],
          identityPw);
    });
  });
}
