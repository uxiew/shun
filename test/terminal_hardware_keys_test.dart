import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:netcatty_mobile/presentation/terminal/terminal_view.dart';

// 所有者 10-07 定（R19 留下的第二项）：硬件键盘 Ctrl+K、Ctrl+A 发给服务器（nano 剪切一行、readline 回行首、
// tmux/screen 的前缀键）；App 自己的清滚动区、全选挪到 Ctrl+Shift+K、Ctrl+Shift+A。两个引擎各跑一遍。
// 这里用 Flutter 的模拟按键，设备上的真实扫描码见 integration_test/r18_keys_test.dart。

const _options = TerminalViewOptions(
  fontSize: 14,
  secureKeyboard: false,
  interactive: true,
  transparentBackground: false,
);

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

      Future<void> mount(WidgetTester tester) async {
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
        terminal.feed(Uint8List.fromList(utf8.encode(
          [for (var i = 1; i <= 300; i++) 'line $i'].join('\r\n'),
        )));
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: terminalViewFor(terminal, _options)),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        sent.clear();
      }

      Future<void> press(
        WidgetTester tester,
        LogicalKeyboardKey key, {
        bool shift = false,
      }) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(key);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump(const Duration(milliseconds: 50));
      }

      int historyLines() => engine == 'Ghostty'
          ? (terminal as GhosttyTerminalAdapter).controller.scrollbackRows
          : (terminal as XtermTerminalAdapter).terminal.buffer.scrollBack;

      testWidgets('Ctrl+K、Ctrl+A 发给服务器（0x0b、0x01），本地什么都不动', (tester) async {
        await mount(tester);
        final before = historyLines();

        await press(tester, LogicalKeyboardKey.keyK);
        await press(tester, LogicalKeyboardKey.keyA);

        expect(sent.toString(), '\x0b\x01');
        expect(historyLines(), before, reason: 'Ctrl+K 不再清本地历史');
      });

      testWidgets('Ctrl+Shift+K 清本地历史；Ghostty 顺带发一个 Ctrl+L 让 shell 重画提示符', (
        tester,
      ) async {
        await mount(tester);
        expect(historyLines(), greaterThan(200));

        await press(tester, LogicalKeyboardKey.keyK, shift: true);

        expect(historyLines(), 0);
        expect(sent.toString(), engine == 'Ghostty' ? '\x0c' : '');
      });

      testWidgets('Ctrl+Shift+A 全选本地的字，不发给服务器', (tester) async {
        await mount(tester);

        await press(tester, LogicalKeyboardKey.keyA, shift: true);
        await tester.pump(const Duration(milliseconds: 100));

        expect(sent.toString(), isEmpty);
        expect(find.byKey(const ValueKey('copy-terminal-selection')),
            findsOneWidget,
            reason: '有选区时右上角出「复制」');
      });

      testWidgets('全屏程序里 Ctrl+Shift+K 什么都不做', (tester) async {
        await mount(tester);
        terminal.feed(Uint8List.fromList(utf8.encode('\x1b[?1049h\x1b[Hvim')));
        await tester.pump(const Duration(milliseconds: 100));
        sent.clear();

        await press(tester, LogicalKeyboardKey.keyK, shift: true);

        expect(sent.toString(), isEmpty);
      });

      // 「顺带看看别的 Ctrl+字母有没有被本地吃掉」：26 个挨个按，Ctrl+V 是 App 的粘贴（先预览，R19），不在这里按。
      testWidgets('没有选区时，除 Ctrl+V 以外的 Ctrl+字母都发给服务器', (tester) async {
        await mount(tester);
        final eaten = <String>[];
        final other = <String, String>{};
        for (var code = 0x61; code <= 0x7a; code++) {
          final letter = String.fromCharCode(code);
          if (letter == 'v') continue;
          sent.clear();
          await press(tester, LogicalKeyboardKey(code));
          final name = 'Ctrl+${letter.toUpperCase()}';
          if (sent.isEmpty) {
            eaten.add(name);
          } else if (sent.toString() != String.fromCharCode(code - 0x60)) {
            other[name] = sent.toString();
          }
        }
        expect(eaten, isEmpty, reason: '没有被本地吃掉的');
        // 这里模拟的按键事件，Ghostty 把和 Tab、回车同码的 Ctrl+I、Ctrl+M 编成 CSI u（「fixterms」写法）。
        // 注意：模拟器上真的硬件按键这两个什么都不发（integration_test/r18_keys_test.dart，10-07），设备上的按键事件
        // 和这里模拟的不一样，以设备为准。这里只记下模拟事件下的样子，免得它悄悄变了没人知道。
        expect(
          other,
          engine == 'Ghostty'
              ? {'Ctrl+I': '\x1b[105;5u', 'Ctrl+M': '\x1b[109;5u'}
              : isEmpty,
          reason: jsonEncode(other),
        );
      });

      testWidgets('有选区时：Ghostty 的 Ctrl+C 是复制（不发 ^C），xterm2 照发', (tester) async {
        await mount(tester);
        await press(tester, LogicalKeyboardKey.keyA, shift: true);
        await tester.pump(const Duration(milliseconds: 100));
        sent.clear();

        await press(tester, LogicalKeyboardKey.keyC);

        // flterm 在 Android 上照 Windows 终端的习惯：有选区时 Ctrl+C 复制、没选区才发 ^C。没改，记在使用手册里。
        expect(sent.toString(), engine == 'Ghostty' ? '' : '\x03');
      });
    });
  }
}
