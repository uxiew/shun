// X12 设备验证：`xwshun.mosh` 只认 Mosh 插件现在的证书（所有者 10-07 决定）。真 App 页面、真插件桥、真安装包。
//
// 这不是 CI 测试。要先装两个包（都在本 worktree 里编出来）：
//   adb -s emulator-5580 install -r plugins/out/echo-fakemosh.apk                          # 别的密钥签、自称 xwshun.mosh
//   adb -s emulator-5580 install -r plugins/mosh/build/outputs/apk/release/mosh-release.apk  # 真 Mosh 插件
//   flutter test integration_test/x12_mosh_binding_test.dart -d emulator-5580
// 输出以 "X12 " 开头的行作为证据。只做到「连接测试」（握手），不开 Mosh 会话，不需要 Mosh 测试环境。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:netcatty_mobile/app.dart';
import 'package:netcatty_mobile/application/plugin_discovery.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/screens/plugins_screen.dart';

const fakePackage = 'example.xwshun.fixture.fakemosh';
const moshPackage = 'top.xdwa.xwshun.mosh';

void report(String key, Object? value) => debugPrint('X12 $key=$value');

Future<void> settle(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('X12 xwshun.mosh 只认登记的证书', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const NetcattyApp(),
    ));
    await settle(tester, 1500);
    final discovery = await container.read(pluginDiscoveryProvider.future);
    await discovery.start();
    PluginEntry entry(String package) => container
        .read(pluginRegistryProvider)
        .singleWhere((e) => e.packageName == package);

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await settle(tester, 600);
    }

    String texts() => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .where((t) => t.trim().isNotEmpty)
        .join(' | ');

    for (final package in [fakePackage, moshPackage]) {
      final e = entry(package);
      report('entry.$package',
          'pluginId=${e.descriptor?.pluginId} status=${e.status.name} signer=${e.signerDigests} reason=${e.reason}');
    }

    final navigator = Navigator.of(tester.element(find.byType(Scaffold).first));
    unawaited(navigator
        .push(MaterialPageRoute<void>(builder: (_) => const PluginsScreen())));
    await settle(tester, 1500);

    // 冒充者：已拒绝，详情页没有批准按钮。
    await tap(find.byKey(const ValueKey('plugin-entry-$fakePackage')));
    report('fake.detail', texts());
    report('fake.approveButton',
        find.byKey(const ValueKey('plugin-approve')).evaluate().length);
    report('fake.checkButton',
        find.byKey(const ValueKey('plugin-check')).evaluate().length);
    expect(entry(fakePackage).status, PluginStatus.rejected);
    expect(find.byKey(const ValueKey('plugin-approve')), findsNothing);
    navigator.pop();
    await settle(tester);

    // 真 Mosh：待批准 → 批准 → 连接测试。
    await tap(find.byKey(const ValueKey('plugin-entry-$moshPackage')));
    report('mosh.before', entry(moshPackage).status.name);
    await tap(find.byKey(const ValueKey('plugin-approve')));
    await tap(find.byKey(const ValueKey('plugin-approve-confirm')));
    await settle(tester, 1500);
    report('mosh.afterApprove', entry(moshPackage).status.name);
    await tap(find.byKey(const ValueKey('plugin-check')));
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    String result() => tester
        .widget<Text>(find.descendant(
            of: find.byKey(const ValueKey('plugin-check-result')),
            matching: find.byType(Text)))
        .data!;
    while (
        find.byKey(const ValueKey('plugin-check-result')).evaluate().isEmpty ||
            result().contains('正在连接')) {
      if (DateTime.now().isAfter(deadline)) fail('等连接测试结果超时');
      await settle(tester, 200);
    }
    report('mosh.check', result());
    report('fake.statusAfter', entry(fakePackage).status.name);
    expect(entry(moshPackage).status, PluginStatus.ready);
    expect(entry(fakePackage).status, PluginStatus.rejected);
    await discovery.disconnect(moshPackage);
    navigator.pop();
    await settle(tester);
  });
}
