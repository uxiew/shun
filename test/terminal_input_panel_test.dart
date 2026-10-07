import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/home_navigation.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/domain/tmux/tmux_target.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:netcatty_mobile/presentation/screens/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flterm/flterm.dart' as flterm show TerminalView;
import 'package:xterm2/xterm.dart' as xterm show TerminalView;

// R25 第一部分：终端输入面板（所有者 10-07 提的）。快捷键栏上的按钮在系统键盘和面板之间切；面板里左右滑动换
// 按键面板 / 大输入框；按键走 sendKey/sendText 同一个出口，大输入框按 R19 的粘贴发、认动手那一刻的连接；
// 面板占系统键盘的位置，切换时远端只收到一次尺寸。两个引擎各跑一遍。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final engines = <String, TerminalSessionAdapterBase Function()>{
    'Ghostty': GhosttyTerminalAdapter.new,
    'xterm2': XtermTerminalAdapter.new,
  };

  final panel = find.byKey(const ValueKey('terminal-input-panel'));
  final toggle = find.byKey(const ValueKey('terminal-action-input-panel'));
  final editor = find.byKey(const ValueKey('terminal-compose-editor'));
  final send = find.byKey(const ValueKey('terminal-compose-send'));
  final fill = find.byKey(const ValueKey('terminal-compose-fill'));
  Finder panelKey(String label) =>
      find.descendant(of: panel, matching: find.text(label));

  for (final MapEntry(key: engine, value: newTerminal) in engines.entries) {
    final engineView =
        engine == 'Ghostty' ? flterm.TerminalView : xterm.TerminalView;

    group('$engine 按键面板', () {
      testWidgets('快捷键栏的按钮打开面板：系统键盘收起、快捷键栏收成一行、记住方式；键按远端键盘模式发到终端', (
        tester,
      ) async {
        final page = await _Page.open(tester, newTerminal);
        expect(panel, findsNothing);

        await tester.tap(toggle);
        await page.settle();
        expect(panel, findsOneWidget);
        expect(find.byKey(const ValueKey('terminal-special-keys-compact')),
            findsOneWidget);
        expect((await page.repository.loadSettings()).terminalInputMode,
            terminalInputKeys);
        expect(tester.testTextInput.isVisible, isFalse, reason: '面板占着系统键盘的位置');

        for (final label in ['Esc', 'Tab', '⌫', '⏎', '↑', 'PgUp', '/']) {
          await tester.tap(panelKey(label));
          await page.settle();
        }
        expect(page.sent['first'],
            ['\x1b', '\t', '\x7f', '\r', '\x1b[A', '\x1b[5~', '/']);

        // vim 打开应用光标键以后，面板的方向键跟着发 ESC O A（和快捷键栏一样交给引擎编码）。
        page.first.terminal.feed(utf8.encode('\x1b[?1h'));
        page.sent['first']!.clear();
        await tester.tap(panelKey('↑'));
        await page.settle();
        expect(page.sent['first'], ['\x1bOA']);
      });

      testWidgets('修饰键一次性：面板上的 Ctrl 和快捷键栏亮的是同一个，套在下一个键上就灭；分页之间带着走', (
        tester,
      ) async {
        final page = await _Page.open(tester, newTerminal);
        await tester.tap(toggle);
        await page.settle();

        await tester.tap(panelKey('Ctrl'));
        await page.settle();
        expect(page.first.terminal.input.modifiers, {'ctrl'});
        // 符号页：Ctrl + [ 就是 Esc。
        await tester
            .tap(find.byKey(const ValueKey('terminal-key-page-symbols')));
        await page.settle();
        await tester.tap(panelKey('['));
        await page.settle();
        expect(page.sent['first'], ['\x1b']);
        expect(page.first.terminal.input.modifiers, isEmpty);

        // F 键页：Shift + F5。
        await tester
            .tap(find.byKey(const ValueKey('terminal-key-page-function')));
        await page.settle();
        await tester.tap(panelKey('Shift'));
        await page.settle();
        await tester.tap(panelKey('F5'));
        await page.settle();
        // Ctrl 组合页：Ctrl+R（反向搜历史）。
        await tester
            .tap(find.byKey(const ValueKey('terminal-key-page-control')));
        await page.settle();
        await tester.tap(panelKey('Ctrl+R'));
        await page.settle();
        expect(page.sent['first'], ['\x1b', '\x1b[15;2~', '\x12']);

        // 亮着的修饰键在切到后台时照样熄灭（R18 的规矩）。
        await tester.tap(panelKey('Alt'));
        await page.settle();
        page.controller.setBackgrounded(true);
        expect(page.first.terminal.input.modifiers, isEmpty);
        page.controller.setBackgrounded(false);

        // 面板上没有字母键：亮起 Ctrl 再换回系统键盘，Ctrl 还亮着，套在系统键盘打的下一个字上
        //（系统键盘那一半是 R18 的设备测试核对的：快捷键栏 Ctrl + 软键盘 c 发 03）。
        await tester.tap(panelKey('Ctrl'));
        await page.settle();
        await tester
            .tap(find.byKey(const ValueKey('terminal-input-system-keyboard')));
        await page.settle();
        expect(panel, findsNothing);
        expect(page.first.terminal.input.modifiers, {'ctrl'});
      });

      testWidgets('方向键按住连发、松手就停；从键上起步左右滑是切页，不连发', (tester) async {
        final page = await _Page.open(tester, newTerminal);
        await tester.tap(toggle);
        await page.settle();

        final gesture = await tester.startGesture(
          tester.getCenter(panelKey('↓')),
        );
        await tester.pump(const Duration(milliseconds: 650));
        await gesture.up();
        await page.settle();
        final repeated = page.sent['first']!.length;
        expect(repeated, greaterThanOrEqualTo(3));
        expect(page.sent['first']!.toSet(), {'\x1b[B'});

        await tester.timedDragFrom(
          tester.getCenter(panelKey('↓')),
          const Offset(-300, 0),
          const Duration(milliseconds: 600),
        );
        await page.settle();
        expect(page.sent['first']!.length, repeated, reason: '滑动不连发');
        expect(editor, findsOneWidget, reason: '滑到了大输入框');
      });

      testWidgets('分屏：面板的键发给点过的那一格', (tester) async {
        final page = await _Page.open(tester, newTerminal);
        await tester.tap(find.byKey(const ValueKey('terminal-action-split')));
        await page.settle();
        await tester.tap(toggle);
        await page.settle();
        await tester.tap(find.byType(engineView).last);
        await page.settle();
        await tester.tap(panelKey('Tab'));
        await page.settle();
        expect(page.sent['first'], isEmpty);
        expect(page.sent['second'], ['\t']);
      });
    });

    group('$engine 大输入框', () {
      Future<_Page> openCompose(WidgetTester tester) async {
        final page = await _Page.open(tester, newTerminal);
        await tester.tap(toggle);
        await page.settle();
        await tester
            .tap(find.byKey(const ValueKey('terminal-input-tab-compose')));
        await page.settle();
        expect(editor, findsOneWidget);
        return page;
      }

      testWidgets('左右滑到大输入框；「发送」= 内容 + 回车，发出去才清空；「只填入」不回车', (tester) async {
        final page = await _Page.open(tester, newTerminal);
        await tester.tap(toggle);
        await page.settle();
        await tester.drag(
          find.byKey(const ValueKey('terminal-input-panel-pages')),
          const Offset(-400, 0),
        );
        await page.settle();
        expect(editor, findsOneWidget);
        expect((await page.repository.loadSettings()).terminalInputMode,
            terminalInputCompose);

        await tester.enterText(editor, 'echo 你好');
        await page.settle();
        expect(page.sent['first'], isEmpty, reason: '打字只在框里，不进终端');
        await tester.tap(send);
        await page.settle();
        expect(page.sent['first'], ['echo 你好', '\r']);
        expect(tester.widget<TextField>(editor).controller!.text, isEmpty);

        await tester.enterText(editor, 'ls -l');
        await page.settle();
        await tester.tap(fill);
        await page.settle();
        expect(page.sent['first'], ['echo 你好', '\r', 'ls -l']);
      });

      testWidgets('多行：照实写会不会逐行执行；没开 bracketed paste 换行变 CR，开着包粘贴标记',
          (tester) async {
        final page = await openCompose(tester);
        await tester.enterText(editor, 'touch a\ntouch b\n');
        await page.settle();
        expect(find.byKey(const ValueKey('terminal-compose-risk-lines-run')),
            findsOneWidget);
        await tester.tap(fill);
        await page.settle();
        expect(page.sent['first'], ['touch a\rtouch b'], reason: '末尾换行去掉，不回车');

        page.first.terminal.feed(utf8.encode('\x1b[?2004h'));
        page.sent['first']!.clear();
        await tester.enterText(editor, 'touch c\ntouch d');
        await page.settle();
        expect(find.byKey(const ValueKey('terminal-compose-risk-bracketed')),
            findsOneWidget);
        await tester.tap(send);
        await page.settle();
        final sent = page.sent['first']!.join();
        expect(sent, startsWith('\x1b[200~touch c'));
        expect(sent, endsWith('touch d\x1b[201~\r'));
      });

      testWidgets('断线：不发、字留着；恢复成新连接也不发，点「改发到新连接」才发', (tester) async {
        final page = await openCompose(tester);
        await tester.enterText(editor, 'rm -rf build');
        await page.settle();

        page.controller.markDisconnected('first');
        await page.settle();
        expect(find.byKey(const ValueKey('terminal-compose-target-problem')),
            findsOneWidget);
        expect(tester.widget<FilledButton>(send).onPressed, isNull);

        // 恢复：同一个标签、同一个终端，新的连接对象（新的 shell）。
        final restored = page.controller.restore('first');
        await page.settle();
        expect(tester.widget<FilledButton>(send).onPressed, isNull,
            reason: '字是对着原来那条写的，不自动改发');
        expect(page.sent['first'], isEmpty);
        expect(
            tester.widget<TextField>(editor).controller!.text, 'rm -rf build');

        await tester
            .tap(find.byKey(const ValueKey('terminal-compose-retarget')));
        await page.settle();
        await tester.tap(send);
        await page.settle();
        expect(page.sent['first'], ['rm -rf build', '\r']);
        expect(
            identical(page.controller.state.sessions.first, restored), isTrue);
      });

      testWidgets('草稿每个标签一份；关掉的标签留下的字不丢，可以放进别的标签的框', (tester) async {
        final page = await openCompose(tester);
        await tester.enterText(editor, 'for first');
        await page.settle();

        page.controller.activate(1);
        await page.settle();
        expect(tester.widget<TextField>(editor).controller!.text, isEmpty);
        await tester.enterText(editor, 'for second');
        await page.settle();
        page.controller.activate(0);
        await page.settle();
        expect(tester.widget<TextField>(editor).controller!.text, 'for first');

        await page.controller.close(0);
        await page.settle();
        expect(find.byKey(const ValueKey('terminal-compose-orphan')),
            findsOneWidget);
        expect(tester.widget<TextField>(editor).controller!.text, 'for second');
        expect(find.byKey(const ValueKey('terminal-compose-orphan-take')),
            findsNothing,
            reason: '框里已经有字，不覆盖');
        await tester.enterText(editor, '');
        await page.settle();
        await tester
            .tap(find.byKey(const ValueKey('terminal-compose-orphan-take')));
        await page.settle();
        expect(tester.widget<TextField>(editor).controller!.text, 'for first');
        expect(page.sent['second'], isEmpty, reason: '放进来不等于发出去');
      });

      testWidgets('记住上次用的是大输入框：重开页面直接是大输入框', (tester) async {
        final page = await _Page.open(
          tester,
          newTerminal,
          settings: const AppSettings(terminalInputMode: terminalInputCompose),
        );
        expect(panel, findsOneWidget);
        expect(editor, findsOneWidget);
        await page.settle();
      });
    });

    group('$engine 切换和布局', () {
      testWidgets('面板收起、点终端再展开；返回键收起面板；换回系统键盘会叫出键盘', (tester) async {
        final page = await _Page.open(tester, newTerminal);
        await tester.tap(toggle);
        await page.settle();

        await tester
            .tap(find.byKey(const ValueKey('terminal-action-hide-keyboard')));
        await page.settle();
        expect(panel, findsNothing);
        await tester.tapAt(tester.getCenter(find.byType(engineView)));
        await page.settle();
        expect(panel, findsOneWidget, reason: '点终端是想打字');
        expect(tester.testTextInput.isVisible, isFalse);

        await tester.binding.handlePopRoute();
        await page.settle();
        expect(panel, findsNothing);
        await tester.tapAt(tester.getCenter(find.byType(engineView)));
        await page.settle();

        await tester
            .tap(find.byKey(const ValueKey('terminal-input-system-keyboard')));
        await page.settle();
        expect(panel, findsNothing);
        expect((await page.repository.loadSettings()).terminalInputMode,
            terminalInputSystem);
        expect(tester.testTextInput.isVisible, isTrue);
      });

      testWidgets('面板打开、收起：远端各只收到一次尺寸；系统键盘换面板（键盘往下收）时终端不变', (
        tester,
      ) async {
        final page = await _Page.open(tester, newTerminal);
        final rowsAtStart = page.first.terminal.viewRows;
        page.resizes['first']!.clear();

        await tester.tap(toggle);
        await page.settle();
        expect(page.resizes['first'], hasLength(1));
        final rowsWithPanel = page.first.terminal.viewRows;
        expect(rowsWithPanel, lessThan(rowsAtStart));

        await tester
            .tap(find.byKey(const ValueKey('terminal-action-hide-keyboard')));
        await page.settle();
        expect(page.resizes['first'], hasLength(2));

        // 换回系统键盘、弹出键盘（336dp，竖屏 Gboard 的高度），记下键盘高度。
        await tester.tap(toggle);
        await page.settle();
        await tester
            .tap(find.byKey(const ValueKey('terminal-input-system-keyboard')));
        await page.keyboard(336);
        final rowsWithKeyboard = page.first.terminal.viewRows;
        page.resizes['first']!.clear();

        // 从系统键盘切到面板：键盘一帧一帧往下收，面板一帧一帧往上长（占的就是键盘的位置），
        // 远端最多收到一次尺寸、就是最后的尺寸（快捷键栏收成一行让出来的那几行），没有中间值。
        await tester.tap(toggle);
        await page.keyboard(0);
        final rowsWithPanel2 = page.first.terminal.viewRows;
        expect(page.resizes['first']!.length, lessThanOrEqualTo(1));
        if (page.resizes['first']!.isNotEmpty) {
          expect(page.resizes['first']!.single.$2, rowsWithPanel2);
        }
        expect(rowsWithPanel2, greaterThanOrEqualTo(rowsWithKeyboard),
            reason: '面板和键盘一样高，快捷键栏还收成了一行');
      });

      testWidgets('点进大输入框、系统键盘升上来：远端只收到最后一次尺寸，没有中间值', (tester) async {
        final page = await _Page.open(tester, newTerminal);
        await tester.tap(toggle);
        await page.settle();
        await tester
            .tap(find.byKey(const ValueKey('terminal-input-tab-compose')));
        await page.settle();
        // 先把焦点拿开、键盘收下，再从头看一次「点进框里」。
        FocusManager.instance.primaryFocus?.unfocus();
        await page.keyboard(0);
        page.resizes['first']!.clear();

        await tester.tap(editor);
        await page.keyboard(336);
        expect(page.resizes['first'], hasLength(1));
        expect(page.resizes['first']!.single.$2, page.first.terminal.viewRows);
      });

      testWidgets('底部有导航栏、手势条留白 24dp：系统键盘换面板时终端不会在键盘收的那几帧多出一行', (
        tester,
      ) async {
        tester.view.padding = const FakeViewPadding(bottom: 24 * 2.625);
        final page = await _Page.open(tester, newTerminal, navigationBar: true);
        addTearDown(tester.view.resetPadding);
        await page.keyboard(200, gesturePadding: 24);
        await page.keyboard(0, gesturePadding: 24);
        await tester.tap(toggle);
        await page.settle();
        await tester
            .tap(find.byKey(const ValueKey('terminal-input-system-keyboard')));
        await page.keyboard(200, gesturePadding: 24);
        page.resizes['first']!.clear();
        final terminal = find.byType(engineView);

        await tester.tap(toggle);
        // 切换那一下终端变一次（快捷键栏收成一行），之后键盘一帧帧往下收、面板往上长，终端一直不变。
        final heights = <double>[];
        final ratio = tester.view.devicePixelRatio;
        for (var frame = 1; frame <= 20; frame++) {
          final inset = 200 * (1 - frame / 20);
          tester.view.viewInsets = FakeViewPadding(bottom: inset * ratio);
          tester.view.padding =
              FakeViewPadding(bottom: inset > 0 ? 0 : 24 * ratio);
          await tester.pump(const Duration(milliseconds: 16));
          heights.add(tester.getSize(terminal).height);
        }
        await page.settle();
        expect(
            heights.reduce(math.max) - heights.reduce(math.min), lessThan(.5),
            reason: '键盘收的那几帧终端忽高忽低：$heights');
        expect(tester.getSize(terminal).height, moreOrLessEquals(heights.last));
        expect(page.resizes['first']!.length, lessThanOrEqualTo(1));
      });

      testWidgets('系统键盘方式、横屏收键盘：终端视图不重新挂上，不会自己把键盘叫回来', (
        tester,
      ) async {
        tester.view.padding = const FakeViewPadding(bottom: 24 * 2.625);
        final page = await _Page.open(tester, newTerminal, navigationBar: true);
        addTearDown(tester.view.resetPadding);
        // 模拟器横屏：终端页 290dp 左右高（状态栏、导航栏），键盘 261dp。
        tester.view.physicalSize = const Size(2400, 1080);
        await page.settle();
        await page.keyboard(261, gesturePadding: 24);
        final engineState = tester.state(find.byType(engineView));
        expect(find.byKey(const ValueKey('terminal-tab-strip')), findsNothing);

        FocusManager.instance.primaryFocus?.unfocus();
        tester.testTextInput.hide();
        // 真机上键盘收得快，一帧就从 261 掉到 50：这一帧里标签条出现、底部多出 24dp 空白，头尾同时变。
        final ratio = tester.view.devicePixelRatio;
        for (final inset in [50.0, 0.0]) {
          tester.view.viewInsets = FakeViewPadding(bottom: inset * ratio);
          tester.view.padding =
              FakeViewPadding(bottom: inset > 0 ? 0 : 24 * ratio);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await page.settle();
        expect(find.byKey(const ValueKey('terminal-tab-strip')), findsOneWidget,
            reason: '键盘收起后标签条回来');
        expect(tester.state(find.byType(engineView)), same(engineState),
            reason: '标签条出现、多出来的空白消失在同一帧：终端不能被当成新的重建');
        expect(tester.testTextInput.isVisible, isFalse);
      });

      testWidgets('横屏点进大输入框：框换成一行的摆法时还是同一个框，系统键盘照样弹出来', (tester) async {
        final page = await _Page.open(tester, newTerminal);
        // 模拟器横屏时终端页只有 290dp 左右高（上面状态栏、下面导航栏）。
        tester.view.physicalSize = const Size(2400, 760);
        await page.settle();
        await tester.tap(toggle);
        await page.settle();
        tester.testTextInput.hide();

        await tester
            .tap(find.byKey(const ValueKey('terminal-input-tab-compose')));
        // 这一帧框先按多行摆出来，焦点在这一帧画完才给它；拿到焦点后地方不够，换成一行的摆法。
        await tester.pump();
        final before = tester.state(find.byType(EditableText));
        await page.settle();
        expect(
            find.byKey(const ValueKey('terminal-compose-more')), findsOneWidget,
            reason: '横屏地方小，框只留一行');
        expect(tester.state(find.byType(EditableText)), same(before),
            reason: '换摆法不换框');
        expect(tester.testTextInput.isVisible, isTrue);
      });

      testWidgets('键盘比面板矮时换回系统键盘：空出来的是键盘的位置，远端只收到一次尺寸、就是最后的尺寸', (
        tester,
      ) async {
        final page = await _Page.open(tester, newTerminal);
        await page.keyboard(108);
        await page.keyboard(0);
        await tester.tap(toggle);
        await page.settle();
        page.resizes['first']!.clear();

        await tester
            .tap(find.byKey(const ValueKey('terminal-input-system-keyboard')));
        // 输入法过了 0.5 秒才升上来（模拟器上的回放输入法就这么慢），比「先别发尺寸」的 400ms 还晚。
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await page.keyboard(108);
        expect(page.resizes['first'], hasLength(1));
        expect(page.resizes['first']!.single.$2, page.first.terminal.viewRows);
        await page.keyboard(0);
      });

      testWidgets('竖屏在大输入框里打字、系统键盘弹着：框、提醒、按钮都在键盘上面看得见、点得到，不溢出', (
        tester,
      ) async {
        final page = await _Page.open(tester, newTerminal);
        await page.keyboard(336);
        await page.keyboard(0);
        await tester.tap(toggle);
        await page.settle();
        await tester
            .tap(find.byKey(const ValueKey('terminal-input-tab-compose')));
        await page.keyboard(336);
        final keyboardTop =
            tester.view.physicalSize.height / tester.view.devicePixelRatio -
                336;

        await tester.enterText(editor, 'touch a\ntouch b');
        await page.settle();
        expect(find.byKey(const ValueKey('terminal-compose-risk-lines-run')),
            findsOneWidget);
        for (final finder in [editor, send, fill]) {
          expect(tester.getRect(finder).bottom,
              lessThanOrEqualTo(keyboardTop + .5));
        }
        expect(
            tester.getSize(find.byType(engineView)).height, greaterThan(100));
        await tester.tap(send);
        await page.settle();
        expect(page.sent['first'], ['touch a\rtouch b', '\r']);
        await page.keyboard(0);
      });

      testWidgets('从面板换回系统键盘：键盘升上来之前面板的位置先空着，终端不会先变高再被压回去', (
        tester,
      ) async {
        final page = await _Page.open(tester, newTerminal);
        // 先让 App 见过一次系统键盘（336dp），面板照这个高度开。
        await page.keyboard(336);
        await page.keyboard(0);
        await tester.tap(toggle);
        await page.settle();
        final terminal = find.byType(engineView);
        final before = tester.getSize(terminal).height;

        await tester
            .tap(find.byKey(const ValueKey('terminal-input-system-keyboard')));
        var tallest = tester.getSize(terminal).height;
        for (var frame = 1; frame <= 10; frame++) {
          tester.view.viewInsets = FakeViewPadding(
              bottom: 336 * frame / 10 * tester.view.devicePixelRatio);
          await tester.pump(const Duration(milliseconds: 16));
          tallest = math.max(tallest, tester.getSize(terminal).height);
        }
        await page.settle();
        expect(tallest, lessThanOrEqualTo(before + 1));
        await page.keyboard(0);
      });

      testWidgets('横屏：面板开着标签条收起，终端不被挤成 0 行；大输入框弹着键盘时快捷键栏让出来、框只留一行', (
        tester,
      ) async {
        final page = await _Page.open(tester, newTerminal);
        tester.view.physicalSize = const Size(2400, 1080);
        await page.settle();
        await tester.tap(toggle);
        await page.settle();
        expect(find.byKey(const ValueKey('terminal-tab-strip')), findsNothing);
        expect(tester.getSize(find.byType(engineView)).height, greaterThan(48));

        await tester
            .tap(find.byKey(const ValueKey('terminal-input-tab-compose')));
        await page.settle();
        await page.keyboard(261);
        expect(
            find.byKey(const ValueKey('terminal-compose-more')), findsOneWidget,
            reason: '只留一行');
        expect(find.byKey(const ValueKey('terminal-special-keys-compact')),
            findsNothing);
        expect(tester.getSize(find.byType(engineView)).height, greaterThan(30));
        expect(page.first.terminal.viewRows, greaterThan(0));
        await page.keyboard(0);
      });

      testWidgets('每一页的键都整个露在面板里、不用滚：竖屏四行，横屏两行（键盘比面板矮也一样）', (
        tester,
      ) async {
        final page = await _Page.open(tester, newTerminal);
        // 只有 108dp 的键盘（盖住了导航栏的回放输入法就是这样）：面板照样放得下一页。
        await page.keyboard(108);
        await page.keyboard(0);
        await tester.tap(toggle);
        await page.settle();
        Future<void> expectAllVisible(String layout) async {
          final visible = tester.getRect(panel);
          for (final keyPage in ['common', 'symbols', 'control', 'function']) {
            await tester
                .tap(find.byKey(ValueKey('terminal-key-page-$keyPage')));
            await page.settle();
            final keys = find.descendant(
              of: find.byKey(ValueKey('terminal-key-grid-$keyPage')),
              matching: find.byType(TextButton),
            );
            expect(keys, findsWidgets);
            for (final key in keys.evaluate()) {
              final rect = tester.getRect(find.byWidget(key.widget));
              expect(rect.bottom, lessThanOrEqualTo(visible.bottom + .5),
                  reason: '$layout $keyPage：有键被挡在面板外');
            }
          }
          await tester
              .tap(find.byKey(const ValueKey('terminal-key-page-common')));
          await page.settle();
        }

        await expectAllVisible('竖屏');
        tester.view.physicalSize = const Size(2400, 1080);
        await page.settle();
        await expectAllVisible('横屏');
        final up = tester.getCenter(panelKey('↑'));
        final down = tester.getCenter(panelKey('↓'));
        expect(up.dx, moreOrLessEquals(down.dx, epsilon: 1));
        expect(down.dy, greaterThan(up.dy), reason: '横屏两行也是倒 T');
      });

      testWidgets('UX02：面板两页、竖屏横屏，触控目标 48dp、可点的都有标签、文字对比度够', (
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

        await tester.tap(toggle);
        await page.settle();
        await expectGuidelines('竖屏按键面板');
        for (final keyPage in ['symbols', 'control', 'function']) {
          await tester.tap(find.byKey(ValueKey('terminal-key-page-$keyPage')));
          await page.settle();
          await expectGuidelines('竖屏按键面板 $keyPage');
        }
        await tester
            .tap(find.byKey(const ValueKey('terminal-input-tab-compose')));
        await page.settle();
        await expectGuidelines('竖屏大输入框');
        tester.view.physicalSize = const Size(2400, 1080);
        await page.settle();
        await expectGuidelines('横屏大输入框');
        await tester.tap(find.byKey(const ValueKey('terminal-input-tab-keys')));
        await page.settle();
        await expectGuidelines('横屏按键面板');
        semantics.dispose();
      });
    });
  }
}

/// 两个标签的终端页，终端都绑着记录用的 sink（像连着一样），不建真连接。
class _Page {
  _Page(
    this.tester,
    this.controller,
    this.repository,
    this.first,
    this.second,
    this.sent,
    this.resizes,
  );

  final WidgetTester tester;
  final _SeededSessionController controller;
  final VaultRepository repository;
  final ActiveTerminalSession first;
  final ActiveTerminalSession second;
  final Map<String, List<String>> sent;
  final Map<String, List<(int, int)>> resizes;

  static Future<_Page> open(
    WidgetTester tester,
    TerminalSessionAdapterBase Function() newTerminal, {
    AppSettings? settings,
    bool navigationBar = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    if (settings != null) await repository.saveSettings(settings);
    final messenger = tester.binding.defaultBinaryMessenger;
    const pip = MethodChannel('app.netcatty.mobile/picture_in_picture');
    messenger.setMockMethodCallHandler(pip, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(pip, null));
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    // 见 terminal_input_routing_test.dart：flterm 的空闲任务遇上动画会让假时钟下的 pump 死循环。
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);

    final sent = <String, List<String>>{};
    final resizes = <String, List<(int, int)>>{};
    final terminals = <String, TerminalSessionAdapterBase>{};
    ActiveTerminalSession session(String id) {
      final terminal = newTerminal();
      addTearDown(terminal.dispose);
      terminals[id] = terminal;
      sent[id] = [];
      resizes[id] = [];
      terminal.bind(
        (Uint8List bytes) => sent[id]!.add(utf8.decode(bytes)),
        resize: (columns, rows, _, __) => resizes[id]!.add((columns, rows)),
      );
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
    container.read(homeTabProvider.notifier).state = 1;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: const TerminalScreen(),
          // 像 App 里那样底部有导航栏（HomeShell）：它把系统手势条的留白算在自己的高度里。
          bottomNavigationBar: navigationBar
              ? NavigationBar(destinations: const [
                  NavigationDestination(icon: Icon(Icons.dns), label: 'a'),
                  NavigationDestination(icon: Icon(Icons.terminal), label: 'b'),
                ])
              : null,
        ),
      ),
    ));
    final page = _Page(
      tester,
      container.read(sessionControllerProvider.notifier)
          as _SeededSessionController,
      repository,
      first,
      second,
      sent,
      resizes,
    );
    await page.settle();
    // 终端挂上时的协议回应（焦点事件之类）不算面板发的。
    for (final list in sent.values) {
      list.clear();
    }
    return page;
  }

  /// 隔开两次点按，免得被当成双击；等过尺寸的「先别发」（400ms）、换回系统键盘后给键盘留的位置（700ms）
  /// 和之后那次尺寸的合并（100ms）。
  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  }

  /// 系统键盘升到（或降到）[dp] 高：像真机一样分十帧动，再停稳。
  ///
  /// [gesturePadding]：手机底部系统手势条的留白（dp）。Android 上键盘一弹出来这截留白就报成 0（模拟器上量到的），
  /// 带着它模拟才看得出「键盘升降那几帧终端页反而变高」。
  Future<void> keyboard(double dp, {double gesturePadding = 0}) async {
    final ratio = tester.view.devicePixelRatio;
    final from = tester.view.viewInsets.bottom / ratio;
    for (var frame = 1; frame <= 10; frame++) {
      final value = from + (dp - from) * frame / 10;
      tester.view.viewInsets = FakeViewPadding(bottom: value * ratio);
      tester.view.padding =
          FakeViewPadding(bottom: value > 0 ? 0 : gesturePadding * ratio);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settle();
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

  /// 像网络断了一样：连接还在列表里，但标成断开。
  void markDisconnected(String id) {
    final session = state.sessions.firstWhere((s) => s.id == id);
    session.connected = false;
    state = state.copyWith(sessions: [...state.sessions]);
  }

  /// 像断线后自动恢复一样：同一个标签、同一个终端，换成一个新的连接对象。
  ActiveTerminalSession restore(String id) {
    final old = state.sessions.firstWhere((s) => s.id == id);
    final restored = ActiveTerminalSession(
      id: old.id,
      host: old.host,
      terminal: old.terminal,
      verifyHostKey: old.verifyHostKey,
      keyboardInteractive: null,
    );
    state = state.copyWith(sessions: [
      for (final session in state.sessions)
        if (session.id == id) restored else session,
    ]);
    return restored;
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
