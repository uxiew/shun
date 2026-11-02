import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/port_forward_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/manage_screen.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/proxy_profile_editor.dart';

class _Forwards extends PortForwardController {
  _Forwards(List<ActivePortForward> forwards) {
    state = forwards;
  }
}

void main() {
  late ProviderContainer container;

  Future<void> open(
    WidgetTester tester, {
    bool empty = false,
  }) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'shun_vault_v1': jsonEncode({
        'hosts': empty
            ? const []
            : [
                {
                  'id': 'web',
                  'label': 'web-1',
                  'hostname': '192.0.2.10',
                  'username': 'ops',
                  'port': 22,
                  'protocol': 'ssh',
                  'group': 'prod',
                },
                {
                  'id': 'nologin',
                  'label': 'no-login',
                  'hostname': '198.51.100.1',
                  'username': '',
                  'port': 22,
                  'protocol': 'ssh',
                },
              ],
        'keys': empty
            ? const []
            : [
                {'id': 'k1', 'label': 'laptop-key', 'privateKey': 'x'},
              ],
        'identities': empty
            ? const []
            : [
                {'id': 'i1', 'label': 'deploy', 'username': 'deployer'},
              ],
        'snippets': const [],
        'customGroups': const [],
        'proxyProfiles': empty
            ? const []
            : [
                {
                  'id': 'p1',
                  'label': 'office-proxy',
                  'config': {
                    'type': 'socks5',
                    'host': 'proxy.example',
                    'port': 1080,
                  },
                },
              ],
      }),
    });
    final repository = await VaultRepository.open();
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      portForwardControllerProvider.overrideWith((ref) => _Forwards(empty
          ? const []
          : [
              ActivePortForward(
                id: 'f1',
                kind: ForwardKind.local,
                localPort: 8080,
                remoteHost: 'db.internal',
                remotePort: 5432,
                hostLabel: 'web-1',
                endedReason: '连接断了',
              ),
            ])),
    ]);
    addTearDown(container.dispose);
    await container.read(vaultControllerProvider.notifier).ready();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ManageScreen()),
    ));
    await tester.pumpAndSettle();
  }

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> tap(WidgetTester tester, String value) async {
    await tester.tap(key(value));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(key('manage-search'), text);
    await tester.pumpAndSettle();
  }

  const tabs = {
    'hosts': 'manage-host-web',
    'credentials': 'keychain-identity-i1',
    'proxies': 'proxy-profile-p1',
    'forwards': 'manage-forward-f1',
  };

  testWidgets('R72：一类一个 tab，切到哪个就只看到哪类', (tester) async {
    await open(tester);
    for (final entry in tabs.entries) {
      await tap(tester, 'manage-tab-${entry.key}');
      for (final item in tabs.values) {
        expect(key(item), item == entry.value ? findsOneWidget : findsNothing,
            reason: '${entry.key} 里的 $item');
      }
    }
  });

  testWidgets('一个搜索框搜四类：当前 tab 没有就跳到有的，tab 上写命中几条，大小写不敏感', (tester) async {
    await open(tester);
    for (final (text, shown) in [
      ('PROD', 'manage-host-web'), // 分组
      ('192.0.2', 'manage-host-web'), // 地址
      ('deployer', 'keychain-identity-i1'), // 凭据用户名
      ('laptop-key', 'keychain-key-k1'),
      ('proxy.example', 'proxy-profile-p1'),
      ('db.internal', 'manage-forward-f1'),
    ]) {
      await search(tester, text);
      expect(key(shown), findsOneWidget, reason: text);
    }
    await search(tester, 'deployer');
    expect(find.text('主机 0'), findsOneWidget);
    expect(find.text('凭据 1'), findsOneWidget);
    expect(key('keychain-key-k1'), findsNothing, reason: '没命中的不列');

    await search(tester, '');
    expect(find.text('主机'), findsOneWidget, reason: '不搜就不写数字');
  });

  testWidgets('搜不到就说没有匹配，四个 tab 都是', (tester) async {
    await open(tester);
    await search(tester, 'nothing-like-this');
    for (final name in tabs.keys) {
      await tap(tester, 'manage-tab-$name');
      expect(find.text('没有匹配的项目'), findsOneWidget, reason: name);
    }
  });

  testWidgets('什么都没有时也能就地新建：＋ 跟着 tab 走', (tester) async {
    await open(tester, empty: true);
    expect(find.text('还没有主机'), findsOneWidget);
    await tap(tester, 'manage-add');
    expect(find.byType(HostEditor), findsOneWidget);
    expect(key('delete-host-from-editor'), findsNothing);
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    await tap(tester, 'manage-tab-credentials');
    await tap(tester, 'manage-add');
    await tap(tester, 'keychain-add-identity');
    expect(find.widgetWithText(AlertDialog, '新建凭据'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    await tap(tester, 'manage-tab-proxies');
    expect(find.text('还没有代理'), findsOneWidget);
    await tap(tester, 'manage-add');
    expect(find.byType(ProxyProfileEditor), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tap(tester, 'manage-tab-forwards');
    expect(find.text('连上主机后才能开转发'), findsOneWidget);
    expect(key('manage-add'), findsNothing, reason: '没连接开不了转发，不摆按钮');
  });

  testWidgets('主机：点行编辑，编辑器里能删，删前要问', (tester) async {
    await open(tester);
    await tap(tester, 'manage-host-web');
    expect(find.byType(HostEditor), findsOneWidget);
    await tester.ensureVisible(key('delete-host-from-editor'));
    await tester.pumpAndSettle();
    await tap(tester, 'delete-host-from-editor');
    expect(find.text('删除服务器？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(key('manage-host-web'), findsNothing);
    expect(
      container.read(vaultControllerProvider).data!.hosts.map((h) => h.id),
      isNot(contains('web')),
    );
  });

  testWidgets('主机：行上有连接，没配好登录的先问', (tester) async {
    await open(tester);
    expect(key('manage-connect-web'), findsOneWidget);
    await tap(tester, 'manage-connect-nologin');
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('凭据和代理：在 tab 里就能改能删', (tester) async {
    await open(tester);
    await tap(tester, 'manage-tab-credentials');
    await tap(tester, 'keychain-identity-i1');
    expect(find.widgetWithText(AlertDialog, '编辑凭据'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    await tap(tester, 'keychain-delete-identity-i1');
    await tap(tester, 'keychain-confirm-delete-identity');
    expect(key('keychain-identity-i1'), findsNothing);

    await tap(tester, 'manage-tab-proxies');
    await tap(tester, 'proxy-edit-p1');
    expect(find.byType(ProxyProfileEditor), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tap(tester, 'proxy-delete-p1');
    await tap(tester, 'proxy-delete-confirm');
    expect(key('proxy-profile-p1'), findsNothing);
  });

  testWidgets('连接没了的转发只能看，点了不打开面板', (tester) async {
    await open(tester);
    await tap(tester, 'manage-tab-forwards');
    expect(tester.widget<ListTile>(key('manage-forward-f1')).onTap, isNull);
    expect(find.textContaining('连接断了'), findsOneWidget);
  });
}
