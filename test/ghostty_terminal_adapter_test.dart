import 'dart:convert';
import 'dart:io';

import 'package:flterm/flterm.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';

// R17：Ghostty 适配器。本机加载 fork 从源码编的 Ghostty 原生库，测的是真引擎，不是假对象。

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

class _Sink {
  final sent = <String>[];
  void input(Uint8List bytes) => sent.add(utf8.decode(bytes));
}

GhosttyTerminalAdapter _terminal() {
  final terminal = GhosttyTerminalAdapter();
  addTearDown(terminal.dispose);
  return terminal;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('先接回调再喂数据；代次（GST03、NET09）', () {
    test('远端的查询一到就有应答，只交给当前代次', () {
      final terminal = _terminal();
      final old = _Sink();
      final current = _Sink();
      final oldBinding = terminal.bind(old.input);
      terminal.feed(_bytes('\x1b[6n')); // 光标位置查询
      terminal.bind(current.input);
      terminal.feed(_bytes('\x1b[c')); // DA 查询
      terminal.sendText('after');

      expect(old.sent, ['\x1b[1;1R']);
      expect(current.sent, hasLength(2));
      expect(current.sent.first, startsWith('\x1b[?'));
      expect(current.sent.last, 'after');
      expect(oldBinding.isActive, isFalse);
    });

    test('回调里再喂数据不重入：排队等这次写完，顺序不乱', () {
      final terminal = _terminal();
      var replies = 0;
      terminal.bind((bytes) {
        // 最坏的调用方：收到应答就同步再喂一段。
        if (replies++ == 0) terminal.feed(_bytes('X'));
      });

      terminal.feed(_bytes('a\x1b[cb'));

      expect(replies, 1);
      expect(terminal.recentLines(24).first.text, 'abX');
    });

    test('旧连接断在没写完的控制序列里，新代次的输出照常显示', () {
      final terminal = _terminal();
      terminal.bind(_Sink().input);
      // 设标题的 OSC 没等到结束符连接就断了。不打断的话，之后的字节全被当成标题吞掉。
      terminal.feed(_bytes('before\r\n\x1b]0;half a title'));
      terminal.bind(_Sink().input); // 恢复
      terminal.feed(_bytes('fresh shell'));

      final text = terminal.allText();
      expect(text, contains('before'));
      expect(text, contains('fresh shell'));
    });

    test('没喂过数据就换代次，不往画面里塞任何东西', () {
      final terminal = _terminal();
      terminal.bind(_Sink().input);
      terminal.bind(_Sink().input);
      terminal.feed(_bytes('hello'));
      expect(terminal.recentLines(24).first.text, 'hello');
    });
  });

  group('释放（GST02、SEC09）', () {
    test('释放后迟到的字节、按键、提示都忽略，读接口返回空，不碰原生对象', () {
      final terminal = GhosttyTerminalAdapter();
      final sink = _Sink();
      final binding = terminal.bind(sink.input);
      terminal.feed(_bytes('content'));
      terminal.dispose();
      terminal.dispose();

      terminal.feed(_bytes('late \x1b[c'));
      terminal.sendText('late input');
      terminal.showNotice('late notice');
      expect(sink.sent, isEmpty);
      expect(binding.isActive, isFalse);
      expect(terminal.engineReleased, isTrue);
      expect(terminal.recentLines(10), isEmpty);
      expect(terminal.allText(), isEmpty);
      expect(terminal.isAlternateScreen, isFalse);
      expect(terminal.viewRows, 0);
      expect(() => terminal.bind(sink.input), throwsStateError);
      expect(terminal.attachView, throwsStateError);
    });

    test('flterm 视图还挂着时只做标记，视图卸下后才释放原生控制器', () async {
      final terminal = GhosttyTerminalAdapter();
      final view = Object();
      var notified = 0;
      terminal.addListener(() => notified++);
      terminal.retainEngineView(view);

      terminal.dispose();
      expect(terminal.isDisposed, isTrue);
      expect(terminal.engineReleased, isFalse, reason: '视图这一帧还可能画');
      expect(notified, greaterThan(0), reason: '通知视图重建、把 flterm 视图卸下');

      terminal.releaseEngineView(Object()); // 别的视图卸下，不算
      await Future<void>.delayed(Duration.zero);
      expect(terminal.engineReleased, isFalse);

      terminal.releaseEngineView(view);
      expect(terminal.engineReleased, isFalse, reason: '卸下这一刻 flterm 视图可能还没解绑');
      await Future<void>.delayed(Duration.zero);
      expect(terminal.engineReleased, isTrue);
    });

    test('卸下后同一轮里又挂回去（换父组件），不释放', () async {
      final terminal = GhosttyTerminalAdapter();
      final view = Object();
      terminal.retainEngineView(view);
      terminal.dispose();
      terminal.releaseEngineView(view);
      terminal.retainEngineView(view);
      await Future<void>.delayed(Duration.zero);
      expect(terminal.engineReleased, isFalse);
      terminal.releaseEngineView(view);
      await Future<void>.delayed(Duration.zero);
      expect(terminal.engineReleased, isTrue);
    });

    test('新视图拿到显示权时通知旧视图让路', () {
      final terminal = _terminal();
      final first = Object();
      terminal.attachView();
      terminal.retainEngineView(first);
      var notified = 0;
      terminal.addListener(() => notified++);

      terminal.attachView();

      expect(notified, 1);
      expect(terminal.engineViewHeldByOther(Object()), isTrue);
      expect(terminal.engineViewHeldByOther(first), isFalse);
    });
  });

  group('远端转义序列不能让终端越权（SEC09）', () {
    test('剪贴板读写、链接、通知、进度、工作目录：一个都不执行，也不回任何字节', () {
      final terminal = _terminal();
      final platformCalls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final sink = _Sink();
      terminal.bind(sink.input);

      terminal.feed(_bytes(
        '\x1b]52;c;${base64.encode(utf8.encode('rm -rf ~'))}\x07' // 写剪贴板
        '\x1b]52;c;?\x07' // 读剪贴板
        '\x1b]8;;https://evil.example/\x07link\x1b]8;;\x07' // 超链接
        '\x1b]9;pwned\x07\x1b]777;notify;t;b\x07' // 通知
        '\x1b]9;4;1;50\x07' // 进度
        '\x1b]7;file://host/etc\x07' // 工作目录
        'visible',
      ));

      expect(sink.sent, isEmpty, reason: '剪贴板查询不能被应答，否则远端能读走剪贴板');
      expect(platformCalls, isEmpty);
      expect(terminal.allText(), contains('visible'));
    });

    test('超长控制序列不卡死、不崩，之后的正常输出照常显示', () {
      final terminal = _terminal();
      terminal.bind(_Sink().input);
      final watch = Stopwatch()..start();
      terminal.feed(_bytes('\x1b]0;'));
      final chunk = _bytes('A' * 16384);
      for (var i = 0; i < 64; i++) {
        terminal.feed(chunk); // 1 MiB 不结束的 OSC
      }
      terminal.feed(_bytes('\x07after-osc\r\n'));
      terminal.feed(_bytes('\x1b[${List.filled(100000, '1').join(';')}m'));
      terminal.feed(_bytes('after-csi\r\n'));
      // Kitty 图像：上限设成 0，整段丢掉，不占内存。
      terminal.feed(_bytes('\x1b_Ga=T,f=24,s=1,v=1;AAAA\x1b\\after-apc'));
      watch.stop();

      final text = terminal.allText();
      expect(text, contains('after-osc'));
      expect(text, contains('after-csi'));
      expect(text, contains('after-apc'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('资源上限（docs/06 预算，R04 问题 7）', () {
    test('配置：滚动区约 5000 行，不收图像和 APC 数据', () {
      final config = _terminal().controller.config;
      expect(config.scrollbackMaxLines, 5000);
      expect(config.scrollbackMaxBytes, 8 * 1024 * 1024);
      expect(config.kittyImageStorageLimit, 0);
      expect(config.apcBufferLimit, 0);
    });

    test('终端模式：只有「备用屏里滚动翻译成方向键」（1007）和 flterm 默认不同（R19）', () {
      final modes = ghosttyTerminalConfig.modes;
      expect(modes[const TerminalMode.alternateScroll()], isFalse);
      expect(
        {...modes}..remove(const TerminalMode.alternateScroll()),
        {...TerminalConfig.defaultModes}
          ..remove(const TerminalMode.alternateScroll()),
        reason: '同步上游后 flterm 的默认模式变了，照着改 ghosttyTerminalConfig',
      );
    });

    test('写两万行以后滚动区按上限回收，最新的行都在', () {
      final terminal = _terminal();
      final lines = StringBuffer();
      for (var i = 0; i < 20000; i++) {
        lines.write('line $i\r\n');
      }
      terminal.feed(_bytes(lines.toString()));

      final kept = terminal.recentLines(1 << 20);
      // 超过 5000 行就整页回收：留下的在「5000 减一页」到 5000 之间（加上 24 行屏幕），不会一直涨。
      expect(kept.length, inInclusiveRange(4000, 5000 + 24));
      expect(
        kept.where((line) => line.text.isNotEmpty).last.text,
        'line 19999',
      );
    });
  });

  // LIFE06（引擎部分）：建、写、读、释放（含「视图还挂着时释放」那条推迟的路），一轮轮做下去
  // 原生内存不能逐轮涨。对照实测：100 个终端各写 95 KB 不释放，RSS 涨 209.5 MiB（约 2.1 MiB 一个）；
  // 正常释放 1000 轮只涨约 2 MiB。所以 300 轮涨不过 32 MiB，就说明没有一轮漏掉一个终端。
  test('LIFE06 300 轮建、写、读、释放，RSS 不逐轮增长', () async {
    final chunk = _bytes(List.generate(
      3000,
      (i) => '\x1b[3${i % 8}mline $i 中文 🙂\x1b[0m',
    ).join('\r\n'));
    Future<void> cycle(int i) async {
      final terminal = GhosttyTerminalAdapter();
      terminal.bind((_) {});
      final view = Object();
      if (i.isEven) terminal.retainEngineView(view);
      terminal.feed(chunk);
      terminal.recentLines(200);
      terminal.allText();
      terminal.dispose();
      if (i.isEven) terminal.releaseEngineView(view);
      await Future<void>.delayed(Duration.zero);
      expect(terminal.engineReleased, isTrue);
    }

    for (var i = 0; i < 100; i++) {
      await cycle(i);
    }
    final before = ProcessInfo.currentRss;
    for (var i = 0; i < 300; i++) {
      await cycle(i);
    }
    final growth = (ProcessInfo.currentRss - before) / (1 << 20);
    // ignore: avoid_print
    print('LIFE06：300 轮 RSS 增长 ${growth.toStringAsFixed(1)} MiB');
    expect(growth, lessThan(32));
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('输入动作', () {
    test('快捷键栏的修饰键作用于下一次输入，然后复位', () {
      final terminal = _terminal();
      final sink = _Sink();
      terminal.bind(sink.input);
      terminal.input.setModifiers(['ctrl']);
      expect(terminal.controller.virtualMods.hasCtrl, isTrue);
      terminal.sendText('c');
      terminal.sendText('c');
      expect(sink.sent, ['\x03', 'c']);
      expect(terminal.controller.virtualMods.isEmpty, isTrue);
    });

    test('软键盘的键用掉了快捷键栏的修饰键，快捷键栏跟着复位', () {
      final terminal = _terminal();
      final sink = _Sink();
      terminal.bind(sink.input);
      terminal.input.setModifiers(['ctrl']);

      terminal.controller.sendKey(Key.d); // 视图把键交给 flterm 编码时就是这条路

      expect(sink.sent, ['\x04']);
      expect(terminal.input.modifiers, isEmpty);
    });

    test('整屏文字把自动折行接回去：复制出来的长网址不断成两行', () {
      final terminal = _terminal();
      final url = 'https://example.com/${'a' * 100}';
      terminal.feed(_bytes('$url\r\nnext'));
      expect(terminal.recentLines(24).take(2).map((line) => line.wrapped), [
        false,
        true,
      ]);
      expect(terminal.allText(), startsWith('$url\nnext'));
    });

    test('App 自己的提示直接显示，不发给远端', () {
      final terminal = _terminal();
      final sink = _Sink();
      terminal.bind(sink.input);
      terminal.showNotice('正在恢复连接…');
      expect(terminal.allText(), contains('正在恢复连接…'));
      expect(sink.sent, isEmpty);
    });
  });

  test('远端写进来的字、App 的提示都通知监听者（画中画小窗按它刷新文字）', () {
    final terminal = _terminal();
    var notified = 0;
    terminal.addListener(() => notified++);
    terminal.feed(_bytes('plain text, no mode change'));
    expect(notified, greaterThan(0), reason: '只改了屏幕上的字，没改任何模式');
    final afterFeed = notified;
    terminal.showNotice('正在恢复连接…');
    expect(notified, greaterThan(afterFeed));
    terminal.dispose();
    final afterDispose = notified;
    terminal.feed(_bytes('late'));
    expect(notified, afterDispose, reason: '释放后不再通知');
  });

  test('适配器只暴露和引擎无关的接口', () {
    final TerminalSessionAdapter terminal = _terminal();
    terminal.feed(_bytes('line1\r\nline2'));
    expect(terminal.engine, 'Ghostty');
    final lines = terminal.recentLines(100);
    expect(lines[0].text, 'line1');
    expect(lines[1].text, 'line2');
    expect(terminal.viewRows, 24);
    expect(terminal.isAlternateScreen, isFalse);
    terminal.feed(_bytes('\x1b[?1049h'));
    expect(terminal.isAlternateScreen, isTrue);
  });
}
