import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/credential_availability.dart';
import 'package:shun/application/tailscale_catalog_import.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/credential_identity.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/security_key.dart';
import 'package:shun/domain/tailscale_ssh.dart';
import 'package:shun/domain/vault_secrets.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';
import 'package:shun/presentation/widgets/first_login_dialog.dart';
import 'package:shun/presentation/widgets/host_address_line.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/keychain_sheet.dart';
import 'package:shun/presentation/widgets/proxy_profile_editor.dart';

import 'support/soft_authenticator.dart';
import 'support/route_editor_actions.dart';

// F31 / R69：连接上可以直接填用户名密码，也可以选「凭据」，选完回显。不迁移：手机上已有主机不改也能连。
void main() {
  final hasKeygen = Process.runSync('which', ['ssh-keygen']).exitCode == 0;
  late Directory dir;
  late SoftAuthenticator securityKey;
  setUpAll(() async {
    if (!hasKeygen) return;
    dir = await Directory.systemTemp.createTemp('shun-login-');
    securityKey = await SoftAuthenticator.create(dir, skEd25519Type);
  });
  tearDownAll(() async {
    if (hasKeygen) await dir.delete(recursive: true);
  });

  final secrets = <String, String>{};
  late ProviderContainer container;

  Map<String, dynamic> identity(String id, Map<String, dynamic> fields) => {
        'id': id,
        'label': id,
        'created': 1,
        ...fields,
      };

  Map<String, dynamic> hostJson(String id, [Map<String, dynamic>? extra]) => {
        'id': id,
        'label': id,
        'hostname': '192.0.2.10',
        'username': 'root',
        'port': 22,
        'protocol': 'ssh',
        'authMethod': 'auto',
        ...?extra,
      };

  Future<void> boot(
    WidgetTester tester,
    Widget home, {
    List<Map<String, dynamic>> hosts = const [],
    List<Map<String, dynamic>> proxyProfiles = const [],
    Map<String, String> stored = const {},
    bool withSecurityKey = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    secrets
      ..clear()
      ..['identity.pw.password'] = 'IDENTITY-PW'
      ..addAll(stored);
    if (withSecurityKey) {
      secrets['key.sk.private'] = securityKey.stub.toPem();
    }
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
        'hosts': hosts,
        'keys': [
          {'id': 'k1', 'label': 'laptop', 'type': 'ED25519'},
          if (withSecurityKey)
            {'id': 'sk', 'label': 'phone', 'type': 'ED25519'},
        ],
        'snippets': const [],
        'customGroups': const [],
        'proxyProfiles': proxyProfiles,
        'identities': [
          identity('pw', {'username': 'ops', 'authMethod': 'password'}),
          identity('ask', {'username': 'asker', 'authMethod': 'password'}),
          identity('key', {
            'username': 'deploy',
            'authMethod': 'key',
            'keyId': 'k1',
          }),
          if (withSecurityKey)
            identity('hard', {
              'username': 'yubi',
              'authMethod': 'key',
              'keyId': 'sk',
            }),
        ],
      }),
    });
    final repository = await VaultRepository.open();
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await container.read(vaultControllerProvider.notifier).ready();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  VaultData vault() => container.read(vaultControllerProvider).data!;

  group('主机编辑器', () {
    HostProfile? saved;

    Future<void> openEditor(
      WidgetTester tester, {
      Map<String, dynamic>? host,
      Map<String, String> stored = const {},
      bool withSecurityKey = false,
    }) async {
      saved = null;
      await boot(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                final hosts = ProviderScope.containerOf(context)
                    .read(vaultControllerProvider)
                    .data!
                    .hosts;
                saved = await Navigator.push<HostProfile>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HostEditor(host: hosts.firstOrNull),
                  ),
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
        hosts: [if (host != null) host],
        stored: stored,
        withSecurityKey: withSecurityKey,
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
    }

    Future<void> choose(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const ValueKey('ssh-login-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(const ValueKey('host-identity')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('credential-option-$id')));
      await tester.pumpAndSettle();
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('host-editor-save')));
      await tester.pumpAndSettle();
    }

    Finder field(String label) => find.widgetWithText(TextFormField, label);
    String text(WidgetTester tester, String label) =>
        tester.widget<TextFormField>(field(label)).controller!.text;

    testWidgets('新建默认用户名 / 密码：只有这两个框，存在主机上', (tester) async {
      await openEditor(tester);
      expect(find.text('用户名 / 密码'), findsOneWidget);
      expect(find.text('SSH 私钥'), findsNothing);
      await tester.enterText(field('名称'), 'nas');
      await tester.enterText(field('主机名 / IP'), '192.0.2.20');
      await tester.enterText(field('用户名'), 'admin');
      await tester.enterText(field('密码（可选）'), 'S3CRET');
      await tester.pump();
      await save(tester);
      expect(saved!.username, 'admin');
      expect(saved!.password, 'S3CRET');
      expect(saved!.data.containsKey('identityId'), isFalse);
      expect(saved!.authMethod, HostAuthMethod.auto);
    });

    testWidgets('选凭据：没选中不让存；选完回显名称、用户名、方式；存好以后主机上不留旧密码和私钥', (tester) async {
      await openEditor(
        tester,
        host: hostJson('web', {'identityFileId': 'k1'}),
        stored: {'host.web.password': 'OLD-PW'},
      );
      await choose(tester, '凭据');
      expect(field('用户名'), findsNothing, reason: '用户名在凭据里');
      await save(tester);
      expect(saved, isNull);
      expect(find.text('选一个凭据'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('host-identity')));
      await tester.pumpAndSettle();
      expect(find.text('ops · 密码'), findsOneWidget);
      expect(find.text('asker · 密码（连接时问）'), findsOneWidget);
      expect(find.text('deploy · SSH 密钥“laptop”'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('credential-option-pw')));
      await tester.pumpAndSettle();
      final summary = find.byKey(const ValueKey('credential-summary'));
      expect(find.descendant(of: summary, matching: find.text('pw')),
          findsOneWidget);
      expect(find.descendant(of: summary, matching: find.text('ops · 密码')),
          findsOneWidget);
      await openRouteEditor(tester);
      expect(find.textContaining('ops@192.0.2.10:22'), findsWidgets,
          reason: '路线预览写凭据的用户名');

      await save(tester);
      expect(saved!.data['identityId'], 'pw');
      expect(saved!.username, 'ops');
      expect(saved!.data.containsKey('password'), isFalse);
      expect(saved!.identityFileId, isNull);
      expect(saved!.authMethod, HostAuthMethod.auto);
    });

    testWidgets('保存前切回用户名 / 密码：填过的都在，凭据不生效', (tester) async {
      await openEditor(
        tester,
        host: hostJson('web'),
        stored: {'host.web.password': 'OLD-PW'},
      );
      await choose(tester, '凭据');
      await pick(tester, 'pw');
      await choose(tester, '用户名 / 密码');
      expect(text(tester, '用户名'), 'root');
      expect(text(tester, '密码（可选）'), 'OLD-PW');
      await save(tester);
      expect(saved!.data.containsKey('identityId'), isFalse);
      expect(saved!.username, 'root');
      expect(saved!.password, 'OLD-PW');
    });

    testWidgets('选凭据时能当场新建：存进保险库、马上选中；密码只进安全存储', (tester) async {
      await openEditor(tester, host: hostJson('web'));
      await choose(tester, '凭据');
      await tester.tap(find.byKey(const ValueKey('host-identity')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('credential-new')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('identity-username')), 'fresh');
      await tester.enterText(
          find.byKey(const ValueKey('identity-password')), 'NEW-SECRET');
      await tester.tap(find.byKey(const ValueKey('identity-save')));
      await tester.pumpAndSettle();
      expect(find.text('fresh · 密码'), findsOneWidget);
      await save(tester);
      final created = vaultIdentities(vault()).last;
      expect(created.username, 'fresh');
      expect(saved!.data['identityId'], created.id);
      expect(saved!.username, 'fresh');
      expect(secrets['identity.${created.id}.password'], 'NEW-SECRET');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shun_vault_v1'), isNot(contains('NEW-SECRET')));
    });

    testWidgets('老主机自带私钥又存了密码：不动就原样存；点「不用了」才去掉私钥', (tester) async {
      await openEditor(
        tester,
        host: hostJson('old', {'identityFileId': 'k1'}),
        stored: {'host.old.password': 'OLD-PW'},
      );
      expect(find.text('私钥“laptop”'), findsOneWidget);
      expect(field('密码（可选）'), findsOneWidget, reason: '自动：私钥和密码都会试');
      await save(tester);
      expect(saved!.identityFileId, 'k1');
      expect(saved!.password, 'OLD-PW');
      expect(saved!.authMethod, HostAuthMethod.auto);

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('own-key-drop')));
      await tester.pumpAndSettle();
      expect(find.text('私钥“laptop”'), findsNothing);
      await save(tester);
      expect(saved!.identityFileId, isNull);
      expect(saved!.password, 'OLD-PW');
    });

    testWidgets('老主机只用私钥：登录不发密码所以不显示密码框；不用了以后存的密码还在', (tester) async {
      await openEditor(
        tester,
        host: hostJson('old', {'authMethod': 'key', 'identityFileId': 'k1'}),
        stored: {'host.old.password': 'KEPT'},
      );
      expect(field('密码（可选）'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('own-key-drop')));
      await tester.pumpAndSettle();
      expect(text(tester, '密码（可选）'), 'KEPT');
      await save(tester);
      expect(saved!.authMethod, HostAuthMethod.auto);
      expect(saved!.identityFileId, isNull);
    });

    testWidgets('只用私钥但私钥已经删了：按用户名 / 密码存，不卡住保存', (tester) async {
      await openEditor(
        tester,
        host: hostJson('old', {'authMethod': 'key', 'identityFileId': 'gone'}),
      );
      await save(tester);
      expect(saved!.authMethod, HostAuthMethod.auto);
      expect(saved!.identityFileId, isNull);
    });

    testWidgets('存为凭据：私钥 + 密码的老主机预填成「SSH 密钥 + 密码」，存完主机改用它，展开后登录不变',
        (tester) async {
      await openEditor(
        tester,
        host: hostJson('old', {'identityFileId': 'k1'}),
        stored: {'host.old.password': 'OLD-PW'},
      );
      final saveAs = find.byKey(const ValueKey('host-save-as-credential'));
      await tester.ensureVisible(saveAs);
      await tester.pumpAndSettle();
      await tester.tap(saveAs);
      await tester.pumpAndSettle();
      expect(find.text('SSH 密钥 + 密码'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('identity-label')), 'old-login');
      await tester.tap(find.byKey(const ValueKey('identity-save')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('host-identity')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('root · SSH 密钥“laptop” + 密码'), findsOneWidget);
      await save(tester);

      final created = vaultIdentities(vault()).last;
      expect(created.label, 'old-login');
      expect(created.auth, IdentityAuth.keyAndPassword);
      expect(saved!.data['identityId'], created.id);
      expect(saved!.data.containsKey('password'), isFalse);
      expect(saved!.identityFileId, isNull);

      final expanded = Map<String, dynamic>.of(saved!.data);
      applyHostIdentity(expanded, vaultIdentityMaps(vault()));
      expect(expanded['authMethod'], 'auto', reason: '还是先公钥再密码');
      expect(expanded['identityFileId'], 'k1');
      expect(expanded['password'], 'OLD-PW');
    });

    testWidgets('安全密钥的凭据回显成安全密钥，不写成 SSH 密钥', (tester) async {
      await openEditor(tester, host: hostJson('web'), withSecurityKey: true);
      await choose(tester, '凭据');
      await pick(tester, 'hard');
      expect(find.text('yubi · 安全密钥“phone”'), findsOneWidget);
      await save(tester);
      final expanded = Map<String, dynamic>.of(saved!.data);
      applyHostIdentity(expanded, vaultIdentityMaps(vault()));
      expect(expanded['identityFileId'], 'sk');
      expect(expanded['authMethod'], 'key');
    }, skip: !hasKeygen);

    testWidgets('Tailscale SSH：要用户名，不要密码和凭据；主机上存的留着', (tester) async {
      await openEditor(
        tester,
        host: hostJson('web'),
        stored: {'host.web.password': 'KEPT'},
      );
      await choose(tester, 'Tailscale SSH');
      expect(field('用户名'), findsOneWidget);
      expect(field('密码（可选）'), findsNothing);
      await save(tester);
      expect(saved!.data[sshLoginModeKey], 'tailscale');
      expect(saved!.password, 'KEPT');
      expect(saved!.data.containsKey('identityId'), isFalse);
    });

    testWidgets('引用的凭据不在了（桌面端删的）：按用户名 / 密码显示，不挂着一个找不到的', (tester) async {
      await openEditor(tester, host: hostJson('web', {'identityId': 'gone'}));
      expect(text(tester, '用户名'), 'root');
      await save(tester);
      expect(saved!.data.containsKey('identityId'), isFalse);
    });
  });

  group('凭据本身', () {
    testWidgets('改凭据的用户名：引用它的主机列表跟着变', (tester) async {
      await boot(
        tester,
        const KeychainSheet(),
        hosts: [
          hostJson('a', {'identityId': 'pw', 'username': 'ops'}),
          hostJson('b'),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('keychain-identity-pw')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('identity-username')), 'ops2');
      await tester.tap(find.byKey(const ValueKey('identity-save')));
      await tester.pumpAndSettle();
      final hosts = {for (final host in vault().hosts) host.id: host};
      expect(hosts['a']!.username, 'ops2');
      expect(hosts['b']!.username, 'root', reason: '没引用的不动');
      expect(vaultIdentities(vault()).first.id, 'pw', reason: '编辑的留在原位置');
    });

    testWidgets('删凭据：列出在用的主机和代理，确认后引用一并去掉', (tester) async {
      await boot(
        tester,
        const KeychainSheet(),
        hosts: [
          hostJson('a', {'identityId': 'pw'})
        ],
        proxyProfiles: [
          {
            'id': 'p',
            'label': 'office-proxy',
            'identityId': 'pw',
            'config': {'type': 'socks5', 'host': '192.0.2.1', 'port': 1080},
          },
        ],
      );
      await tester
          .tap(find.byKey(const ValueKey('keychain-delete-identity-pw')));
      await tester.pumpAndSettle();
      expect(find.textContaining('a、office-proxy'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('keychain-confirm-delete-identity')));
      await tester.pumpAndSettle();
      expect(vault().hosts.single.data.containsKey('identityId'), isFalse);
      expect(vault().proxyProfiles.single.data.containsKey(proxyIdentityKey),
          isFalse);
      expect(vaultIdentities(vault()).any((item) => item.id == 'pw'), isFalse);
    });

    testWidgets('类型选安全密钥只列安全密钥，选 SSH 密钥只列普通私钥；换类型清掉不匹配的选择', (tester) async {
      await boot(tester, const KeychainSheet(), withSecurityKey: true);
      await tester.tap(find.byKey(const ValueKey('keychain-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建凭据').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('identity-username')), 'u');

      Future<void> kind(String label) async {
        await tester.tap(find.byKey(const ValueKey('identity-auth')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      Future<void> openKeys() async {
        await tester.tap(find.byKey(const ValueKey('identity-key')));
        await tester.pumpAndSettle();
      }

      List<String?> listed() => [
            for (final item in tester
                .widget<DropdownButton<String>>(find.descendant(
                  of: find.byKey(const ValueKey('identity-key')),
                  matching: find.byType(DropdownButton<String>),
                ))
                .items!)
              item.value,
          ];

      await kind('SSH 密钥');
      expect(listed(), ['k1']);
      await openKeys();
      await tester.tap(find.text('laptop').last);
      await tester.pumpAndSettle();

      await kind('安全密钥');
      await tester.tap(find.byKey(const ValueKey('identity-save')));
      await tester.pumpAndSettle();
      expect(find.text('选一把安全密钥'), findsOneWidget, reason: '别的类型选的不算');
      expect(listed(), ['sk']);
      await openKeys();
      await tester.tap(find.text('phone').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('identity-save')));
      await tester.pumpAndSettle();
      final created = vaultIdentities(vault()).last;
      expect(created.keyId, 'sk');
      expect(created.data['authMethod'], 'key');
    }, skip: !hasKeygen);

    testWidgets('主机列表的地址行写凭据的用户名', (tester) async {
      final host = HostProfile(hostJson('a', {'identityId': 'pw'}));
      await boot(
        tester,
        Scaffold(body: HostAddressLine(host)),
        hosts: [host.toJson()],
      );
      expect(find.text('ops@192.0.2.10:22'), findsOneWidget);
    });
  });

  group('首次登录', () {
    testWidgets('选凭据：选中前不让连，选中后不用填用户名，写回这一台', (tester) async {
      final host = HostProfile(hostJson('new', {'username': ''}));
      FirstLogin? result;
      await boot(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await askFirstLogin(context, host);
            },
            child: const Text('go'),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      final connect = find.byKey(const ValueKey('first-login-connect'));
      await tester.tap(find.byKey(const ValueKey('first-login-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('凭据').last);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(connect).onPressed, isNull);
      expect(find.byKey(const ValueKey('first-login-username')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('first-login-credential')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('credential-option-ask')));
      await tester.pumpAndSettle();
      expect(find.text('asker · 密码（连接时问）'), findsOneWidget);
      await tester.tap(connect);
      await tester.pumpAndSettle();
      final updated = hostWithFirstLogin(host, result!);
      expect(updated.data['identityId'], 'ask');
      expect(updated.username, 'asker');
      expect(updated.data.containsKey('password'), isFalse);
    });

    test('选了凭据就算配好了：没存密码的连接时问，不再弹首次登录', () {
      final bound = HostProfile(hostJson('t', {
        'username': '',
        'identityId': 'ask',
        CatalogBinding.key:
            const CatalogBinding(catalogId: 'c', deviceId: 'd').toJson(),
      }));
      final identities = [
        identity('ask', {'username': 'asker', 'authMethod': 'password'}),
      ];
      expect(needsFirstLogin(bound, identities: identities), isFalse);
      expect(needsFirstLogin(bound), isTrue, reason: '凭据不在了就回到没配的状态');
    });
  });

  group('Tailscale 导入', () {
    final cache = CatalogCache(
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
    );
    final store = VaultData.fromJson({
      'hosts': const [],
      'identities': [
        {
          'id': 'pw',
          'label': 'pw',
          'username': 'ops',
          'authMethod': 'password',
          'password': 'IDENTITY-PW',
        },
      ],
    });

    test('默认凭据：存的只是 ID，导入的主机引用它，用户名同步', () {
      final defaults = CatalogImportDefaults.fromJson(
        const CatalogImportDefaults(identityId: 'pw').toJson(),
      );
      expect(defaults.identityId, 'pw');
      expect(defaults.toJson().toString(), isNot(contains('IDENTITY-PW')));
      final result = buildCatalogImport(
        cache: cache,
        deviceIds: const ['1'],
        options: defaults.options(),
        vault: store,
        newId: () => 'h',
      );
      final host = result.hosts.single;
      expect(host.data['identityId'], 'pw');
      expect(host.username, 'ops');
      expect(host.data.containsKey('password'), isFalse);
    });

    test('默认凭据删了：照样导入，第一次连接时问', () {
      final result = buildCatalogImport(
        cache: cache,
        deviceIds: const ['1'],
        options: const CatalogImportDefaults(identityId: 'gone').options(),
        vault: store,
        newId: () => 'h',
      );
      final host = result.hosts.single;
      expect(host.data.containsKey('identityId'), isFalse);
      expect(needsFirstLogin(host), isTrue);
    });

    test('有凭据之前存的默认私钥照常生效', () {
      final result = buildCatalogImport(
        cache: cache,
        deviceIds: const ['1'],
        options: CatalogImportDefaults.fromJson(const {
          'username': 'ubuntu',
          'identityFileId': 'k1',
        }).options(),
        vault: store,
        newId: () => 'h',
      );
      expect(result.hosts.single.identityFileId, 'k1');
      expect(result.hosts.single.username, 'ubuntu');
    });
  });

  group('代理用凭据', () {
    HostProfile target() => HostProfile(hostJson('t', {'proxyProfileId': 'p'}));
    ProxyProfile profile([String? credential = 'pw']) => ProxyProfile({
          'id': 'p',
          'label': 'office',
          if (credential != null) proxyIdentityKey: credential,
          'config': {'type': 'socks5', 'host': '192.0.2.1', 'port': 1080},
        });
    final identities = [
      identity('pw', {
        'username': 'proxy-user',
        'authMethod': 'password',
        'password': 'PROXY-PW',
      }),
      identity('key', {
        'username': 'deploy',
        'authMethod': 'key',
        'keyId': 'k1',
      }),
    ];

    test('连接时取凭据现在的用户名密码；路线形状含用户名，密码不进形状', () {
      final plan = resolveRoutePlan(
        target(),
        hosts: const [],
        proxyProfiles: [profile()],
        identities: identities,
      );
      final entry = plan.entry as ProxyEntry;
      expect(entry.username, 'proxy-user');
      expect(entry.password, 'PROXY-PW');
      expect(plan.shape, contains('proxy-user'));
      expect(plan.shape, isNot(contains('PROXY-PW')));
      expect((plan.withoutSecrets().entry as ProxyEntry).password, isNull);
      expect(plan.toString(), isNot(contains('PROXY-PW')));
    });

    test('凭据删了、换成密钥了：拨号前报清楚；只算路线形状的地方不报', () {
      expect(
        () => resolveRoutePlan(
          target(),
          hosts: const [],
          proxyProfiles: [profile('gone')],
          identities: identities,
        ),
        throwsA(isA<RouteConfigException>()
            .having((error) => error.message, 'message', contains('已经删了'))),
      );
      expect(
        () => resolveRoutePlan(
          target(),
          hosts: const [],
          proxyProfiles: [profile('key')],
          identities: identities,
        ),
        throwsA(isA<RouteConfigException>()
            .having((error) => error.message, 'message', contains('不是用户名密码'))),
      );
      expect(
        () => resolveRoutePlan(
          target(),
          hosts: const [],
          proxyProfiles: [profile('gone')],
        ),
        returnsNormally,
      );
    });

    test('手填的老代理配置照常用', () {
      final plan = resolveRoutePlan(
        target(),
        hosts: const [],
        proxyProfiles: [
          ProxyProfile({
            'id': 'p',
            'label': 'office',
            'config': {
              'type': 'socks5',
              'host': '192.0.2.1',
              'port': 1080,
              'username': 'manual',
              'password': 'MANUAL',
            },
          }),
        ],
        identities: identities,
      );
      final entry = plan.entry as ProxyEntry;
      expect(entry.username, 'manual');
      expect(entry.password, 'MANUAL');
    });

    test('代理用的凭据密码解不开：连接前拦下，不拿空密码去试', () {
      final data = VaultData.fromJson({
        'hosts': [target().toJson()],
        'proxyProfiles': [profile().toJson()],
        'identities': identities,
      });
      expect(
        unreadableCredentialProblem(
          data.hosts.single,
          data,
          {'identity.pw.password'},
        ),
        contains('代理口令'),
      );
    });

    testWidgets('编辑代理：只列存了密码的凭据，存好以后配置里没有账号密码', (tester) async {
      await boot(
        tester,
        ProxyProfileEditor(
          profile: ProxyProfile({
            'id': 'p',
            'label': 'office',
            'config': {
              'type': 'socks5',
              'host': '192.0.2.1',
              'port': 1080,
              'username': 'manual',
              'password': 'MANUAL',
            },
          }),
        ),
        proxyProfiles: [
          {
            'id': 'p',
            'label': 'office',
            'config': {
              'type': 'socks5',
              'host': '192.0.2.1',
              'port': 1080,
              'username': 'manual',
            },
          },
        ],
        stored: {'proxy.p.password': 'MANUAL'},
      );
      await tester.tap(find.byKey(const ValueKey('proxy-login-choice')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('凭据').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('proxy-credential')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('credential-option-pw')), findsOneWidget);
      expect(find.byKey(const ValueKey('credential-option-ask')), findsNothing,
          reason: '没存密码：代理没法连接时问');
      expect(find.byKey(const ValueKey('credential-option-key')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('credential-option-pw')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('proxy-save')));
      await tester.pumpAndSettle();
      final saved = vault().proxyProfiles.single;
      expect(saved.data[proxyIdentityKey], 'pw');
      expect(saved.config!.username, isNull);
      expect(saved.config!.password, isNull);
      expect(secrets.containsKey('proxy.p.password'), isFalse);
    });
  });
}
