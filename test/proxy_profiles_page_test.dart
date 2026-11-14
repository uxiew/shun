import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/proxy_profiles_page.dart';
import 'package:shun/presentation/widgets/connection_route_editor.dart';
import 'support/prism_test_host.dart';
import 'support/route_editor_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VaultRepository repository;
  late ProviderContainer container;
  final secrets = <String, String>{};
  HostProfile host(String id, {Map<String, dynamic> extra = const {}}) =>
      HostProfile({
        ...HostProfile.create(
                id: id, label: id, hostname: '$id.example', username: 'ops')
            .data,
        ...extra,
      });
  final config = {
    'type': 'socks5',
    'host': 'proxy.example',
    'port': 1080,
    'password': ' literal secret ',
    'desktop-extra': {'preserve': true}
  };
  final profile = ProxyProfile({
    'id': 'p',
    'label': 'Office proxy',
    'config': config,
    'unknown': 'preserve'
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secrets[key];
        case 'write':
          secrets[key!] = args['value'] as String;
          return null;
        case 'delete':
          secrets.remove(key);
          return null;
        default:
          return null;
      }
    });
    repository = await VaultRepository.open();
    await repository.saveVault(VaultData(hosts: [
      host('a', extra: {'proxyProfileId': 'p'}),
      host('b', extra: {'proxyProfileId': 'p'}),
      for (var i = 1; i <= 4; i++) host('edge$i'),
    ], keys: [], snippets: [], customGroups: [], proxyProfiles: [
      profile
    ]));
  });
  tearDown(() {
    container.dispose();
    ShunLocalizations.use('zh-CN');
  });

  Future<void> open(WidgetTester tester, Widget page,
      {Size size = const Size(900, 4000)}) async {
    container = ProviderContainer(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)]);
    await container.read(vaultControllerProvider.notifier).ready();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            localizationsDelegates: prismTestDelegates,
            builder: prismTestBuilder,
            home: page)));
    await tester.pumpAndSettle();
  }

  testWidgets('edit saved proxy, preserve unknown fields and literal password',
      (tester) async {
    await open(tester, const ProxyProfilesPage());
    await tapRoute(tester, find.byKey(const ValueKey('proxy-edit-p')));
    await tapRoute(tester, find.byType(DropdownButtonFormField<ProxyType>));
    await tapRoute(tester, find.text('HTTP').last);
    await tester.enterText(
        find.byKey(const ValueKey('proxy-host')), ' updated.example ');
    await tapRoute(tester, find.byKey(const ValueKey('proxy-save')));
    final saved = (await repository.loadVault()).proxyProfiles.single;
    expect(saved.id, 'p');
    expect(saved.config!.host, 'updated.example');
    expect(saved.config!.type, ProxyType.http);
    expect(saved.config!.password, ' literal secret ');
    expect(saved.data['unknown'], 'preserve');
    expect(saved.data['config']['desktop-extra'], {'preserve': true});
    expect(find.text('updated.example:1080'), findsOneWidget);
  });

  testWidgets(
      'delete lists affected hosts, cancellation is inert, confirm keeps references',
      (tester) async {
    await open(tester, const ProxyProfilesPage());
    await tapRoute(tester, find.byKey(const ValueKey('proxy-delete-p')));
    expect(find.textContaining('这些主机在用它'), findsOneWidget);
    expect(find.text('没有主机引用此代理。'), findsNothing);
    expect(find.text('a · ops@a.example:22'), findsOneWidget);
    expect(find.text('b · ops@b.example:22'), findsOneWidget);
    await tapRoute(tester, find.text('取消'));
    expect((await repository.loadVault()).proxyProfiles.length, 1);
    await tapRoute(tester, find.byKey(const ValueKey('proxy-delete-p')));
    await tapRoute(tester, find.byKey(const ValueKey('proxy-delete-confirm')));
    final vault = await repository.loadVault();
    expect(vault.proxyProfiles, isEmpty);
    expect(vault.hosts.first.proxyProfileId, 'p');
  });

  testWidgets('没有主机在用时，删除确认框只写这一句，不再先说「以下主机引用此代理」', (tester) async {
    await repository.saveVault(VaultData(
        hosts: [host('edge1')],
        keys: [],
        snippets: [],
        customGroups: [],
        proxyProfiles: [profile]));
    await open(tester, const ProxyProfilesPage());
    await tapRoute(tester, find.byKey(const ValueKey('proxy-delete-p')));
    expect(find.text('没有主机引用此代理。'), findsOneWidget);
    // 旧版这里还有一句「以下主机引用此代理……」，两句都带「引用此代理」。
    expect(find.textContaining('引用此代理'), findsOneWidget);
    expect(find.textContaining('这些主机在用它'), findsNothing);
  });

  testWidgets(
      'changed references during delete confirmation require fresh confirmation',
      (tester) async {
    await open(tester, const ProxyProfilesPage());
    await tapRoute(tester, find.byKey(const ValueKey('proxy-delete-p')));
    await container
        .read(vaultControllerProvider.notifier)
        .upsertHost(host('new', extra: {'proxyProfileId': 'p'}));
    await tapRoute(tester, find.byKey(const ValueKey('proxy-delete-confirm')));
    expect((await repository.loadVault()).proxyProfiles.length, 1);
    expect(find.text('代理或引用主机已变化，请重新打开后再操作。'), findsOneWidget);
  });

  testWidgets(
      'inline conversion requires save; cancelling host leaves original host unchanged',
      (tester) async {
    final original = host('inline', extra: {'proxyConfig': config});
    final before = await repository.loadVault();
    await repository
        .saveVault(before.copyWith(hosts: [...before.hosts, original]));
    await open(tester, HostEditor(host: original));
    await openRouteEditor(tester);
    await tapRoute(tester, find.byKey(const ValueKey('route-save-inline')));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect((await repository.loadVault()).proxyProfiles.length, 1);
    await tapRoute(tester, find.byKey(const ValueKey('route-save-inline')));
    await tester.enterText(
        find.byKey(const ValueKey('proxy-label')), 'converted');
    await tapRoute(tester, find.byKey(const ValueKey('proxy-save')));
    final vault = await repository.loadVault();
    final saved =
        vault.proxyProfiles.singleWhere((p) => p.label == 'converted');
    expect(saved.config!.password, ' literal secret ');
    expect(saved.data['config']['desktop-extra'], {'preserve': true});
    expect(vault.hosts.singleWhere((h) => h.id == original.id).toJson(),
        original.toJson());
    final draft = tester
        .widget<ConnectionRouteEditor>(find.byType(ConnectionRouteEditor))
        .draft;
    final data = <String, dynamic>{};
    draft.writeTo(data);
    expect(data['proxyProfileId'], saved.id);
    expect(data.containsKey('proxyConfig'), isFalse);
  });

  testWidgets(
      'deleted selected proxy remains an invalid reference, never switches to direct',
      (tester) async {
    await open(
        tester, HostEditor(host: host('a', extra: {'proxyProfileId': 'p'})));
    await openRouteEditor(tester);
    await tapRoute(tester, find.text('代理管理'));
    await tapRoute(tester, find.byKey(const ValueKey('proxy-delete-p')));
    await tapRoute(tester, find.byKey(const ValueKey('proxy-delete-confirm')));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('找不到代理配置'), findsOneWidget);
    final draft = tester
        .widget<ConnectionRouteEditor>(find.byType(ConnectionRouteEditor))
        .draft;
    expect(draft.selectedProxyProfileId, 'p');
    expect(draft.usesProxy, isTrue);
    await tapRoute(tester, find.text('保存'));
    expect(find.byType(HostEditor), findsOneWidget);
  });

  testWidgets('jump order, removal and three-hop maximum in shared chain',
      (tester) async {
    await open(tester, HostEditor(host: host('target')));
    for (var i = 1; i <= 3; i++) {
      await addRouteJump(tester, 'edge$i');
    }
    final editor = tester
        .widget<ConnectionRouteEditor>(find.byType(ConnectionRouteEditor));
    expect(editor.draft.jumpHostIds, ['edge1', 'edge2', 'edge3']);
    expect(
        find.descendant(
            of: find.byType(ConnectionRouteEditor),
            matching: find.byType(DropdownButtonFormField<String>)),
        findsNothing);
    await tapRoute(tester, find.byKey(const ValueKey('jump-up-2')));
    expect(editor.draft.jumpHostIds, ['edge1', 'edge3', 'edge2']);
    await tapRoute(tester, find.byKey(const ValueKey('jump-down-0')));
    expect(editor.draft.jumpHostIds, ['edge3', 'edge1', 'edge2']);
    await tapRoute(tester, find.byKey(const ValueKey('jump-remove-1')));
    expect(editor.draft.jumpHostIds, ['edge3', 'edge2']);
    await addRouteJump(tester, 'edge4');
    expect(editor.draft.jumpHostIds, ['edge3', 'edge2', 'edge4']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('jump consent cancellation and a changed source are inert',
      (tester) async {
    final edge = host('consent-edge', extra: {'proxyProfileId': 'p'});
    await repository
        .saveVault((await repository.loadVault()).copyWith(hosts: [edge]));
    await open(tester, HostEditor(host: host('target')));
    await addRouteJump(tester, 'consent-edge');
    await tapRoute(tester, find.byKey(const ValueKey('route-confirm-jumps')));
    // R41 起编辑页底部栏也有「取消」：只点对话框里的。
    await tapRoute(
        tester,
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text('取消')));
    var draft = tester
        .widget<ConnectionRouteEditor>(find.byType(ConnectionRouteEditor))
        .draft;
    expect(draft.confirmation, isNull);
    await tapRoute(tester, find.byKey(const ValueKey('route-confirm-jumps')));
    await container
        .read(vaultControllerProvider.notifier)
        .upsertHost(HostProfile({...edge.data, 'hostname': 'changed.example'}));
    await tester.pumpAndSettle();
    await tapRoute(tester, find.byKey(const ValueKey('route-choice-proxy')));
    expect(find.text('跳板路线确认已失效，请重新确认。'), findsOneWidget);
    expect(draft.confirmation, isNull);
    expect(draft.usesProxy, isFalse);
    await tapRoute(tester, find.byKey(const ValueKey('route-confirm-jumps')));
    await tapRoute(tester, find.byKey(const ValueKey('route-choice-proxy')));
    expect(draft.confirmation, isNotNull);
    expect(draft.selectedProxyProfileId, 'p');
    await tapRoute(tester, find.byKey(const ValueKey('route-remove-proxy')));
    expect(draft.confirmation, isNull);
    expect(
        tester
            .widget<ConnectionRouteEditor>(find.byType(ConnectionRouteEditor))
            .plan,
        isNull);
  });

  testWidgets('360dp English management and proxy form fit with keyboard',
      (tester) async {
    ShunLocalizations.use('en');
    await open(tester, const ProxyProfilesPage(), size: const Size(360, 800));
    await tapRoute(tester, find.byKey(const ValueKey('proxy-edit-p')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('proxy-label')), 'Office renamed');
    await tapRoute(tester, find.byKey(const ValueKey('proxy-save')));
    expect((await repository.loadVault()).proxyProfiles.single.label,
        'Office renamed');
    expect(tester.takeException(), isNull);
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join();
    expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isFalse);
  });

  group('UIM10（R89）代理页', () {
    List<String> keysIn(WidgetTester tester) => [
          for (final element in find
              .descendant(
                  of: find.byType(ProxyProfilesPage),
                  matching:
                      find.byWidgetPredicate((w) => w.key is ValueKey<String>))
              .evaluate())
            (element.widget.key! as ValueKey<String>).value,
        ];

    testWidgets('迁移前代理页的入口一项不少、顺序不变', (tester) async {
      await open(tester, const ProxyProfilesPage());
      final keys = keysIn(tester);
      // HEAD 上同一份数据录到的顺序。
      const before = [
        'proxy-profile-p',
        'proxy-edit-p',
        'proxy-delete-p',
        'proxy-create',
      ];
      var at = 0;
      for (final key in keys) {
        if (at < before.length && before[at] == key) at++;
      }
      expect(at, before.length, reason: keys.join('\n'));
    });

    testWidgets('选择模式点行返回 id，不进编辑页', (tester) async {
      String? picked;
      await open(
          tester,
          Builder(
              builder: (context) => TextButton(
                  onPressed: () async =>
                      picked = await selectRouteProxy(context, null),
                  child: const Text('go'))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('proxy-profile-p')));
      await tester.pumpAndSettle();
      expect(picked, 'p');
      expect(find.byKey(const ValueKey('proxy-label')), findsNothing);
    });

    testWidgets('管理模式点行 = 点「编辑」（行为变化）；不改动已存的代理', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, const ProxyProfilesPage());
      expect(
          tester.getSemantics(find.bySemanticsLabel(RegExp('^Office proxy'))),
          isSemantics(
              isButton: true,
              hasEnabledState: true,
              isEnabled: true,
              hasTapAction: true));
      final before =
          (await repository.loadVault()).proxyProfiles.single.toJson();
      await tester.tap(find.byKey(const ValueKey('proxy-profile-p')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('proxy-label')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
          (await repository.loadVault()).proxyProfiles.single.toJson(), before);
      handle.dispose();
    });

    testWidgets('代理密码：key 在，切明文三个输入法开关仍全关', (tester) async {
      await open(tester, const ProxyProfilesPage());
      await tapRoute(tester, find.byKey(const ValueKey('proxy-edit-p')));
      expect(find.byKey(const ValueKey('proxy-username')), findsOneWidget);
      EditableText field() => tester.widget<EditableText>(find.descendant(
          of: find.byKey(const ValueKey('proxy-password')),
          matching: find.byType(EditableText)));
      for (final obscured in [true, false]) {
        expect(field().obscureText, obscured);
        expect(field().enableIMEPersonalizedLearning, isFalse);
        expect(field().enableSuggestions, isFalse);
        expect(field().autocorrect, isFalse);
        await tester.tap(find.descendant(
            of: find.byKey(const ValueKey('proxy-password')),
            matching: find.byType(IconButton)));
        await tester.pump();
      }
    });

    testWidgets('删除确认保留「不会自动改成直连」，取消不删', (tester) async {
      await open(tester, const ProxyProfilesPage());
      await tapRoute(tester, find.byKey(const ValueKey('proxy-delete-p')));
      expect(find.textContaining('不会自动改成直连'), findsOneWidget);
      await tapRoute(tester, find.byKey(const ValueKey('proxy-delete-cancel')));
      expect((await repository.loadVault()).proxyProfiles.length, 1);
    });
  });
}
