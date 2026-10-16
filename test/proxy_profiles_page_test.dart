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
        container: container, child: MaterialApp(home: page)));
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
    await tapRoute(tester,
        find.descendant(of: find.byType(AlertDialog), matching: find.text('取消')));
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
}
