// 设置五组和管理页走查（F39、R79）：真 App、真 Android（UU、RustDesk、插件只在 Android 上有）。
// 不连网。只用工具跑：
//   SHUN_R39_AVD=shun-r39-a30 SHUN_R70_TARGET=integration_test/r79_settings_test.dart python3 tool/r70-device.py
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/manage_screen.dart';
import 'package:shun/presentation/screens/settings_screen.dart';

void mark(String line) => debugPrint('R70 $line');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    await binding.delayed(const Duration(milliseconds: 400));
    await tester.pump();
    mark('SHOT $name');
    await binding.delayed(const Duration(milliseconds: 1200));
    await tester.pump();
  }

  testWidgets('每个设置项都在该在的组里，手册路径走得通', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)]);
    addTearDown(container.dispose);
    final controller = container.read(vaultControllerProvider.notifier);
    await controller.ready();
    await controller.replace(VaultData.fromJson({
      'hosts': [
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
      'keys': [
        {'id': 'k1', 'label': 'laptop-key', 'privateKey': 'x'},
      ],
      'snippets': const [],
      'customGroups': const [],
      'identities': [
        {'id': 'i1', 'label': 'deploy', 'username': 'deployer', 'keyId': 'k1'},
      ],
      'proxyProfiles': [
        {
          'id': 'p1',
          'label': 'office-proxy',
          'config': {'type': 'socks5', 'host': 'proxy.example', 'port': 1080},
        },
      ],
    }));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester);
    container.read(homeTabProvider.notifier).state = 4;
    await settle(tester);

    final scrollable = find
        .descendant(
            of: find.byType(SettingsScreen), matching: find.byType(Scrollable))
        .first;

    // 改前清单在 evidence/R79.md。从上往下滑，顺序对才算在组里。
    const walk = <(String, List<String>)>[
      ('通用', ['界面主题', '自定义背景', 'SFTP 代码高亮']),
      ('终端', ['全屏程序里滑动翻页']),
      (
        '连接',
        [
          '管理',
          '代理管理',
          '凭据',
          'Tailscale',
          '日志',
        ]
      ),
      ('插件', ['UU 远程', 'RustDesk', '插件（实验）']),
      ('安全', ['应用锁', '可信主机密钥']),
      ('数据', ['云端备份', '备份到文件', '从文件恢复', '发到另一台手机', '从另一台手机接收']),
    ];
    var shots = 0;
    for (final (group, items) in walk) {
      for (final text in [group, ...items]) {
        final target = find.descendant(
            of: find.byType(SettingsScreen),
            matching: find.text(text),
            skipOffstage: false);
        await tester.scrollUntilVisible(target.first, 200,
            scrollable: scrollable, maxScrolls: 200);
        await settle(tester);
        mark('FOUND $group -> $text');
      }
      await shot(tester, '${(shots++).toString().padLeft(2, '0')}-$group');
    }

    // 管理页：从「设置 → 连接 → 管理」走进去，一类一个 tab，一个框搜四类。
    final manage = find.byKey(const ValueKey('settings-manage'));
    await tester.scrollUntilVisible(manage, -200,
        scrollable: scrollable, maxScrolls: 200);
    await settle(tester);
    await shot(tester, '09-连接开头');
    await tester.tap(manage);
    await binding.delayed(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.byType(ManageScreen), findsOneWidget);
    await shot(tester, '10-manage');
    for (final tab in ['credentials', 'proxies', 'forwards']) {
      await tester.tap(find.byKey(ValueKey('manage-tab-$tab')));
      await binding.delayed(const Duration(milliseconds: 500));
      await settle(tester);
      await shot(tester, '10-manage-$tab');
    }
    await tester.tap(find.byKey(const ValueKey('manage-tab-hosts')));
    await binding.delayed(const Duration(milliseconds: 500));
    await settle(tester);
    for (final (text, key) in [
      ('prod', 'manage-host-web'),
      ('deployer', 'keychain-identity-i1'),
      ('proxy.example', 'proxy-profile-p1'),
    ]) {
      await tester.enterText(find.byKey(const ValueKey('manage-search')), text);
      // 当前 tab 没有命中会自己跳过去，等它滑完。
      await binding.delayed(const Duration(milliseconds: 500));
      await settle(tester);
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: text);
      await shot(tester, '11-manage-$text');
    }
  });
}
