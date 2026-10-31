// R45 设备验证：真 SSH，远端录下收到的所有字节，证明切页、切主机、收起都不发东西；顺便量折叠后的可见行数。
//
//   SHUN_R39_AVD=shun-r39-a30 python3 tool/fixture-drive.py integration_test/r45_host_keys_test.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/settings_screen.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/widgets/terminal_key_button.dart';

const _raw = String.fromEnvironment('SHUN_FIXTURE');
final Map<String, dynamic> fixture =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

void report(String key, Object? value) => debugPrint('R45 $key=$value');

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> until(WidgetTester tester, bool Function() condition,
    {required String what,
    Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 外面的脚本看到这一行就截一张屏（`adb screencap`），给人看排版。
Future<void> shot(WidgetTester tester, String name) async {
  report('shot', name);
  await settle(tester, 2500);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('R45 按主机的快捷键', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester, 1500);

    final vault = container.read(vaultControllerProvider.notifier);
    final sessions = container.read(sessionControllerProvider.notifier);
    final ai = terminalKeyTemplates.singleWhere((t) => t.id == 'ai-cli').keys;
    final tmux =
        terminalKeyTemplates.singleWhere((t) => t.id == 'tmux-vim').keys;
    HostProfile host(String id) => HostProfile({
          'id': id,
          'label': id.toUpperCase(),
          'hostname': '127.0.0.1',
          'port': fixture['edgePort'],
          'username': fixture['user'],
          'password': fixture['password'],
          'authMethod': 'password',
          'protocol': 'ssh',
        });
    final withLayout = host('r45-a').withTerminalKeys(ai);
    final plain = host('r45-b');
    await vault.upsertHost(withLayout);
    await vault.upsertHost(plain);
    Future<bool> verify(_, __, ___) async => true;
    expect(await sessions.connect(withLayout, verify), isTrue);
    expect(await sessions.connect(plain, verify), isTrue);
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester, 1500);

    ActiveTerminalSession tab(String id) => container
        .read(sessionControllerProvider)
        .sessions
        .singleWhere((session) => session.host.id == id);
    final a = tab('r45-a');
    final b = tab('r45-b');
    // 两个标签都把收到的字节录下来：后面不管怎么切，这里多一个字节都能看见。
    for (final (session, file) in [(a, 'a'), (b, 'b')]) {
      sessions.typeInto(
        session.id,
        'clear; stty -echo; cat > /tmp/r45-$file.out; stty echo\r',
      );
    }
    await settle(tester, 1500);

    Finder keyLabeled(String label) =>
        find.widgetWithText(TerminalKeyButton, label);
    final panelToggle =
        find.byKey(const ValueKey('terminal-action-input-panel'));
    final hide = find.byKey(const ValueKey('terminal-action-hide-keyboard'));

    // 可见行数和会话切换入口（任务要评估的）。当前标签是 b，刚连上时系统键盘弹着。
    expect(container.read(sessionControllerProvider).active?.id, b.id);
    final strip = find.byKey(const ValueKey('terminal-tab-strip'));
    double inset() =>
        tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
    void measure(String state) {
      report('rows.$state', b.terminal.viewRows);
      report('inset.$state', inset());
      report('tabStrip.$state', strip.evaluate().isNotEmpty);
    }

    measure('keyboard');
    await tester.tap(hide);
    await settle(tester, 1500);
    measure('folded');
    await tester.tap(panelToggle);
    await settle(tester, 1500);
    measure('panel');
    await tester.tap(hide);
    await settle(tester, 1500);
    container.read(terminalFullscreenProvider.notifier).state = true;
    await settle(tester, 1500);
    measure('fullscreen');
    container.read(terminalFullscreenProvider.notifier).state = false;
    await settle(tester, 1500);

    // 没有专用布局的 b：默认键。面板开着时快捷键栏收成一行，按照样在。
    await tester.tap(panelToggle);
    await settle(tester, 1200);
    final bar = find.byKey(const ValueKey('terminal-special-keys-compact'));
    expect(
        find.descendant(of: bar, matching: keyLabeled('Esc')), findsOneWidget);
    expect(
        find.descendant(of: bar, matching: keyLabeled('⇧Tab')), findsNothing);
    report('plainHostDefaultKeys', true);

    // 亮着 Ctrl、面板换页：带着走（R25），什么都不发。
    b.input.setModifiers(const {'ctrl'});
    await settle(tester, 300);
    for (final page in ['symbols', 'control', 'function', 'common']) {
      await tester.tap(find.byKey(ValueKey('terminal-key-page-$page')));
      await settle(tester, 400);
    }
    expect(b.input.modifiers, {'ctrl'});

    // 切主机：Ctrl 熄灭，布局换成 a 的专用布局。
    sessions.activate(0);
    await settle(tester, 1500);
    expect(container.read(sessionControllerProvider).active?.id, a.id);
    expect(b.input.modifiers, isEmpty);
    report('switchHostClearsModifier', true);
    expect(
        find.descendant(of: bar, matching: keyLabeled('⇧Tab')), findsOneWidget);
    report('hostLayoutFollowsTab', true);

    // 折叠：亮着的 Alt 熄灭。
    a.input.setModifiers(const {'alt'});
    await settle(tester, 300);
    await tester.tap(hide);
    await settle(tester, 1000);
    expect(a.input.modifiers, isEmpty);
    report('foldClearsModifier', true);

    // 按专用布局里的键：走同一个出口，远端收到 CSI Z。前面那些切换一个字节都没发的话，文件里只有它。
    await tester.tap(panelToggle);
    await settle(tester, 1200);
    await tester.tap(find.descendant(of: bar, matching: keyLabeled('⇧Tab')));
    await settle(tester, 500);

    Future<String> recorded(ActiveTerminalSession session, String file) async {
      // 回车冲掉一行，Ctrl+D 结束 cat。
      sessions.typeInto(session.id, '\r\x04');
      await settle(tester, 800);
      sessions.typeInto(
        session.id,
        "clear; printf 'R4''5<'; od -An -tx1 /tmp/r45-$file.out | tr -d ' \\n'; printf '>\\n'\r",
      );
      final pattern = RegExp(r'R45<([0-9a-f]*)>');
      await until(
        tester,
        () => pattern.hasMatch(session.terminal.allText()),
        what: '远端打出录到的字节',
      );
      return pattern.firstMatch(session.terminal.allText())!.group(1)!;
    }

    final fromA = await recorded(a, 'a');
    report('a.received', fromA);
    // ESC [ Z，然后是冲一行的回车。
    expect(fromA, '1b5b5a0a');
    sessions.activate(1);
    await settle(tester, 1000);
    final fromB = await recorded(b, 'b');
    report('b.received', fromB);
    expect(fromB, '0a', reason: '只有冲一行的回车：切页、切主机、折叠都没发东西');
    report('nothingSentBySwitching', true);

    // 从真的快捷键设置改；存进保险库，重新读盘也在。
    await tester.tap(hide);
    await settle(tester, 1000);
    final edit = find.byKey(const ValueKey('terminal-action-edit'));
    if (edit.evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
      await settle(tester, 500);
    }
    await tester.tap(edit.first);
    await settle(tester, 800);
    await tester.tap(find.byKey(const ValueKey('terminal-keys-host-scope')));
    await settle(tester, 400);
    await tester.tap(
      find.byKey(const ValueKey('terminal-keys-template-tmux-vim')),
    );
    await settle(tester, 400);
    await shot(tester, 'sheet');
    await tester.tap(find.byKey(const ValueKey('terminal-keys-save')));
    await settle(tester, 1000);
    final saved = (await repository.loadVault())
        .hosts
        .singleWhere((value) => value.id == 'r45-b');
    expect(saved.terminalKeys, tmux);
    report('hostLayoutPersisted', true);
    // 存完不用切标签，眼前的键就换了（键盘收着，先展开）。
    await tester.tap(panelToggle);
    await settle(tester, 1200);
    expect(
      find.descendant(of: bar, matching: keyLabeled('Ctrl+B')),
      findsOneWidget,
    );
    report('hostLayoutAppliesAtOnce', true);
    await shot(tester, 'panel-tmux');

    // 按键高度：同一台手机上终端少几行。
    final settingsController =
        container.read(settingsControllerProvider.notifier);
    await settingsController.edit((s) => s.copyWith(terminalKeyHeight: 64));
    await settle(tester, 1200);
    measure('panel64');
    await shot(tester, 'panel64');
    await tester.tap(panelToggle);
    await settle(tester, 2000);
    measure('keyboard64');
    await shot(tester, 'keyboard64');
    await settingsController.edit((s) => s.copyWith(terminalKeyHeight: 48));
    await settle(tester, 1200);
    measure('keyboard48');
    await shot(tester, 'keyboard48');

    // 设置页那三项。
    await tester.tap(hide);
    await settle(tester, 1000);
    container.read(homeTabProvider.notifier).state = 4;
    await settle(tester, 1200);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-key-height')),
      300,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await settle(tester, 600);
    await shot(tester, 'settings');
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester, 800);

    await sessions.close(1);
    await sessions.close(0);
    await settle(tester);
  }, skip: fixture.isEmpty, timeout: const Timeout(Duration(minutes: 5)));
}
