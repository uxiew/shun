// 新建连接走查（F39、R73）：真 App 页面、中文字体、真屏幕尺寸，看首屏放得下什么。
// 不连网、不连真机上的数据。只用工具跑：
//   SHUN_R39_AVD=shun-r39-a30 SHUN_R70_TARGET=integration_test/r73_editor_walkthrough_test.dart python3 tool/r70-device.py
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/home_shell.dart';
import 'package:shun/presentation/widgets/host_editor.dart';

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
    // 给脚本留出截屏时间：它读到标记才动手。
    await binding.delayed(const Duration(milliseconds: 1200));
    await tester.pump();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await settle(tester);
    await tester.tap(finder);
    await settle(tester);
  }

  testWidgets('新建连接：首屏、类型面板、高级', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)]);
    addTearDown(container.dispose);
    final controller = container.read(vaultControllerProvider.notifier);
    final vault = await controller.ready();
    await controller.replace(VaultData.fromJson({
      ...vault.toJson(),
      'hosts': [
        {
          'id': 'old',
          'label': '公司跳板',
          'hostname': '10.0.0.8',
          'port': 22,
          'username': 'ops',
          'protocol': 'ssh',
          'group': 'prod',
          'startupCommand': 'uptime',
          'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
        },
      ],
    }));
    // 带密码框的页面默认防截屏，adb screencap 得到 0 字节。只开在这个用完就清数据的测试 App 上。
    await container
        .read(settingsControllerProvider.notifier)
        .updateAllowSensitiveScreenshots(true);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    for (var i = 0; i < 600 && find.byType(HomeShell).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settle(tester);

    await tester.tap(find.byTooltip('添加连接').first);
    await settle(tester);
    await binding.delayed(const Duration(milliseconds: 500));
    await shot(tester, '01-new');
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    debugPrint('R73 screen=$screen '
        'advanced=${tester.getRect(find.byKey(const ValueKey('advanced-all')))} '
        'save=${tester.getRect(find.byKey(const ValueKey('host-editor-save')))}');

    await tapKey(tester, 'host-protocol');
    await shot(tester, '02-type-sheet');
    await tapKey(tester, 'connection-type-Mosh');
    await shot(tester, '03-mosh');
    await tapKey(tester, 'advanced-all');
    await shot(tester, '04-advanced');
    await tapKey(tester, 'advanced-route');
    await shot(tester, '05-route');
    // 滚下去以后顶上那行已经被列表回收了。
    tester
        .state<ScrollableState>(find
            .descendant(
                of: find.byType(HostEditor), matching: find.byType(Scrollable))
            .first)
        .position
        .jumpTo(0);
    await settle(tester);
    await tapKey(tester, 'host-protocol');
    await tapKey(tester, 'connection-type-Telnet');
    await shot(tester, '06-telnet');
    await tester.tap(find.byIcon(Icons.close).first);
    await settle(tester);
    if (find
        .byKey(const ValueKey('host-editor-discard'))
        .evaluate()
        .isNotEmpty) {
      await tapKey(tester, 'host-editor-discard');
    }

    final context = tester.element(find.byType(HomeShell));
    final old = (await controller.ready()).hosts.single;
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => HostEditor(host: old)));
    await settle(tester);
    await shot(tester, '07-edit-summary');
    await tapKey(tester, 'advanced-all');
    await shot(tester, '08-edit-advanced');
    await tester.pumpWidget(const SizedBox());
  });
}
