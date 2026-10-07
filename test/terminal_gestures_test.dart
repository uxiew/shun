import 'dart:convert';

import 'package:flterm/flterm.dart' as flterm show TerminalView;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:netcatty_mobile/presentation/terminal/terminal_view.dart';
import 'package:xterm2/xterm.dart' as xterm show TerminalView;

// R19 / TER07：手指在终端上滑、点、长按，远端收到什么。两个引擎各跑一遍。
// 规矩：滑动在普通 shell 里翻本地滚动区；全屏程序没开鼠标报告时什么都不发（不变成方向键）；
// 开了鼠标报告（tmux mouse on）只发滚轮。点按、长按永远不发东西。
// 10-07 加了设置「全屏程序里滑动翻页」（默认关）：开了以后全屏程序没开鼠标报告时滑动发 ↑/↓。

const _options = TerminalViewOptions(
  fontSize: 14,
  secureKeyboard: false,
  interactive: true,
  transparentBackground: false,
);

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// SGR 鼠标报告里的按钮码：0 左键按下，64/65 滚轮上/下。
List<int> _sgrButtons(String sent) => [
      for (final m in RegExp(r'\x1b\[<(\d+);\d+;\d+[Mm]').allMatches(sent))
        int.parse(m.group(1)!),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final engines = <String, TerminalSessionAdapterBase Function()>{
    'Ghostty': GhosttyTerminalAdapter.new,
    'xterm2': XtermTerminalAdapter.new,
  };

  for (final MapEntry(key: engine, value: newTerminal) in engines.entries) {
    group(engine, () {
      late TerminalSessionAdapterBase terminal;
      late StringBuffer sent;
      final engineView =
          engine == 'Ghostty' ? flterm.TerminalView : xterm.TerminalView;

      Future<void> mount(
        WidgetTester tester, {
        TerminalViewOptions options = _options,
      }) async {
        tester.view.physicalSize = const Size(1080, 1800);
        tester.view.devicePixelRatio = 2.625;
        addTearDown(tester.view.reset);
        // 见 terminal_input_routing_test.dart：flterm 的空闲任务遇上动画会让假时钟下的 pump 死循环。
        final strategy = tester.binding.schedulingStrategy;
        tester.binding.schedulingStrategy = (
                {required int priority, required SchedulerBinding scheduler}) =>
            true;
        addTearDown(() => tester.binding.schedulingStrategy = strategy);
        terminal = newTerminal();
        addTearDown(terminal.dispose);
        sent = StringBuffer();
        terminal.bind((bytes) => sent.write(latin1.decode(bytes)));
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: terminalViewFor(terminal, options)),
        ));
        await tester.pump();
        // 挂上时的协议回应（焦点事件之类）不算手势发的。
        sent.clear();
      }

      const swipeOptions = TerminalViewOptions(
        fontSize: 14,
        secureKeyboard: false,
        interactive: true,
        transparentBackground: false,
        fullscreenSwipe: true,
      );

      /// 远端收到的方向键：↑ 和 ↓ 各几个。光标键模式下是 ESC O A，平时是 ESC [ A，两种都数。
      ({int up, int down, String rest}) arrows(String text) {
        final up = RegExp(r'\x1b[\[O]A').allMatches(text).length;
        final down = RegExp(r'\x1b[\[O]B').allMatches(text).length;
        return (
          up: up,
          down: down,
          rest: text.replaceAll(RegExp(r'\x1b[\[O][AB]'), ''),
        );
      }

      Future<void> settle(WidgetTester tester) async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> swipe(WidgetTester tester, double dy) async {
        await tester.timedDrag(
          find.byType(engineView),
          Offset(0, dy),
          const Duration(milliseconds: 300),
        );
        await settle(tester);
      }

      Future<void> longPress(WidgetTester tester) async {
        final center = tester.getCenter(find.byType(engineView));
        final gesture = await tester.startGesture(
          center.translate(-100, -200),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        await gesture.moveBy(const Offset(60, 0));
        await tester.pump(const Duration(milliseconds: 50));
        await gesture.up();
        await settle(tester);
      }

      testWidgets('普通 shell：滑动翻本地滚动区，不发任何字节', (tester) async {
        await mount(tester);
        terminal.feed(
            _bytes([for (var i = 1; i <= 300; i++) 'line $i'].join('\r\n')));
        await settle(tester);

        double scrolled() => engine == 'Ghostty'
            ? (terminal as GhosttyTerminalAdapter)
                .controller
                .scrollbar
                .offset
                .toDouble()
            : tester
                .state<ScrollableState>(find
                    .descendant(
                      of: find.byType(engineView),
                      matching: find.byType(Scrollable),
                    )
                    .first)
                .position
                .pixels;
        final before = scrolled();
        await swipe(tester, 400); // 手指往下拉 = 往回看历史
        expect(scrolled(), lessThan(before), reason: '视口往上翻了');
        expect(sent.toString(), isEmpty);
      });

      testWidgets('全屏程序没开鼠标报告（tmux 没开 mouse、less、vim）：滑动不变成方向键，什么都不发', (
        tester,
      ) async {
        await mount(tester);
        terminal.feed(_bytes('\x1b[?1049h\x1b[Hfull screen app'));
        await settle(tester);
        expect(terminal.isAlternateScreen, isTrue);

        await swipe(tester, -400);
        await swipe(tester, 400);
        expect(sent.toString(), isEmpty);
      });

      testWidgets('开着鼠标报告（tmux mouse on）：滑动只发滚轮；点按、长按不发点击', (tester) async {
        await mount(tester);
        // tmux 开 mouse 后发的就是这几个：备用屏、按钮事件跟踪、SGR 编码。
        terminal.feed(_bytes('\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h'
            '\x1b[Htmux pane text'));
        await settle(tester);

        await swipe(tester, 400); // 往回看：滚轮上
        await swipe(tester, -400); // 滚轮下
        final wheel = _sgrButtons(sent.toString());
        expect(wheel, containsAll([64, 65]));
        expect(wheel.toSet(), {64, 65}, reason: '只有滚轮，没有按下/松开');
        sent.clear();

        await tester.tapAt(tester.getCenter(find.byType(engineView)));
        await tester.pump(kDoubleTapTimeout);
        await settle(tester);
        expect(sent.toString(), isEmpty, reason: '点按是叫键盘，不是点 tmux 的窗格');

        await longPress(tester);
        expect(sent.toString(), isEmpty, reason: '长按是选字，不发给程序');
      });

      testWidgets('设置开了「全屏程序里滑动翻页」：全屏程序没开鼠标时，手指往下拉发 ↑、往上推发 ↓，没有别的字节', (
        tester,
      ) async {
        await mount(tester, options: swipeOptions);
        terminal.feed(_bytes('\x1b[?1049h\x1b[Hless'));
        await settle(tester);

        await swipe(tester, 400); // 往回看 = ↑
        final back = arrows(sent.toString());
        sent.clear();
        await swipe(tester, -400);
        final forward = arrows(sent.toString());

        expect(back.up, greaterThan(3), reason: '每滑过一行一个');
        expect(back.down, 0);
        expect(forward.down, greaterThan(3));
        expect(forward.up, 0);
        expect(back.rest + forward.rest, isEmpty);
      });

      testWidgets('设置开着：开着鼠标报告的程序照样只发滚轮；普通 shell 照样翻本地历史', (tester) async {
        await mount(tester, options: swipeOptions);
        terminal.feed(
            _bytes([for (var i = 1; i <= 300; i++) 'line $i'].join('\r\n')));
        await settle(tester);
        await swipe(tester, 400);
        expect(sent.toString(), isEmpty, reason: '主屏不发');

        terminal.feed(_bytes('\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[Htmux'));
        await settle(tester);
        await swipe(tester, 400);
        expect(_sgrButtons(sent.toString()).toSet(), {64});
        expect(arrows(sent.toString()).up, 0, reason: '开着鼠标时不发方向键');
      });

      testWidgets('开着的终端改设置马上生效；退出全屏程序再进来仍然有效', (tester) async {
        await mount(tester);
        terminal.feed(_bytes('\x1b[?1049h\x1b[Hless'));
        await settle(tester);
        await swipe(tester, 400);
        expect(sent.toString(), isEmpty, reason: '默认关');

        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: terminalViewFor(terminal, swipeOptions)),
        ));
        await settle(tester);
        sent.clear();
        await swipe(tester, 400);
        expect(arrows(sent.toString()).up, greaterThan(3));

        // 退出 less 再开一次：Ghostty 回主屏时按配置重设模式，只改当前模式的话这里就又不发了。
        terminal.feed(_bytes('\x1b[?1049l'));
        await settle(tester);
        terminal.feed(_bytes('\x1b[?1049h\x1b[Hless again'));
        await settle(tester);
        sent.clear();
        await swipe(tester, 400);
        expect(arrows(sent.toString()).up, greaterThan(3));

        // 再关掉：回到什么都不发。
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: terminalViewFor(terminal, _options)),
        ));
        await settle(tester);
        sent.clear();
        await swipe(tester, 400);
        expect(sent.toString(), isEmpty);
      });
    });
  }
}
