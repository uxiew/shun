// 手机连不到 tailnet 地址时的失败页（R77 / UXR06）：真 App、真连接失败、真的拉起另一个 App。
// 100.64.0.1 在模拟器上到不了，用来冒充手机没连 tailnet；这不是真的 Tailscale App，也没有真 tailnet。
// 只用工具跑：
//   SHUN_R39_AVD=shun-r39-a30 SHUN_R70_TARGET=integration_test/r77_open_tailscale_test.dart python3 tool/r70-device.py
// 没装时看到「没找到」，模拟器上装了同包名的空壳时被拉起，两种结果都打在 R70 RESULT 这行，由跑的人对着 logcat 核对。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';

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

  testWidgets('连不到 tailnet 地址：给「打开 Tailscale」，点了不重连', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)]);
    addTearDown(container.dispose);
    final controller = container.read(vaultControllerProvider.notifier);
    await controller.ready();
    await controller.replace(VaultData.fromJson({
      'hosts': [
        {
          'id': 'nas',
          'label': 'nas',
          'hostname': '100.64.0.1',
          'username': 'ops',
          'password': 'not-a-real-password',
          'port': 22,
          'sshTcpConnectTimeoutSeconds': 5,
          'protocol': 'ssh',
        },
      ],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'identities': const [],
      'proxyProfiles': const [],
    }));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester);
    await tester.tap(find.text('nas'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    final open = find.byKey(const ValueKey('tailscale-fix-open'));
    for (var i = 0; i < 100 && open.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      await binding.delayed(const Duration(milliseconds: 200));
    }
    expect(open, findsOneWidget, reason: '等了 40 秒没到失败页，或失败页没给按钮');
    await tester.ensureVisible(open);
    await shot(tester, '01-failure-page');

    await tester.tap(open);
    // 被拉起时这个 App 在后台，不出帧，pump 会一直等：只用真时间，回到前台再 pump。
    await binding.delayed(const Duration(seconds: 3));
    mark('SHOT 02-after-open');
    await binding.delayed(const Duration(milliseconds: 1500));
    mark('FRONT');
    await binding.delayed(const Duration(seconds: 2));
    await shot(tester, '03-back');
    mark(
        'RESULT notFound=${find.text('没找到 Tailscale App').evaluate().isNotEmpty}');
    expect(open, findsOneWidget, reason: '回来还停在失败页，没有自动重连');
  });
}
