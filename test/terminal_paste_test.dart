import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';

// R19 / GST04：粘贴、普通文字、功能键三条路各发什么。两个引擎各跑一遍。
// 这里核对的「清洗」只是引擎替远端挡掉一部分控制字节，不代表远端不会执行粘贴的内容：
// 没开 bracketed paste 时换行就是回车，见下面「没开 2004」那条。

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  final engines = <String, TerminalSessionAdapterBase Function()>{
    'Ghostty': GhosttyTerminalAdapter.new,
    'xterm2': XtermTerminalAdapter.new,
  };

  for (final MapEntry(key: engine, value: newTerminal) in engines.entries) {
    group(engine, () {
      late TerminalSessionAdapterBase terminal;
      late StringBuffer sent;

      setUp(() {
        terminal = newTerminal();
        sent = StringBuffer();
        terminal.bind((bytes) => sent.write(utf8.decode(bytes)));
      });
      tearDown(() => terminal.dispose());

      test('sendText 是打字：换行原样发，就是按了回车', () {
        terminal.sendText('ls\n');
        expect(sent.toString(), 'ls\n');
      });

      test('没开 2004：粘贴里的换行变成回车（CR），前面的行会被执行；末尾不追加回车', () {
        expect(terminal.bracketedPasteMode, isFalse);
        terminal.paste('echo 1\necho 2');
        expect(sent.toString(), 'echo 1\recho 2');
      });

      test('开了 2004：整段包进粘贴标记，末尾不追加回车', () {
        terminal.feed(_bytes('\x1b[?2004h'));
        expect(terminal.bracketedPasteMode, isTrue);
        terminal.paste('echo 1\necho 2');
        final out = sent.toString();
        expect(out, startsWith('\x1b[200~echo 1'));
        expect(out, endsWith('echo 2\x1b[201~'));
        expect(out, isNot(contains('\r')));

        terminal.feed(_bytes('\x1b[?2004l'));
        expect(terminal.bracketedPasteMode, isFalse);
      });

      test('粘贴里伪造的结束标记、Ctrl-C、Ctrl-D 被引擎挡掉（只是清洗，不是不执行的保证）', () {
        terminal.feed(_bytes('\x1b[?2004h'));
        terminal.paste('a\x1b[201~b\x03c\x04d');
        final out = sent.toString();
        expect(
          '\x1b[201~'.allMatches(out).length,
          1,
          reason: '只剩真正的结束标记，内容里那个提前结束不了粘贴',
        );
        expect(out, isNot(contains('\x03')));
        expect(out, isNot(contains('\x04')));
      });

      test('快捷键栏亮着 Ctrl 时粘贴：不把第一个字变成控制键，Ctrl 被清掉', () {
        terminal.input.setModifiers({'ctrl'});
        terminal.paste('c');
        expect(sent.toString(), 'c');
        expect(terminal.input.modifiers, isEmpty);
        terminal.sendText('c');
        expect(sent.toString(), 'cc', reason: '清掉以后下一个键也不再是 Ctrl');
      });

      test('功能键照远端键盘模式编码，和粘贴互不影响', () {
        terminal.feed(_bytes('\x1b[?1h\x1b[?2004h'));
        terminal.sendKey(TerminalSpecialKey.arrowUp);
        terminal.paste('x');
        expect(sent.toString(), '\x1bOA\x1b[200~x\x1b[201~');
      });

      test('空文字、释放后粘贴都不发、不抛错', () {
        terminal.paste('');
        terminal.dispose();
        terminal.paste('late');
        expect(sent.toString(), isEmpty);
        expect(terminal.bracketedPasteMode, isFalse);
      });

      test('旧代次收不到粘贴', () {
        final old = StringBuffer();
        final binding = terminal.bind((bytes) => old.write(utf8.decode(bytes)));
        terminal.bind((bytes) => sent.write(utf8.decode(bytes)));
        terminal.paste('new');
        expect(binding.isActive, isFalse);
        expect(old.toString(), isEmpty);
        expect(sent.toString(), 'new');
      });
    });
  }
}
