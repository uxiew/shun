import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:shun/presentation/terminal/terminal_view.dart';

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
        reason: '终端自动拿焦点（R19 时 xterm2 的视图只在有焦点时替远端读写剪贴板，有焦点才测得出）',
      );
      sent.clear();

      terminal.feed(Uint8List.fromList(utf8.encode(
        '\x1b]52;c;${base64.encode(utf8.encode('rm -rf ~'))}\x07' // 写剪贴板
        '\x1b]52;c;?\x07' // 读剪贴板
        '\x1b]52;p;?\x1b\\' // 读 primary 选区，ST 结尾
        'visible',
      )));
      // 读剪贴板可能是异步的（R19 时 xterm2 就是）：等它可能的应答回来。
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(clipboardCalls, isEmpty, reason: '远端不能读写手机剪贴板');
      expect(sent.join(), isNot(contains('52;')), reason: '剪贴板查询不能被应答');
      expect(terminal.allText(), contains('visible'));
    });

    testWidgets('$engine：恶意标题、目录、通知、链接、图像、标题回报：不执行本地动作，不把标题回给远端', (
      tester,
    ) async {
      final platformCalls = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call.method);
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
      sent.clear();
      platformCalls.clear();

      terminal.feed(Uint8List.fromList(utf8.encode(
        // 标题里塞命令和换行，再要求终端把标题报回来（经典的「标题回显」注入）。
        '\x1b]2;rm -rf ~\r\n\x07\x1b]1;icon\r\n\x07\x1b[21t\x1b[20t'
        '\x1b]7;file://evil.example/etc\x07' // 工作目录
        '\x1b]9;pwned\x07\x1b]777;notify;title;body\x07' // 桌面通知
        '\x1b]9;4;1;50\x07' // 进度
        '\x1b]8;;intent://x#Intent;end\x07tap\x1b]8;;\x07' // 链接（不点不该有任何动作）
        '\x1b]1337;File=inline=1:AAAA\x07' // iTerm2 图像
        '\x1b_Gf=24,s=1,v=1,a=T;AAAA\x1b\\' // Kitty 图像
        '\x1bPq#0;2;0;0;0#0~~@@vv@@~~\x1b\\' // Sixel
        '\x1b]1337;SetUserVar=x=eA==\x07'
        'after',
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final reply = sent.join();
      expect(reply, isNot(contains('rm -rf')), reason: '标题不能回给远端，否则成了远端替用户打的字');
      expect(reply, isNot(contains('icon')));
      expect(platformCalls, isNot(contains('Clipboard.setData')));
      expect(
        platformCalls.where((m) => !m.startsWith('TextInput.')),
        isEmpty,
        reason: '没有通知、打开链接之类的平台调用',
      );
      expect(terminal.allText(), contains('after'));
    });

    test('$engine：超长的不结束序列（剪贴板、DCS、标题各 16 MiB）内存有界，之后照常显示', () {
      final terminal = newTerminal();
      addTearDown(terminal.dispose);
      terminal.bind((_) {});
      final chunk = Uint8List.fromList(utf8.encode('A' * 65536));
      final before = ProcessInfo.currentRss;
      final watch = Stopwatch()..start();
      for (final opener in ['\x1b]52;c;', '\x1bP1;1|', '\x1b]2;']) {
        terminal.feed(Uint8List.fromList(utf8.encode(opener)));
        for (var i = 0; i < 256; i++) {
          terminal.feed(chunk); // 16 MiB
        }
        terminal.feed(Uint8List.fromList(utf8.encode('\x07\x1b\\\r\n')));
      }
      terminal.feed(Uint8List.fromList(utf8.encode('still-here\r\n')));
      watch.stop();
      final grown = ProcessInfo.currentRss - before;
      // ignore: avoid_print
      print(
          'R19 $engine 48MiB 不结束序列：${watch.elapsedMilliseconds} ms，RSS +${grown >> 20} MiB');
      expect(terminal.allText(), contains('still-here'));
      expect(grown, lessThan(64 << 20), reason: '不随远端发来的字节数涨');
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
    });
  }
}
