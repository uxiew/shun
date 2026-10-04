import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';

// R18：快捷键栏的功能键交给引擎编码（跟远端的光标键模式走）。两个引擎各跑一遍。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final engines = <String, TerminalSessionAdapterBase Function()>{
    'Ghostty': GhosttyTerminalAdapter.new,
    'xterm2': XtermTerminalAdapter.new,
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

      test('释放后按键不碰引擎、不抛错', () {
        terminal.dispose();
        terminal.sendKey(TerminalSpecialKey.arrowUp);
        expect(sent, isEmpty);
      });
    });
  }
}
