import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flterm/flterm.dart' as flterm show TerminalView;

// R18：快捷键栏的功能键交给引擎编码（跟远端的光标键模式走）、修饰键不粘、
// 分屏时输入只发给用户点过的那一格、地方不够时快捷键栏收成一行。两个引擎各跑一遍。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final engines = <String, TerminalSessionAdapterBase Function()>{
    'Ghostty': GhosttyTerminalAdapter.new,
  };

  for (final MapEntry(key: engine, value: newTerminal) in engines.entries) {
    group('$engine 功能键', () {
      late TerminalSessionAdapterBase terminal;
      late List<String> sent;

      setUp(() {
        terminal = newTerminal();
        sent = [];
        terminal.bind((bytes) => sent.add(latin1.decode(bytes)));
      });
      tearDown(() => terminal.dispose());

      test('方向键跟着远端切的光标键模式走（vim、less 会打开应用光标键）', () {
        terminal.sendKey(TerminalSpecialKey.arrowUp);
        terminal.feed(utf8.encode('\x1b[?1h'));
        terminal.sendKey(TerminalSpecialKey.arrowUp);
        terminal.sendKey(TerminalSpecialKey.arrowLeft);
        terminal.feed(utf8.encode('\x1b[?1l'));
        terminal.sendKey(TerminalSpecialKey.arrowUp);

        expect(sent, ['\x1b[A', '\x1bOA', '\x1bOD', '\x1b[A']);
      });

      test('快捷键栏的 Ctrl 套在方向键上，用完就灭', () {
        terminal.input.setModifiers({'ctrl'});
        terminal.sendKey(TerminalSpecialKey.arrowRight);
        terminal.sendKey(TerminalSpecialKey.arrowRight);

        expect(sent, ['\x1b[1;5C', '\x1b[C']);
        expect(terminal.input.modifiers, isEmpty);
      });

      test('Alt 套在 Tab、Esc、方向键上各只套一次', () {
        terminal.input.setModifiers({'alt'});
        terminal.sendKey(TerminalSpecialKey.tab);
        terminal.input.setModifiers({'alt'});
        terminal.sendKey(TerminalSpecialKey.escape);
        terminal.input.setModifiers({'alt'});
        terminal.sendKey(TerminalSpecialKey.arrowUp);

        expect(sent, ['\x1b\t', '\x1b\x1b', '\x1b[1;3A']);
        expect(terminal.input.modifiers, isEmpty);
      });

      test('Esc、Tab、Shift+Tab', () {
        terminal.sendKey(TerminalSpecialKey.escape);
        terminal.sendKey(TerminalSpecialKey.tab);
        terminal.input.setModifiers({'shift'});
        terminal.sendKey(TerminalSpecialKey.tab);

        expect(sent, ['\x1b', '\t', '\x1b[Z']);
        expect(terminal.input.modifiers, isEmpty);
      });

      test('按键面板的功能键（R25）：PgUp/PgDn、F1–F12、回车、退格、Delete、Insert，带不带修饰键', () {
        // 期望值按 xterm 的规矩写，和原版 xterm2 一样（对照用的 xtermKeySequence 在 test/support/xterm_terminal_adapter.dart）。
        final cases = <(TerminalSpecialKey, Set<String>, String)>[
          (TerminalSpecialKey.pageUp, {}, '\x1b[5~'),
          (TerminalSpecialKey.pageDown, {}, '\x1b[6~'),
          (TerminalSpecialKey.pageUp, {'ctrl'}, '\x1b[5;5~'),
          (TerminalSpecialKey.pageDown, {'shift'}, '\x1b[6;2~'),
          (TerminalSpecialKey.f1, {}, '\x1bOP'),
          (TerminalSpecialKey.f4, {}, '\x1bOS'),
          (TerminalSpecialKey.f1, {'shift'}, '\x1b[1;2P'),
          (TerminalSpecialKey.f5, {}, '\x1b[15~'),
          (TerminalSpecialKey.f6, {}, '\x1b[17~'),
          (TerminalSpecialKey.f10, {}, '\x1b[21~'),
          (TerminalSpecialKey.f11, {}, '\x1b[23~'),
          (TerminalSpecialKey.f12, {}, '\x1b[24~'),
          (TerminalSpecialKey.f5, {'ctrl'}, '\x1b[15;5~'),
          (TerminalSpecialKey.insert, {}, '\x1b[2~'),
          (TerminalSpecialKey.delete, {}, '\x1b[3~'),
          (TerminalSpecialKey.enter, {}, '\r'),
          (TerminalSpecialKey.enter, {'alt'}, '\x1b\r'),
          (TerminalSpecialKey.backspace, {}, '\x7f'),
          (TerminalSpecialKey.backspace, {'alt'}, '\x1b\x7f'),
          (TerminalSpecialKey.home, {}, '\x1b[H'),
          (TerminalSpecialKey.end, {'ctrl'}, '\x1b[1;5F'),
        ];
        for (final (key, modifiers, expected) in cases) {
          sent.clear();
          terminal.input.setModifiers(modifiers);
          terminal.sendKey(key);
          expect(sent, [expected], reason: '$key $modifiers');
          expect(terminal.input.modifiers, isEmpty, reason: '用完就灭：$key');
        }
      });

      test('释放后按键不碰引擎、不抛错', () {
        terminal.dispose();
        terminal.sendKey(TerminalSpecialKey.arrowUp);
        expect(sent, isEmpty);
      });
    });

    group('$engine 终端页', () {
      testWidgets('分屏：快捷键栏的键和修饰键只发给点过的那一格，换格时上一格的修饰键清掉', (tester) async {
        final page = await _Page.open(tester, newTerminal);
        final engineView = flterm.TerminalView;
        await tester.tap(find.byKey(const ValueKey('terminal-action-split')));
        await page.settle();
        expect(find.byType(engineView), findsNWidgets(2));

        // 没点过哪一格时输入跟当前标签走。
        await tester.tap(find.text('↑'));
        await page.settle();
        expect(page.sent['first'], ['\x1b[A']);
        expect(page.sent['second'], isEmpty);

        // 点第二格：描边挪过去，快捷键栏改发给它。
        await tester.tap(find.byType(engineView).last);
        await page.settle();
        expect(
          tester.getRect(find.byKey(
            const ValueKey('terminal-pane-input-target'),
          )),
          tester.getRect(find.byType(engineView).last),
        );
        await tester.tap(find.text('↑'));
        await tester.tap(find.text('Ctrl'));
        await page.settle();
        expect(page.sent['first'], ['\x1b[A']);
        expect(page.sent['second'], ['\x1b[A']);
        expect(page.second.terminal.input.modifiers, {'ctrl'});
        expect(page.first.terminal.input.modifiers, isEmpty);

        // 回到第一格：第二格挂着的 Ctrl 清掉，不会等用户回去时把下一个字变成控制键。
        await tester.tap(find.byType(engineView).first);
        await page.settle();
        expect(page.second.terminal.input.modifiers, isEmpty);
        await tester.tap(find.text('→'));
        await page.settle();
        expect(page.sent['first'], ['\x1b[A', '\x1b[C']);
        expect(page.sent['second'], ['\x1b[A']);
      });

      testWidgets(
          '快捷键栏的 PgUp/PgDn（10-07）：两行放下 14 个键，PgUp 在 PgDn 上面；按远端键盘模式发、套修饰键', (
        tester,
      ) async {
        final page = await _Page.open(tester, newTerminal);
        final pgUp = tester.getCenter(find.text('PgUp'));
        final pgDn = tester.getCenter(find.text('PgDn'));
        expect(pgUp.dx, moreOrLessEquals(pgDn.dx, epsilon: 1));
        expect(pgDn.dy, greaterThan(pgUp.dy));
        expect(tester.getCenter(find.text('Esc')).dy,
            moreOrLessEquals(pgUp.dy, epsilon: 1),
            reason: '还是两行');
        expect(tester.getCenter(find.text('↑')).dx,
            moreOrLessEquals(tester.getCenter(find.text('↓')).dx, epsilon: 1));

        await tester.tap(find.text('PgUp'));
        await page.settle();
        await tester.tap(find.text('Ctrl'));
        await page.settle();
        await tester.tap(find.text('PgDn'));
        await page.settle();
        expect(page.sent['first'], ['\x1b[5~', '\x1b[6;5~']);
        expect(page.first.terminal.input.modifiers, isEmpty);
      });

      testWidgets('切标签、切到后台：修饰键清掉', (tester) async {
        final page = await _Page.open(tester, newTerminal);
        await tester.tap(find.text('Alt'));
        await page.settle();
        expect(page.first.terminal.input.modifiers, {'alt'});

        page.controller.activate(1);
        await page.settle();
        expect(page.first.terminal.input.modifiers, isEmpty);

        await tester.tap(find.text('Ctrl'));
        await page.settle();
        expect(page.second.terminal.input.modifiers, {'ctrl'});
        page.controller.setBackgrounded(true);
        expect(page.second.terminal.input.modifiers, isEmpty);
        page.controller.setBackgrounded(false);
      });

      testWidgets('UX02：竖屏、横屏、横屏弹键盘，触控目标 48dp、可点的都有标签、文字对比度够', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final page = await _Page.open(tester, newTerminal);
        Future<void> expectGuidelines(String layout) async {
          for (final guideline in [
            androidTapTargetGuideline,
            labeledTapTargetGuideline,
            textContrastGuideline,
          ]) {
            final result = await guideline.evaluate(tester);
            expect(result.passed, isTrue, reason: '$layout：${result.reason}');
          }
        }

        await expectGuidelines('竖屏');
        tester.view.physicalSize = const Size(2400, 1080);
        await page.settle();
        await expectGuidelines('横屏');
        tester.view.viewInsets = const FakeViewPadding(bottom: 261 * 2.625);
        await page.settle();
        await expectGuidelines('横屏弹键盘');
        tester.view.resetViewInsets();
        semantics.dispose();
      });

      testWidgets('横屏收成一行，弹键盘时再收起标签条；终端始终有地方、不溢出', (tester) async {
        final page = await _Page.open(tester, newTerminal);
        final engineView = flterm.TerminalView;
        Finder compactBar() =>
            find.byKey(const ValueKey('terminal-special-keys-compact'));
        Finder tabs() => find.byKey(const ValueKey('terminal-tab-strip'));

        // 竖屏：两行快捷键 + 一行操作按钮。
        expect(compactBar(), findsNothing);
        expect(tabs(), findsOneWidget);

        // 横屏（Pixel 7 横过来是 914x411dp）：一行。
        tester.view.physicalSize = const Size(2400, 1080);
        tester.view.devicePixelRatio = 2.625;
        await page.settle();
        expect(compactBar(), findsOneWidget);
        expect(tabs(), findsOneWidget);
        expect(
            find.byKey(const ValueKey('terminal-action-more')), findsOneWidget);

        // 再弹软键盘（模拟器上实测 261dp）：标签条也收起。
        tester.view.viewInsets = const FakeViewPadding(bottom: 261 * 2.625);
        await page.settle();
        expect(tabs(), findsNothing);
        expect(compactBar(), findsOneWidget);
        expect(tester.getSize(find.byType(engineView)).height, greaterThan(48));

        // 「更多」里的操作照样能用。
        await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
        await page.settle();
        await tester.tap(find.byKey(const ValueKey('terminal-action-split')));
        await page.settle();
        expect(find.byType(engineView), findsNWidgets(2));

        tester.view.resetViewInsets();
        await page.settle();
      });
    });
  }
}

/// 两个标签的终端页，终端都绑着记录用的 sink（像连着一样），不建真连接。
class _Page {
  _Page(this.tester, this.controller, this.first, this.second, this.sent);

  final WidgetTester tester;
  final SessionController controller;
  final ActiveTerminalSession first;
  final ActiveTerminalSession second;
  final Map<String, List<String>> sent;

  static Future<_Page> open(
    WidgetTester tester,
    TerminalSessionAdapterBase Function() newTerminal,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final messenger = tester.binding.defaultBinaryMessenger;
    const pip = MethodChannel('top.xdwa.shun/picture_in_picture');
    messenger.setMockMethodCallHandler(pip, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(pip, null));
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    // flterm 在终端闲下来 250ms 后排一个「空闲优先级」任务压缩滚动区；有动画在跑（点按钮的水波纹）时
    // 调度器推迟它，用零延时计时器反复重试。真机上帧照常出、动画结束就放行；测试的假时钟在一次
    // pump(时长) 里不出帧，这个重试就成了死循环（vm_service 抓到的栈停在 SchedulerBinding._runTasks）。
    // 这里让空闲任务不等动画，和终端页逻辑无关。
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);

    final sent = <String, List<String>>{};
    ActiveTerminalSession session(String id) {
      final terminal = newTerminal();
      sent[id] = [];
      terminal.bind((Uint8List bytes) => sent[id]!.add(latin1.decode(bytes)));
      return ActiveTerminalSession(
        id: id,
        host: HostProfile.create(
          id: id,
          label: id,
          hostname: '$id.example.com',
          username: 'root',
        ),
        terminal: terminal,
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
      );
    }

    final first = session('first');
    final second = session('second');
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith(
        (ref) => _SeededSessionController(
          ref.read(vaultControllerProvider.notifier),
          ref,
          SessionState(sessions: [first, second]),
        ),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: TerminalScreen())),
    ));
    final page = _Page(
      tester,
      container.read(sessionControllerProvider.notifier),
      first,
      second,
      sent,
    );
    await page.settle();
    // 终端挂上时的协议回应（焦点事件之类）不算快捷键栏发的。
    for (final list in sent.values) {
      list.clear();
    }
    return page;
  }

  /// 隔开两次点按，免得被当成双击（双击是选词）；Ghostty 换手要多等一两帧。
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  }
}

class _SeededSessionController extends SessionController {
  _SeededSessionController(
    VaultController vaultController,
    Ref ref,
    SessionState initialState,
  ) : super(_NoNetworkSshService(), vaultController, ref) {
    state = initialState;
  }
}

/// 前后台切换会让会话控制器去重连没连着的标签；测试里一律失败，不碰网络。
class _NoNetworkSshService extends SshService {
  @override
  Future<ActiveTerminalSession> connect({
    required String sessionId,
    required HostProfile host,
    List<HostProfile> hosts = const [],
    List<SshKeyProfile> keys = const [],
    List<ProxyProfile> proxyProfiles = const [],
    RoutePlan? routePlan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required TerminalSessionAdapter terminal,
    ConnectionPurpose purpose = ConnectionPurpose.fresh,
    ConnectionAttempt? attempt,
    TmuxTarget? tmuxAttach,
  }) async =>
      throw StateError('测试不连网络');
}
