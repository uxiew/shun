import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:netcatty_mobile/presentation/terminal/terminal_view.dart';

// R19 / SEC08、SEC09：远端输出是不可信数据。适配器上不接效果回调还不够——
// 视图挂上、拿到焦点以后，引擎自己的视图会不会替它接上？这里两个引擎都挂上真视图、拿着焦点再喂。

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
    testWidgets('$engine：视图挂着、有焦点时，OSC 52 读不走也写不进剪贴板，不回任何字节', (tester) async {
      final clipboardCalls = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method.startsWith('Clipboard.')) {
          clipboardCalls.add(call.method);
          if (call.method == 'Clipboard.getData') {
            return {'text': 'phone-secret'};
          }
        }
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      final terminal = newTerminal();
      addTearDown(terminal.dispose);
      final sent = <String>[];
      terminal.bind((bytes) => sent.add(latin1.decode(bytes)));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: terminalViewFor(terminal, _options)),
      ));
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.context,
        isNotNull,
        reason: '终端自动拿焦点（xterm2 的视图只在有焦点时替远端读写剪贴板）',
      );
      sent.clear();

      terminal.feed(Uint8List.fromList(utf8.encode(
        '\x1b]52;c;${base64.encode(utf8.encode('rm -rf ~'))}\x07' // 写剪贴板
        '\x1b]52;c;?\x07' // 读剪贴板
        '\x1b]52;p;?\x1b\\' // 读 primary 选区，ST 结尾
        'visible',
      )));
      // xterm2 读剪贴板是异步的：等它可能的应答回来。
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(clipboardCalls, isEmpty, reason: '远端不能读写手机剪贴板');
      expect(sent.join(), isNot(contains('52;')), reason: '剪贴板查询不能被应答');
      expect(terminal.allText(), contains('visible'));
    });
  }
}
