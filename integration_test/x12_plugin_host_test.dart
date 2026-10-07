// X12 设备验证：用户从主机列表连第三方终端插件（所有者 10-07 决定）。真 App 页面、真插件桥、真插件（样例 Hello 终端）。
//
// 这不是 CI 测试。要先：
//   adb -s emulator-5580 install -r plugins/example/app/build/outputs/apk/release/app-release.apk   # 样例，信任这台宿主的证书
//   flutter test integration_test/x12_plugin_host_test.dart -d emulator-5580
// 测试打出 "X12 uninstall.READY" 后，在电脑上：adb -s emulator-5580 uninstall example.xwshun.hello
// 另开一个终端预授权通知（每次 flutter test 都重装 App，一连上就为前台保活服务申请通知，系统框会挡住界面）：
//   until adb -s emulator-5580 shell pm grant top.xdwa.xwshun android.permission.POST_NOTIFICATIONS 2>/dev/null; do sleep 0.3; done
// 输出以 "X12 " 开头的行作为证据。
//
// 走的路：主机编辑器（选「插件」、选插件、保存）→ 主机列表点它连接 → 欢迎语、命令回显、转屏改尺寸 →
// 标签开着时到插件页点「连接测试」，标签不受影响 → 关标签（确认框写清楚）→ 插件停用后点条目 → 插件卸载后点条目。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:netcatty_mobile/app.dart';
import 'package:netcatty_mobile/application/home_navigation.dart';
import 'package:netcatty_mobile/application/plugin_discovery.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/application/plugin_terminal.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/presentation/screens/plugins_screen.dart';
import 'package:plugin_api/plugin_api.dart' show SessionPhase;

const helloPackage = 'example.xwshun.hello';
const hostLabel = 'x12-notes';

void report(String key, Object? value) => debugPrint('X12 $key=$value');

Future<void> waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  String what = '条件',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> settle(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('X12 从主机列表连第三方终端插件', (tester) async {
    addTearDown(() => SystemChrome.setPreferredOrientations(const []));
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const NetcattyApp(),
    ));
    await settle(tester, 1500);
    final discovery = await container.read(pluginDiscoveryProvider.future);
    await discovery.start();
    PluginEntry hello() => container
        .read(pluginRegistryProvider)
        .singleWhere((e) => e.packageName == helloPackage);
    if (hello().status == PluginStatus.needsApproval) {
      await discovery.approve(hello());
    }
    report('plugin', '${hello().status.name} signer=${hello().signerDigests}');

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await settle(tester, 600);
    }

    String texts() => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join('\n');

    // ---- 1. 主机编辑器：选「插件」、选插件、保存 ----
    container.read(homeTabProvider.notifier).state = 0;
    await settle(tester);
    await tap(find.text('添加主机').last);
    await tap(find.text('插件'));
    report('editor.hostnameField',
        find.widgetWithText(TextFormField, '主机名 / IP').evaluate().length);
    await tester.enterText(find.widgetWithText(TextFormField, '名称'), hostLabel);
    await tap(find.byKey(const ValueKey('plugin-picker')));
    await tap(find.textContaining('Hello 终端（样例）').last);
    report('editor.note',
        find.byKey(const ValueKey('plugin-network-note')).evaluate().length);
    await tap(find.text('保存'));
    await settle(tester, 1500);
    report('vault.line',
        texts().split('\n').where((t) => t.startsWith('插件 ')).join(' / '));

    // ---- 2. 主机列表点它连接 ----
    final sw = Stopwatch()..start();
    await tap(find.text(hostLabel).first);
    await tap(find.widgetWithText(FilledButton, '连接'));
    await waitFor(tester,
        () => controller.state.sessions.any((s) => s.host.label == hostLabel),
        what: '插件标签');
    final tab =
        controller.state.sessions.singleWhere((s) => s.host.label == hostLabel);
    final link = tab.plugin! as PluginTerminalProvider;
    final terminal = tab.terminal;
    await waitFor(tester, () => terminal.allText().contains('hello>'),
        what: '欢迎语');
    report('connect.ms', sw.elapsedMilliseconds);
    report(
        'tab',
        'protocol=${link.protocol} detail=${link.detail} isSsh=${tab.isSsh} '
            'engine=${terminal.engine} handle=${link.session.handle}');
    report('tab.label',
        texts().split('\n').where((t) => t.contains(hostLabel)).join(' / '));
    report(
        'screen.banner',
        terminal
            .allText()
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .take(3)
            .join(' / '));

    Future<void> type(String text) async {
      controller.typeInto(tab.id, text);
      await tester.pump();
    }

    await type('help\r');
    await waitFor(tester, () => terminal.allText().contains('插件这边结束会话'),
        what: 'help 输出');
    await type('color\r');
    await waitFor(tester, () => terminal.allText().contains('反显'),
        what: 'color 输出');

    Future<(int, int)> reportedSize(String tag) async {
      await type('clear\r');
      await settle(tester, 300);
      await type('size\r');
      await waitFor(tester, () => terminal.allText().contains('终端大小：'),
          what: 'size 输出');
      final line =
          terminal.allText().split('\n').lastWhere((l) => l.contains('终端大小：'));
      final m = RegExp(r'(\d+) 列 × (\d+) 行').firstMatch(line)!;
      final size = (int.parse(m.group(1)!), int.parse(m.group(2)!));
      report('size.$tag',
          'plugin=$size engine=${(terminal as TerminalSessionAdapterBase).sentSize}');
      return size;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester, 1500);
    final portrait = await reportedSize('portrait');
    await SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.landscapeLeft]);
    await waitFor(tester, () {
      final s = tester.view.physicalSize;
      return s.width > s.height;
    }, what: '转横屏');
    await settle(tester, 2000);
    final landscape = await reportedSize('landscape');
    expect(landscape, (terminal as TerminalSessionAdapterBase).sentSize);
    expect(landscape, isNot(portrait));
    await SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.portraitUp]);
    await waitFor(tester, () {
      final s = tester.view.physicalSize;
      return s.width < s.height;
    }, what: '转竖屏');
    await settle(tester, 1500);

    // ---- 3. 标签开着时到插件页点「连接测试」：标签不受影响 ----
    final navigator = Navigator.of(tester.element(find.byType(Scaffold).first));
    unawaited(navigator
        .push(MaterialPageRoute<void>(builder: (_) => const PluginsScreen())));
    await settle(tester, 1500);
    await tap(find.byKey(const ValueKey('plugin-entry-$helloPackage')));
    await tap(find.byKey(const ValueKey('plugin-check')));
    await waitFor(
        tester,
        () => find
            .byKey(const ValueKey('plugin-check-result'))
            .evaluate()
            .isNotEmpty,
        what: '连接测试结果');
    report(
        'check',
        tester
            .widget<Text>(find.descendant(
                of: find.byKey(const ValueKey('plugin-check-result')),
                matching: find.byType(Text)))
            .data);
    report('check.liveNote',
        find.byKey(const ValueKey('plugin-live-sessions')).evaluate().length);
    navigator.pop();
    await settle(tester, 600);
    navigator.pop();
    await settle(tester, 2500);
    await type('info\r');
    await waitFor(tester, () => terminal.allText().contains('代次'),
        what: 'info 输出');
    report(
        'afterCheck',
        'phase=${link.session.phase} sameTab=${controller.state.sessions.contains(tab)} '
            'sameSession=${identical((tab.plugin! as PluginTerminalProvider).session, link.session)} '
            'writes=${link.session.writeCount} inputs=${link.inputEvents}');
    expect(link.session.phase, SessionPhase.active);
    expect(link.inputEvents, link.session.writeCount, reason: '每次输入只写一次');

    // ---- 4. 关标签：确认框写清楚 ----
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester);
    final chip = find.ancestor(
        of: find.textContaining('$hostLabel · Hello 终端（样例）'),
        matching: find.byType(InputChip));
    report('chip', chip.evaluate().length);
    tester.widget<InputChip>(chip.first).onDeleted!();
    await settle(tester, 800);
    report('closeDialog',
        texts().split('\n').where((t) => t.contains('插件')).join(' / '));
    await tap(find.text('断开并关闭'));
    await waitFor(tester, () => controller.state.sessions.isEmpty,
        what: '标签关掉');
    await settle(tester, 2500);
    report('closed',
        'phase=${link.session.phase} stopConfirmed=${link.session.stopConfirmed}');

    Future<String> connectFails() async {
      container.read(homeTabProvider.notifier).state = 0;
      await settle(tester);
      final line =
          texts().split('\n').where((t) => t.startsWith('插件 ')).join(' / ');
      await tap(find.text(hostLabel).first);
      await tap(find.widgetWithText(FilledButton, '连接'));
      await waitFor(tester,
          () => controller.state.pendingConnections.any((p) => p.error != null),
          what: '连接失败');
      final pending = controller.state.pendingConnections.single;
      final error = '${pending.error}';
      controller.dismissPending(pending.id);
      await settle(tester);
      return '$line | $error';
    }

    // ---- 5. 插件停用后点条目 ----
    await discovery.disable(hello());
    await settle(tester);
    report('disabled', await connectFails());
    await discovery.enable(hello());
    await settle(tester);

    // ---- 6. 插件卸载后点条目 ----
    report('uninstall.READY', 'adb -s emulator-5580 uninstall $helloPackage');
    // 包事件会触发重新发现；保险起见每秒也主动发现一次。
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (!container.read(pluginRegistryProvider).any((e) =>
        e.packageName == helloPackage && e.status == PluginStatus.missing)) {
      if (DateTime.now().isAfter(deadline)) fail('等待样例被卸载超时');
      await discovery.refresh();
      await settle(tester, 1000);
    }
    report('uninstalled', await connectFails());
  }, timeout: const Timeout(Duration(minutes: 6)));
}
