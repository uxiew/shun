import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/credential_availability.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/credential_identity.dart';
import 'package:shun/domain/host_summary.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/vault_secrets.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/first_login_dialog.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/keychain_sheet.dart';

// R26 F25：「凭据」里的登录身份。格式和展开规则照桌面端 Netcatty（Identity、resolveHostAuth）：
// 身份里的用户名、登录方式、密钥、密码优先；「密钥 + 密码」是带密码的 key，连接时按「自动」先公钥再密码。

Map<String, dynamic> identity(String id, Map<String, dynamic> fields) => {
      'id': id,
      'label': id,
      'created': 1,
      ...fields,
    };

final identities = [
  identity('pw', {
    'username': 'ops',
    'authMethod': 'password',
    'password': 'IDENTITY-PW',
  }),
  identity('key', {'username': 'deploy', 'authMethod': 'key', 'keyId': 'k1'}),
  identity('both', {
    'username': 'admin',
    'authMethod': 'key',
    'keyId': 'k1',
    'password': 'SECOND-STEP',
  }),
  // 桌面端允许身份不填用户名：用主机自己的。
  identity('noname', {'username': '', 'authMethod': 'key', 'keyId': 'k1'}),
];

Map<String, dynamic> hostData(String identityId,
        {Map<String, dynamic>? extra}) =>
    {
      'id': 'h-$identityId',
      'label': 'web-$identityId',
      'hostname': '192.0.2.10',
      'port': 22,
      'username': 'host-user',
      'protocol': 'ssh',
      'authMethod': 'auto',
      'password': 'HOST-PW',
      'identityFileId': 'k2',
      'identityId': identityId,
      ...?extra,
    };

void main() {
  group('展开规则', () {
    Map<String, dynamic> applied(String id) =>
        hostData(id)..also((data) => applyHostIdentity(data, identities));

    test('密码：用身份的用户名和密码，不发主机挂的私钥', () {
      final data = applied('pw');
      expect(data['username'], 'ops');
      expect(data['authMethod'], 'password');
      expect(data['password'], 'IDENTITY-PW');
      expect(data.containsKey('identityFileId'), isFalse);
    });

    test('密钥：只用密钥，用身份引用的那把', () {
      final data = applied('key');
      expect(data['username'], 'deploy');
      expect(data['authMethod'], 'key');
      expect(data['identityFileId'], 'k1');
    });

    test('密钥 + 密码：按「自动」，密钥和密码都给（公钥过了服务器再要密码时发）', () {
      final data = applied('both');
      expect(IdentityProfile(identities[2]).auth, IdentityAuth.keyAndPassword);
      expect(data['username'], 'admin');
      expect(data['authMethod'], 'auto');
      expect(data['identityFileId'], 'k1');
      expect(data['password'], 'SECOND-STEP');
    });

    test('身份没填用户名用主机的；引用的身份不在了就整个用主机自己的（和桌面端一样）', () {
      expect(applied('noname')['username'], 'host-user');
      final gone = applied('deleted');
      expect(gone['username'], 'host-user');
      expect(gone['authMethod'], 'auto');
      expect(gone['password'], 'HOST-PW');
      expect(gone['identityFileId'], 'k2');
    });
  });

  test('路线：目标和跳板都按身份展开；保险库里的主机不被改', () {
    final jump = HostProfile(hostData('key', extra: {
      'id': 'jump',
      'label': 'jump',
      'hostname': '192.0.2.1',
    }));
    final target = HostProfile(hostData('both', extra: {
      'hostChain': {
        'hostIds': ['jump']
      },
    }));
    final keys = [
      SshKeyProfile({'id': 'k1', 'label': 'laptop', 'privateKey': 'K1'}),
      SshKeyProfile({'id': 'k2', 'label': 'old', 'privateKey': 'K2'}),
    ];
    final plan = resolveRoutePlan(
      target,
      hosts: [jump, target],
      proxyProfiles: const [],
      keys: keys,
      identities: identities,
    );
    expect(plan.jumps.single.host.username, 'deploy');
    expect(plan.jumps.single.key?.id, 'k1');
    expect(plan.target.host.username, 'admin');
    expect(plan.target.host.authMethod, HostAuthMethod.auto);
    expect(plan.target.host.password, 'SECOND-STEP');
    expect(plan.target.key?.id, 'k1');
    expect(target.username, 'host-user', reason: '只改路线快照');
    expect(target.identityFileId, 'k2');

    // 去掉凭据后身份里的密码也没了（断线恢复留的那份）。
    final forgotten = plan.withoutSecrets();
    expect(forgotten.target.host.password, isNull);
    expect(forgotten.target.host.username, 'admin');
  });

  group('拨号前的检查和提示', () {
    final vault = VaultData.fromJson({
      'hosts': [hostData('both'), hostData('pw')],
      'keys': [
        {'id': 'k1', 'label': 'laptop', 'privateKey': 'K1'},
      ],
      'identities': identities,
    });

    test('身份的密码解不开：拨号前拦下，说是哪个凭据', () {
      final problem = unreadableCredentialProblem(
          vault.hosts.first, vault, {'identity.both.password'});
      expect(problem, contains('凭据“both”的密码'));
      expect(problem, startsWith('目标“web-both”'));
      // 主机自己的密码解不开，但登录用的是身份的：不拦。
      expect(
          unreadableCredentialProblem(
              vault.hosts.last, vault, {'host.h-pw.password'}),
          isNull);
    });

    test('第一次连接：身份里有用户名就不问', () {
      final noUser = HostProfile(hostData('pw', extra: {'username': ''}));
      expect(needsFirstLogin(noUser), isTrue);
      expect(needsFirstLogin(noUser, identities: vaultIdentityMaps(vault)),
          isFalse);
    });

    test('主机详情写明是哪个凭据、怎么登录', () {
      final host = vault.hosts.first;
      final effective = HostProfile(Map<String, dynamic>.from(host.data));
      applyHostIdentity(effective.data, vaultIdentityMaps(vault));
      expect(
        describeLogin(effective, vault.keys.single,
            identity: hostIdentity(host, vaultIdentityMaps(vault))),
        '凭据“both”：自动：先试私钥“laptop”，再试保存的密码，都不行再问你',
      );
    });
  });

  group('界面', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final secrets = <String, String>{};

    Future<ProviderContainer> open(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      secrets.clear();
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
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
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      SharedPreferences.setMockInitialValues({
        'shun_vault_v1': jsonEncode({
          'hosts': [
            {
              'id': 'web',
              'label': 'web',
              'hostname': '192.0.2.10',
              'username': 'host-user',
              'port': 22,
              'protocol': 'ssh',
              'identityId': 'pw',
            },
          ],
          'keys': [
            {'id': 'k1', 'label': 'laptop', 'type': 'ED25519'},
          ],
          'snippets': const [],
          'customGroups': const [],
          'identities': [
            identity('pw', {'username': 'ops', 'authMethod': 'password'}),
          ],
        }),
      });
      final repository = await VaultRepository.open();
      final container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
      ]);
      addTearDown(container.dispose);
      await container.read(vaultControllerProvider.notifier).ready();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: home),
      ));
      await tester.pumpAndSettle();
      return container;
    }

    List<Map<String, dynamic>> stored(ProviderContainer container) =>
        vaultIdentityMaps(container.read(vaultControllerProvider).data!);

    testWidgets('新建「密钥 + 密码」身份：存成桌面端格式，密码只进安全存储', (tester) async {
      final container = await open(tester, const KeychainSheet());
      expect(find.text('凭据'), findsOneWidget);
      expect(find.textContaining('1 台主机在用'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('keychain-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建凭据').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('identity-username')), 'admin');
      await tester.tap(find.byKey(const ValueKey('identity-auth')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH 密钥 + 密码').last);
      await tester.pumpAndSettle();

      // 没选密钥、没填密码：不存。
      await tester.tap(find.byKey(const ValueKey('identity-save')));
      await tester.pumpAndSettle();
      expect(find.text('选一把 SSH 密钥'), findsOneWidget);
      expect(find.text('「密钥 + 密码」要填密码'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('identity-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('laptop').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('identity-password')), 'SECOND-STEP');
      await tester.tap(find.byKey(const ValueKey('identity-save')));
      await tester.pumpAndSettle();

      final created = stored(container).last;
      expect(created['username'], 'admin');
      expect(created['label'], 'admin', reason: '名称没填就用用户名');
      expect(created['authMethod'], 'key');
      expect(created['keyId'], 'k1');
      expect(created['password'], 'SECOND-STEP');
      expect(secrets['identity.${created['id']}.password'], 'SECOND-STEP');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shun_vault_v1'), isNot(contains('SECOND-STEP')));
      expect(find.textContaining('SSH 密钥“laptop” + 密码'), findsOneWidget);
    });

    testWidgets('删身份先问、写出在用的主机；删了以后主机不再引用它', (tester) async {
      final container = await open(tester, const KeychainSheet());
      await tester
          .tap(find.byKey(const ValueKey('keychain-delete-identity-pw')));
      await tester.pumpAndSettle();
      expect(find.textContaining('这些在用它：web。'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('keychain-confirm-delete-identity')));
      await tester.pumpAndSettle();
      expect(stored(container), isEmpty);
      final host = container.read(vaultControllerProvider).data!.hosts.single;
      expect(host.data.containsKey('identityId'), isFalse);
    });

    testWidgets('删密钥时把引用它的身份也列出来', (tester) async {
      final container = await open(tester, const KeychainSheet());
      final vault = container.read(vaultControllerProvider).data!;
      await container.read(vaultControllerProvider.notifier).replace(
            vault.copyWith(extras: {
              ...vault.extras,
              'identities': [
                identity('deploy', {
                  'username': 'deploy',
                  'authMethod': 'key',
                  'keyId': 'k1',
                }),
              ],
            }),
          );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('keychain-delete-k1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('凭据“deploy”'), findsOneWidget);
    });

    testWidgets('主机编辑器：选了凭据就收起用户名和密码，保存时记下 identityId', (tester) async {
      HostProfile? saved;
      final container = await open(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                final vault = ProviderScope.containerOf(context)
                    .read(vaultControllerProvider)
                    .data!;
                saved = await Navigator.push<HostProfile>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HostEditor(host: vault.hosts.single),
                  ),
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      );
      expect(container, isNotNull);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('credential-summary')), findsOneWidget);
      expect(find.text('ops · 密码（连接时问）'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '用户名'), findsNothing,
          reason: '用户名在凭据里');

      await tester.tap(find.byKey(const ValueKey('ssh-login-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('用户名 / 密码').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, '用户名'))
            .controller!
            .text,
        'host-user',
        reason: '切回来，主机自己的账号还在',
      );

      await tester.tap(find.byKey(const ValueKey('ssh-login-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('凭据').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('host-editor-save')));
      await tester.pumpAndSettle();
      expect(saved?.data['identityId'], 'pw');
      expect(saved?.username, 'ops', reason: '列表和路线预览读主机上的用户名');
    });
  });
}

extension<T> on T {
  T also(void Function(T) action) {
    action(this);
    return this;
  }
}
