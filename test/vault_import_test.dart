import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/application/vault_import.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:netcatty_mobile/presentation/widgets/vault_import_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 导入保险库文件：以前直接整库替换、不问一句，文件里没有的主机连同密码私钥被删。
// 现在先算清楚会新增、更新、删除什么，默认合并；替换要在确认框里明确选。
Map<String, dynamic> host(
  String id, {
  String? label,
  String hostname = 'example.com',
  String username = 'root',
  int port = 22,
  String? password,
}) =>
    {
      'id': id,
      'label': label ?? id,
      'hostname': hostname,
      'port': port,
      'username': username,
      'protocol': 'ssh',
      if (password != null) 'password': password,
    };

VaultData localVault() => VaultData.fromJson({
      'hosts': [
        host('shared',
            label: 'web', hostname: 'web.example.com', password: 'PW-SHARED'),
        host('moved',
            label: 'db', hostname: 'db.example.com', password: 'PW-MOVED'),
        host('mine',
            label: 'hop', hostname: 'hop.example.com', password: 'PW-MINE'),
      ],
      'keys': [
        {'id': 'k-shared', 'label': 'laptop', 'privateKey': 'KEY-SHARED'},
        {'id': 'k-mine', 'label': 'old', 'privateKey': 'KEY-MINE'},
      ],
      'snippets': [
        {'id': 's-mine', 'label': 'uptime', 'command': 'uptime'},
      ],
      'customGroups': ['prod'],
      'proxyProfiles': [
        {
          'id': 'p-shared',
          'label': 'office',
          'config': {
            'type': 'socks5',
            'host': '10.0.0.5',
            'port': 1080,
            'username': 'me',
            'password': 'PROXY-PW',
          },
        },
        {
          'id': 'p-mine',
          'label': 'home',
          'config': {'type': 'http', 'host': '10.0.0.6', 'port': 8080},
        },
      ],
      'knownHosts': [
        {
          'hostname': 'web.example.com',
          'port': 22,
          'keyType': 'ssh-ed25519',
          'fingerprint': 'SHA256:local-verified',
        },
      ],
      'notes': [
        {'id': 'n-mine', 'title': 'local note'},
      ],
      'x-local-only': {'keep': true},
    });

/// 本 App 导出的文件的样子：不带任何凭据。
VaultData fileVault() => VaultData.fromJson({
      'hosts': [
        host('shared', label: 'web', hostname: 'web.example.com'),
        host('moved', label: 'db', hostname: 'db2.example.com'),
        host('new', label: 'cache', hostname: 'cache.example.com'),
      ],
      'keys': [
        {'id': 'k-shared', 'label': 'laptop', 'privateKey': ''},
        {'id': 'k-new', 'label': 'ci', 'privateKey': ''},
      ],
      'snippets': [],
      'customGroups': ['staging'],
      'proxyProfiles': [
        {
          'id': 'p-shared',
          'label': 'office',
          'config': {
            'type': 'socks5',
            'host': '10.0.0.5',
            'port': 1080,
            'username': 'me',
          },
        },
      ],
      'knownHosts': [
        {
          'hostname': 'WEB.example.com.',
          'port': 22,
          'keyType': 'ssh-ed25519',
          'fingerprint': 'SHA256:from-file',
        },
        {
          'hostname': 'cache.example.com',
          'port': 22,
          'keyType': 'ssh-ed25519',
          'fingerprint': 'SHA256:cache',
        },
      ],
      'notes': [
        {'id': 'n-file', 'title': 'file note'},
      ],
      'x-local-only': {'keep': false},
      'x-file-only': 1,
    });

HostProfile byId(VaultData vault, String id) =>
    vault.hosts.firstWhere((value) => value.id == id);

void main() {
  group('导入前算清楚会发生什么', () {
    final plan = planVaultImport(fileVault(), localVault());

    test('新增、更新、本机独有分别列出', () {
      expect(plan.addedHosts.map((h) => h.id), ['new']);
      expect(plan.updatedHosts.map((h) => h.id), ['shared', 'moved']);
      expect(plan.localOnlyHosts.map((h) => h.id), ['mine']);
      expect(plan.localOnlyKeys.map((k) => k.id), ['k-mine']);
      expect(plan.localOnlyProxies.map((p) => p.id), ['p-mine']);
      expect(plan.localOnlySnippets.map((s) => s.id), ['s-mine']);
      expect(plan.hasLocalOnly, isTrue);
    });

    test('改了地址的主机，本机密码不沿用，并点名告诉用户', () {
      expect(plan.credentialsNotCarried, ['db']);
    });

    test('文件里只有名字没有内容、本机也没有的私钥，点名告诉用户', () {
      expect(plan.keysWithoutMaterial.map((k) => k.label), ['ci']);
    });

    test('文件包含本机全部条目时没有本机独有的，合并和替换一样', () {
      final same = planVaultImport(localVault(), localVault());
      expect(same.hasLocalOnly, isFalse);
      expect(same.credentialsNotCarried, isEmpty);
    });
  });

  group('合并：文件里有的新增或更新，本机独有的连同凭据留着', () {
    final merged = planVaultImport(fileVault(), localVault())
        .result(VaultImportMode.merge);

    test('主机、私钥、代理、片段都在，文件里的排前面', () {
      expect(merged.hosts.map((h) => h.id), ['shared', 'moved', 'new', 'mine']);
      expect(merged.keys.map((k) => k.id), ['k-shared', 'k-new', 'k-mine']);
      expect(merged.proxyProfiles.map((p) => p.id), ['p-shared', 'p-mine']);
      expect(merged.snippets.map((s) => s.id), ['s-mine']);
      expect(merged.customGroups, ['staging', 'prod']);
    });

    test('凭据：同一登录目标沿用，改了地址的不沿用，本机独有的原样保留', () {
      expect(byId(merged, 'shared').password, 'PW-SHARED');
      expect(byId(merged, 'moved').password, isNull);
      expect(byId(merged, 'moved').hostname, 'db2.example.com');
      expect(byId(merged, 'mine').password, 'PW-MINE');
      final keys = {for (final k in merged.keys) k.id: k.privateKey};
      expect(
          keys, {'k-shared': 'KEY-SHARED', 'k-new': '', 'k-mine': 'KEY-MINE'});
      final office = merged.proxyProfiles.first.data['config'] as Map;
      expect(office['password'], 'PROXY-PW');
    });

    test('受信指纹：同一台主机两边不一样时保留本机核对过的，文件独有的加进来', () {
      final known = (merged.extras['knownHosts'] as List).cast<Map>();
      expect(known.map((e) => e['fingerprint']),
          ['SHA256:local-verified', 'SHA256:cache']);
    });

    test('extras 里的集合按 ID 合并；其他字段文件有的用文件的，文件没有的保留本机的', () {
      final notes = (merged.extras['notes'] as List).cast<Map>();
      expect(notes.map((e) => e['id']), ['n-file', 'n-mine']);
      expect(merged.extras['x-local-only'], {'keep': false});
      expect(merged.extras['x-file-only'], 1);
    });

    test('没有 ID 的条目不会因为合并而重复', () {
      final withPlain = VaultData.fromJson({
        ...localVault().toJson(),
        'notes': [
          {'title': 'plain'},
        ],
      });
      final file = VaultData.fromJson({
        ...fileVault().toJson(),
        'notes': [
          {'title': 'plain'},
        ],
      });
      final result =
          planVaultImport(file, withPlain).result(VaultImportMode.merge);
      expect(result.extras['notes'], [
        {'title': 'plain'},
      ]);
    });
  });

  group('替换：保险库变成文件的内容', () {
    final replaced = planVaultImport(fileVault(), localVault())
        .result(VaultImportMode.replace);

    test('本机独有的条目没了，文件里的沿用本机凭据的规则不变', () {
      expect(replaced.hosts.map((h) => h.id), ['shared', 'moved', 'new']);
      expect(replaced.keys.map((k) => k.id), ['k-shared', 'k-new']);
      expect(replaced.proxyProfiles.map((p) => p.id), ['p-shared']);
      expect(byId(replaced, 'shared').password, 'PW-SHARED');
      expect(byId(replaced, 'moved').password, isNull);
      expect(replaced.extras.containsKey('notes'), isTrue);
      expect(replaced.extras['x-file-only'], 1);
    });
  });

  group('写入：和主机写入排队，确认期间本机变了就不写', () {
    const secureStorage =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    late VaultController vault;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorage, (call) async => null);
      SharedPreferences.setMockInitialValues({});
      vault = VaultController(await VaultRepository.open());
      await vault.ready();
      await vault.replace(localVault());
    });
    tearDown(() => vault.dispose());

    test('合并导入后本机独有的主机还在', () async {
      final shown = planVaultImport(fileVault(), await vault.ready());
      final used = await vault.importVault(shown, VaultImportMode.merge);
      expect(used.localOnlyHosts.map((h) => h.id), ['mine']);
      expect((await vault.ready()).hosts.map((h) => h.id),
          ['shared', 'moved', 'new', 'mine']);
    });

    test('确认框开着时本机新加了主机：拒绝写入，保险库不变', () async {
      final shown = planVaultImport(fileVault(), await vault.ready());
      await vault.upsertHost(HostProfile(host('added-meanwhile')));
      await expectLater(
        vault.importVault(shown, VaultImportMode.replace),
        throwsA(isA<VaultChangedDuringImport>()),
      );
      expect((await vault.ready()).hosts.map((h) => h.id),
          ['shared', 'moved', 'mine', 'added-meanwhile']);
    });

    test('导入和连接回写同时到达：排队执行，回写不被导入冲掉', () async {
      final shown = planVaultImport(fileVault(), await vault.ready());
      final mine = byId(await vault.ready(), 'mine');
      await Future.wait([
        vault.markConnected(mine),
        vault.importVault(shown, VaultImportMode.merge),
      ]);
      expect(byId(await vault.ready(), 'mine').lastConnectedAt, isNot(0));
    });
  });

  group('确认框', () {
    Future<VaultImportMode?> pick(
      WidgetTester tester,
      VaultImportPlan plan,
      Key? button,
    ) async {
      VaultImportMode? picked;
      var closed = false;
      // 先清掉上一次的组件树：同类型的 MaterialApp 会被复用，上一次开着的确认框还在。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await confirmVaultImport(context, plan);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (button == null) return null;
      await tester.tap(find.byKey(button));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      return picked;
    }

    final plan = planVaultImport(fileVault(), localVault());

    testWidgets('有本机独有条目：点名列出，替换不是默认按钮，三种选择各自返回', (tester) async {
      await pick(tester, plan, null);
      expect(find.textContaining('文件里有 3 台主机'), findsOneWidget);
      expect(find.textContaining('hop'), findsOneWidget);
      expect(find.textContaining('old'), findsOneWidget);
      expect(find.textContaining('home'), findsOneWidget);
      expect(find.textContaining('uptime'), findsOneWidget);
      expect(find.text('db'), findsOneWidget); // 凭据不沿用
      expect(find.text('ci'), findsOneWidget); // 私钥要重新导入
      expect(find.widgetWithText(FilledButton, '合并'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '替换'), findsOneWidget);

      expect(await pick(tester, plan, const ValueKey('vault-import-merge')),
          VaultImportMode.merge);
      expect(await pick(tester, plan, const ValueKey('vault-import-replace')),
          VaultImportMode.replace);
      expect(await pick(tester, plan, const ValueKey('vault-import-cancel')),
          isNull);
    });

    testWidgets('没有本机独有条目：只有取消和导入，没有替换', (tester) async {
      final same = planVaultImport(localVault(), localVault());
      await pick(tester, same, null);
      expect(find.widgetWithText(FilledButton, '导入'), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-import-replace')), findsNothing);
    });

    testWidgets('英文界面：带数字的句子整句翻译，主机名原样显示', (tester) async {
      NetcattyLocalizations.use('en');
      addTearDown(() => NetcattyLocalizations.use('zh'));
      await pick(tester, plan, null);
      expect(
        find.text('The file has 3 hosts: 1 will be added and 2 existing ones '
            'will be updated from the file.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Merge'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Replace'), findsOneWidget);
      expect(find.text('db'), findsOneWidget);
      expect(
        NetcattyLocalizations.text('导入完成（合并）：新增主机 1 台，更新主机 2 台，本机独有的主机保留：1'),
        'Imported (merge): hosts added 1, hosts updated 2, local-only hosts kept 1',
      );
      expect(
        NetcattyLocalizations.text('导入失败：${const VaultChangedDuringImport()}'),
        'Import failed: The vault on this device changed while you were '
        'confirming; nothing was imported. Choose the file again.',
      );
    });
  });
}
