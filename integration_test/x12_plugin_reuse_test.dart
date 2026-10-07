// X12 设备验证：插件已有会话在跑时，插件页的「连接测试」「会话测试」不能把它断掉（X09 留下的坑）。
//
// 两段，都在真实 App 页面里、经真实的 Kotlin 插件桥：
//   mosh  开一个真 Mosh 标签（X09 的路：SSH 引导 → Mosh 插件走 UDP）→ 插件页进 Mosh 详情点「连接测试」→
//         进出一次会话测试页（Mosh 申请了临时凭据，只有说明、开不了）→ 回到 Mosh 标签敲一行：
//         远端照常收到，mosh-server 启动计数不变、还是那一个在跑，插件会话还是原来那个句柄和代次。
//   echo  另开一个 echo 会话（代替「别处在用的会话」）→ 进会话测试、开一个测试会话、发一行、离开 →
//         原来那个 echo 会话还活着、照常回显，连接没被断开。
//
// 这不是 CI 测试。要先（详见 docs/xwshun/README.md 第 2 节「Mosh」）：
//   (cd tool/mosh-fixture && ./up.sh)
//   adb -s emulator-5580 shell svc wifi disable          # 原因见本机手册第 3 节；测完一定 enable
//   adb -s emulator-5580 install -r plugins/mosh/build/outputs/apk/release/mosh-release.apk
//   adb -s emulator-5580 install -r plugins/out/echo-author.apk
//   flutter test integration_test/x12_plugin_reuse_test.dart -d emulator-5580 \
//     --dart-define=X09_MOSH="$(python3 tool/mosh-fixture/x08_config.py)"
// 输出以 "X12 " 开头的行作为证据。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:netcatty_mobile/application/mosh_session.dart';
import 'package:netcatty_mobile/application/plugin_discovery.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/application/plugin_sessions.dart';
import 'package:netcatty_mobile/presentation/screens/plugin_session_test_screen.dart';
import 'package:netcatty_mobile/presentation/screens/plugins_screen.dart';
import 'package:plugin_api/plugin_api.dart' show SessionPhase;

import 'mosh_session_test.dart'
    show Monitor, config, moshHost, settle, startApp, verifyFixture, waitFor;

const echoPackage = 'example.xwshun.fixture.echo';
const moshPackage = 'top.xdwa.xwshun.mosh';

void report(String key, Object? value) => debugPrint('X12 $key=$value');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = config.isEmpty ? '没给 X09_MOSH，见文件头' : false;

  testWidgets('X12 插件已有会话时，连接测试和会话测试不断开它', (tester) async {
    final monitor = await Monitor.open();
    addTearDown(monitor.close);
    // 不 pkill：测试环境可能还有别人的 mosh-server。下面只看本测试前后的差值。
    final running0 = await monitor.running();
    final (container, controller) = await startApp(tester);
    final manager = container.read(pluginSessionManagerProvider);
    final discovery = await container.read(pluginDiscoveryProvider.future);

    NavigatorState navigator() =>
        Navigator.of(tester.element(find.byType(Scaffold).first));

    Future<void> tapKey(String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.tap(find.byKey(ValueKey(key)));
      await settle(tester, 300);
    }

    String texts() => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .followedBy(tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((t) => t.data ?? ''))
        .join('\n');

    // ---- mosh：真 Mosh 标签开着，去插件页点连接测试、进出会话测试说明页 ----
    final starts0 = await monitor.starts();
    final connected = controller.connect(moshHost('x12-mosh'), verifyFixture);
    await waitFor(tester,
        () => controller.state.sessions.any((s) => s.host.id == 'x12-mosh'),
        timeout: const Duration(seconds: 40), what: 'Mosh 标签');
    expect(await connected, isTrue);
    final tab =
        controller.state.sessions.lastWhere((s) => s.host.id == 'x12-mosh');
    final link = tab.plugin! as MoshTerminalProvider;
    final session = link.session;
    await waitFor(tester, () => tab.terminal.allText().contains(r'$'),
        what: '远端提示符');
    controller.typeInto(tab.id, 'echo before-\$((6*7))\r');
    await waitFor(tester, () => tab.terminal.allText().contains('before-42'),
        what: 'before-42');
    final starts1 = await monitor.starts();
    report(
        'mosh.opened',
        'handle=${session.handle} generation=${session.generation} phase=${session.phase} '
            'starts=$starts0->$starts1 running=${await monitor.running()}');
    expect(starts1, starts0 + 1);

    unawaited(navigator()
        .push(MaterialPageRoute<void>(builder: (_) => const PluginsScreen())));
    await settle(tester, 1500);
    await tapKey('plugin-entry-$moshPackage');
    await tapKey('plugin-check');
    await waitFor(
        tester,
        () => find
            .byKey(const ValueKey('plugin-check-result'))
            .evaluate()
            .isNotEmpty,
        what: '连接测试结果');
    final checkText = tester
        .widget<Text>(find.descendant(
            of: find.byKey(const ValueKey('plugin-check-result')),
            matching: find.byType(Text)))
        .data;
    report('mosh.check', checkText);
    report('mosh.detail.sessionTestButton',
        find.byKey(const ValueKey('plugin-session-test')).evaluate().length);
    report(
        'mosh.detail.unavailable',
        texts().split('\n').firstWhere((t) => t.contains('会话测试拿不出这些材料'),
            orElse: () => '（没有）'));
    report('mosh.detail.liveSessionsNote',
        find.byKey(const ValueKey('plugin-live-sessions')).evaluate().length);
    report('mosh.detail.disconnectButton', find.text('断开').evaluate().length);
    expect(checkText, PluginDiscovery.checkReused);
    expect(find.byKey(const ValueKey('plugin-session-test')), findsNothing);
    expect(find.text('断开'), findsNothing);

    // 会话测试页：从详情页进不去（没有按钮），直接推进去看它也只给说明、开不了；再退出。
    unawaited(navigator().push(MaterialPageRoute<void>(
        builder: (_) =>
            const PluginSessionTestScreen(packageName: moshPackage))));
    await settle(tester, 800);
    final startButton = tester
        .widget<FilledButton>(find.byKey(const ValueKey('session-test-start')));
    report('mosh.sessionTest.startEnabled', startButton.onPressed != null);
    report(
        'mosh.sessionTest.unavailable',
        find
            .byKey(const ValueKey('session-test-unavailable'))
            .evaluate()
            .length);
    expect(startButton.onPressed, isNull);
    navigator().pop(); // 会话测试页
    await settle(tester, 800);
    navigator().pop(); // 详情页
    await settle(tester, 800);
    navigator().pop(); // 插件页
    await settle(tester, 2500); // 若有人断开连接，Mosh 会话会在这段时间里收尾

    report(
        'mosh.afterPlugins', 'phase=${session.phase} handle=${session.handle}');
    controller.typeInto(tab.id, 'echo after-\$((6*7))\r');
    var echoedAfter = true;
    try {
      await waitFor(tester, () => tab.terminal.allText().contains('after-42'),
          timeout: const Duration(seconds: 15), what: 'after-42');
    } on TestFailure {
      echoedAfter = false;
    }
    final starts2 = await monitor.starts();
    final running = await monitor.running();
    final stillThere = controller.state.sessions.any((s) => identical(s, tab));
    report(
        'mosh.after',
        'echoed=$echoedAfter phase=${session.phase} sameTab=$stillThere '
            'sameSession=${identical((tab.plugin! as MoshTerminalProvider).session, session)} '
            'starts=$starts1->$starts2 running=$running');
    expect(echoedAfter, isTrue);
    expect(session.phase, SessionPhase.active);
    expect(starts2, starts1, reason: '没有新起 mosh-server');
    expect(running, running0 + 1, reason: '还是本测试起的那一个 mosh-server 在跑');
    await controller.close(controller.state.sessions.indexOf(tab));
    var left = await monitor.running();
    for (var i = 0; i < 40 && left > running0; i++) {
      await settle(tester, 250);
      left = await monitor.running();
    }
    report('mosh.closed',
        'serverLeft=${left - running0} stopConfirmed=${session.stopConfirmed}');

    // ---- echo：另一个会话开着时进出会话测试 ----
    final echoEntry = container
        .read(pluginRegistryProvider)
        .singleWhere((e) => e.packageName == echoPackage);
    if (echoEntry.status == PluginStatus.needsApproval) {
      await discovery.approve(echoEntry);
    }
    final ready = container
        .read(pluginRegistryProvider)
        .singleWhere((e) => e.packageName == echoPackage);
    final first = await discovery.check(ready);
    report('echo.firstCheck', '${first.ok} reused=${first.reused}');
    final other = await manager.open(ready);
    final otherOut = BytesBuilder();
    final otherSub = other.output.listen(otherOut.add);
    addTearDown(otherSub.cancel);
    await waitFor(tester, () => other.phase == SessionPhase.active,
        what: 'echo 会话 active');
    await other.write(Uint8List.fromList(utf8.encode('one\n')));
    await waitFor(tester, () => utf8.decode(otherOut.toBytes()).contains('one'),
        what: 'echo 回显 one');

    unawaited(navigator().push(MaterialPageRoute<void>(
        builder: (_) =>
            const PluginSessionTestScreen(packageName: echoPackage))));
    await settle(tester, 800);
    await tapKey('session-test-start');
    await waitFor(tester, () => texts().contains('插件回报：运行中（active）'),
        what: '测试会话 active');
    await tester.enterText(
        find.byKey(const ValueKey('session-test-input')), 'hi');
    await tapKey('session-test-send');
    await waitFor(
        tester,
        () => tester
            .widget<SelectableText>(
                find.byKey(const ValueKey('session-test-output')))
            .data!
            .contains('hi'),
        what: '测试会话回显 hi');
    final steps = texts()
        .split('\n')
        .where((t) => RegExp(r'^\d+ ms  ').hasMatch(t))
        .join(' / ');
    report('echo.sessionTest.steps', steps);
    expect(steps, contains(PluginDiscovery.checkReused));
    navigator().pop();
    await settle(tester, 3000); // 测试会话关完（插件确认或 2 秒）后才会考虑断开

    await other.write(Uint8List.fromList(utf8.encode('two\n')));
    var echoedTwo = true;
    try {
      await waitFor(
          tester, () => utf8.decode(otherOut.toBytes()).contains('two'),
          timeout: const Duration(seconds: 10), what: 'echo 回显 two');
    } on TestFailure {
      echoedTwo = false;
    }
    final again = await discovery.check(ready);
    report(
        'echo.after',
        'otherPhase=${other.phase} echoedTwo=$echoedTwo liveSessions=${manager.sessions.length} '
            'checkAfter=${again.ok} reused=${again.reused}');
    expect(other.phase, SessionPhase.active);
    expect(echoedTwo, isTrue);
    expect(again.reused, isTrue, reason: '连接没被断开');
    await other.close();
    report('echo.closed', 'stopConfirmed=${other.stopConfirmed}');
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 4)));
}
