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
import 'package:shun/presentation/widgets/keychain_sheet.dart';
import 'package:shun/presentation/widgets/proxy_profiles_page.dart';

class _Forwards extends PortForwardController {
  _Forwards(List<ActivePortForward> forwards) {
    state = forwards;
  }
}

void main() {
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
    final container = ProviderContainer(overrides: [
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

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(key('manage-search'), text);
    await tester.pumpAndSettle();
  }

  const all = [
    'manage-host-web',
    'manage-identity-i1',
    'manage-key-k1',
    'manage-proxy-p1',
    'manage-forward-f1',
  ];

  void expectOnly(String? shown) {
    for (final item in all) {
      expect(key(item), item == shown ? findsOneWidget : findsNothing,
          reason: '$item，应该只看到 $shown');
    }
  }

  testWidgets('不搜时四类都列出来', (tester) async {
    await open(tester);
    for (final item in all) {
      expect(key(item), findsOneWidget, reason: item);
    }
  });

  testWidgets('一个搜索框搜四类，大小写不敏感', (tester) async {
    await open(tester);
    for (final (text, shown) in [
      ('PROD', 'manage-host-web'), // 分组
      ('192.0.2', 'manage-host-web'), // 地址
      ('deployer', 'manage-identity-i1'), // 凭据用户名
      ('laptop-key', 'manage-key-k1'),
      ('proxy.example', 'manage-proxy-p1'),
      ('db.internal', 'manage-forward-f1'),
    ]) {
      await search(tester, text);
      expectOnly(shown);
    }
  });

  testWidgets('搜不到就说没有匹配，分组标题也收起来', (tester) async {
    await open(tester);
    expect(key('manage-open-credentials'), findsOneWidget);
    await search(tester, 'nothing-like-this');
    expectOnly(null);
    expect(find.text('没有匹配的项目'), findsOneWidget);
    expect(key('manage-open-credentials'), findsNothing);
  });

  testWidgets('什么都没有时每类说去哪加，凭据和代理还能进自己的页面', (tester) async {
    await open(tester, empty: true);
    expect(find.text('在「连接」页添加'), findsOneWidget);
    expect(find.text('还没有凭据'), findsOneWidget);
    expect(find.text('还没有代理'), findsOneWidget);
    expect(find.text('在终端或主机菜单里开'), findsOneWidget);
    await tester.tap(key('manage-open-credentials'));
    await tester.pumpAndSettle();
    expect(find.byType(KeychainSheet), findsOneWidget);
  });

  testWidgets('点开走各自原来的页面', (tester) async {
    await open(tester);
    await tester.tap(key('manage-identity-i1'));
    await tester.pumpAndSettle();
    expect(find.byType(KeychainSheet), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byType(KeychainSheet), matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();

    await tester.tap(key('manage-proxy-p1'));
    await tester.pumpAndSettle();
    expect(find.byType(ProxyProfilesPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(key('manage-host-web'));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsOneWidget);
  });

  testWidgets('连接没了的转发只能看，点了不打开面板', (tester) async {
    await open(tester);
    expect(tester.widget<ListTile>(key('manage-forward-f1')).onTap, isNull);
    expect(find.textContaining('连接断了'), findsOneWidget);
  });
}
