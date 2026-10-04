import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// 把一个绑定收到的字节按 UTF-8 记下来。
class _Sink {
  final sent = <String>[];
  final sizes = <(int, int)>[];
  void input(Uint8List bytes) => sent.add(utf8.decode(bytes));
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) =>
      sizes.add((columns, rows));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('代次：同一时刻只有一条连接收得到终端输入（NET09、SEC09）', () {
    test('新绑定立刻取代旧绑定，旧代次再也收不到字节', () {
      final terminal = XtermTerminalAdapter();
      addTearDown(terminal.dispose);
      final old = _Sink();
      final current = _Sink();
      final oldBinding = terminal.bind(old.input);
      terminal.sendText('before');
      final newBinding = terminal.bind(current.input);
      terminal.sendText('after');
      // 远端发 DA 查询，终端的应答也只交给当前代次。
      terminal.feed(_bytes('\x1b[c'));

      expect(old.sent, ['before']);
      expect(current.sent.first, 'after');
      expect(current.sent, hasLength(2));
      expect(current.sent.last, startsWith('\x1b['));
      expect(oldBinding.isActive, isFalse);
      expect(newBinding.isActive, isTrue);
    });

    test('旧代次晚到的释放不会把新代次也解掉', () {
      final terminal = XtermTerminalAdapter();
      addTearDown(terminal.dispose);
      final current = _Sink();
      final oldBinding = terminal.bind(_Sink().input);
      final newBinding = terminal.bind(current.input);

      oldBinding.release(); // 旧连接收尾时的 detachOutput
      terminal.sendText('x');
      expect(current.sent, ['x']);
      expect(newBinding.isActive, isTrue);

      newBinding.release();
      terminal.sendText('y');
      expect(current.sent, ['x'], reason: '解绑后的输入丢弃，不发给任何连接');
    });

    test('恢复时新连接一绑定就拿到终端现在的尺寸（不再停在 80x24）', () {
      final terminal = XtermTerminalAdapter();
      addTearDown(terminal.dispose);
      final first = _Sink();
      terminal.bind(first.input, resize: first.resize);
      expect(first.sizes, isEmpty, reason: '视图还没量过，不发一个猜的尺寸');

      terminal.terminal.resize(120, 40); // 视图布局后量出的尺寸
      expect(first.sizes, [(120, 40)]);

      // 断线恢复：新 PTY 按 80x24 打开；终端尺寸没变，xterm2 不会再通知。
      final restored = _Sink();
      terminal.bind(restored.input, resize: restored.resize);
      expect(restored.sizes, [(120, 40)]);
    });

    test('新代次从干净的解码状态开始：旧连接停在半个字符上不会和新 shell 拼成乱码', () {
      final terminal = XtermTerminalAdapter();
      addTearDown(terminal.dispose);
      terminal.bind(_Sink().input);
      final han = utf8.encode('汉'); // 3 字节
      terminal.feed(Uint8List.fromList(han.sublist(0, 2)));
      terminal.bind(_Sink().input); // 恢复
      terminal.feed(_bytes('ok'));

      final text = terminal.allText();
      expect(text, contains('ok'));
      expect(text, isNot(contains('�')), reason: '半个字符直接丢掉，不和下一代的字节拼');
    });
  });

  group('显示权：同一时刻只有一个视图（GST02）', () {
    test('新视图占用后旧的失效；旧视图晚一步释放不影响新视图', () {
      final terminal = XtermTerminalAdapter();
      addTearDown(terminal.dispose);
      final first = terminal.attachView();
      final second = terminal.attachView();
      expect(first.isActive, isFalse);
      expect(second.isActive, isTrue);

      first.release(); // 旋转、切分屏时旧视图在新视图挂上之后才销毁
      expect(second.isActive, isTrue);

      second.release();
      expect(second.isActive, isFalse);
      expect(terminal.attachView().isActive, isTrue);
    });
  });

  group('释放之后（GST02、SEC09）', () {
    test('迟到的远端字节、按键、提示都被忽略，不抛错；不能再绑定或显示', () {
      final terminal = XtermTerminalAdapter();
      final sink = _Sink();
      final binding = terminal.bind(sink.input);
      final view = terminal.attachView();
      terminal.dispose();
      terminal.dispose(); // 重复释放无副作用

      terminal.feed(_bytes('late output \x1b[c'));
      terminal.sendText('late input');
      terminal.showNotice('late notice');
      expect(sink.sent, isEmpty);
      expect(binding.isActive, isFalse);
      expect(view.isActive, isFalse);
      expect(() => terminal.bind(sink.input), throwsStateError);
      expect(terminal.attachView, throwsStateError);
      expect(terminal.isDisposed, isTrue);
    });
  });

  group('远端转义序列不能让终端越权（SEC09）', () {
    test('剪贴板写入和查询、链接、通知、工作目录：没有任何效果回调接上，也不回任何字节', () {
      final terminal = XtermTerminalAdapter();
      addTearDown(terminal.dispose);
      final xterm = terminal.terminal;
      expect(xterm.onClipboardStore, isNull);
      expect(xterm.onClipboardQuery, isNull);
      expect(xterm.onOpenUrl, isNull);
      expect(xterm.onNotification, isNull);
      expect(xterm.onCurrentDirectoryChange, isNull);
      expect(xterm.onPrivateOSC, isNull);

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
        '\x1b]7;file://host/etc\x07' // 工作目录
        'visible',
      ));

      expect(sink.sent, isEmpty, reason: '剪贴板查询不能被应答，否则远端能读走剪贴板');
      expect(platformCalls, isEmpty);
      expect(terminal.allText(), contains('visible'));
    });

    test('超长控制序列不卡死、不崩，之后的正常输出照常显示', () {
      final terminal = XtermTerminalAdapter();
      addTearDown(terminal.dispose);
      terminal.bind(_Sink().input);
      final watch = Stopwatch()..start();
      // 1 MiB 不结束的 OSC，结束后跟正常文字。
      terminal.feed(_bytes('\x1b]0;'));
      final chunk = _bytes('A' * 16384);
      for (var i = 0; i < 64; i++) {
        terminal.feed(chunk);
      }
      terminal.feed(_bytes('\x07after-osc\r\n'));
      // 10 万个参数的 CSI。
      terminal.feed(_bytes('\x1b[${List.filled(100000, '1').join(';')}m'));
      terminal.feed(_bytes('after-csi\r\n'));
      watch.stop();

      final text = terminal.allText();
      expect(text, contains('after-osc'));
      expect(text, contains('after-csi'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('输入动作', () {
    test('快捷键栏的修饰键作用于下一次输入，然后复位', () {
      final terminal = XtermTerminalAdapter();
      addTearDown(terminal.dispose);
      final sink = _Sink();
      terminal.bind(sink.input);
      terminal.input.setModifiers(['ctrl']);
      terminal.sendText('c');
      terminal.sendText('c');
      expect(sink.sent, ['\x03', 'c']);
    });

    test('App 自己的提示直接显示，不发给远端', () {
      final terminal = XtermTerminalAdapter();
      addTearDown(terminal.dispose);
      final sink = _Sink();
      terminal.bind(sink.input);
      terminal.showNotice('正在恢复连接…');
      expect(terminal.allText(), contains('正在恢复连接…'));
      expect(sink.sent, isEmpty);
    });
  });

  test('适配器只暴露和引擎无关的接口', () {
    final TerminalSessionAdapter terminal = XtermTerminalAdapter();
    addTearDown(terminal.dispose);
    terminal.feed(_bytes('line1\r\nline2'));
    expect(terminal.engine, 'xterm2');
    final lines = terminal.recentLines(100);
    expect(lines.first.text.trimRight(), 'line1');
    expect(lines[1].text.trimRight(), 'line2');
    expect(terminal.isAlternateScreen, isFalse);
    terminal.feed(_bytes('\x1b[?1049h'));
    expect(terminal.isAlternateScreen, isTrue);
  });

  group('尺寸发给远端：不发 0、不刮风暴（TER06）', () {
    test('0 行或 0 列不发', () {
      final terminal = _SizeOnlyEngine();
      addTearDown(terminal.dispose);
      final sink = _Sink();
      terminal.bind(sink.input, resize: sink.resize);
      terminal.resize(0, 24);
      terminal.resize(80, 0);
      terminal.resize(-1, -1);
      expect(sink.sizes, isEmpty);
    });

    test('键盘动画那样连着变：第一个立刻发，100 毫秒内的合并成最后一个', () {
      fakeAsync((async) {
        final terminal = _SizeOnlyEngine();
        final sink = _Sink();
        terminal.bind(sink.input, resize: sink.resize);
        for (var rows = 40; rows >= 25; rows--) {
          terminal.resize(80, rows); // 每帧少一行
          async.elapse(const Duration(milliseconds: 5));
        }
        expect(sink.sizes, [(80, 40)], reason: '第一个立刻发');
        async.elapse(TerminalSessionAdapterBase.resizeInterval);
        expect(sink.sizes, [(80, 40), (80, 25)], reason: '中间的不发，到点补最后一个');
        async.elapse(const Duration(seconds: 1));
        expect(sink.sizes, hasLength(2));
        terminal.dispose();
      });
    });

    test('隔得够久的两次各发一次；尺寸没变不重复发', () {
      fakeAsync((async) {
        final terminal = _SizeOnlyEngine();
        final sink = _Sink();
        terminal.bind(sink.input, resize: sink.resize);
        terminal.resize(80, 24);
        async.elapse(const Duration(milliseconds: 300));
        terminal.resize(80, 24);
        async.elapse(const Duration(milliseconds: 300));
        terminal.resize(132, 43);
        async.elapse(const Duration(milliseconds: 300));
        expect(sink.sizes, [(80, 24), (132, 43)]);
        terminal.dispose();
      });
    });

    test('换代次时新连接立刻拿到最新尺寸，旧代次不再收到补发', () {
      fakeAsync((async) {
        final terminal = _SizeOnlyEngine();
        final old = _Sink();
        terminal.bind(old.input, resize: old.resize);
        terminal.resize(80, 40);
        terminal.resize(80, 30); // 等着补发
        final current = _Sink();
        terminal.bind(current.input, resize: current.resize);
        async.elapse(const Duration(seconds: 1));
        expect(old.sizes, [(80, 40)]);
        expect(current.sizes, [(80, 30)]);
        terminal.dispose();
      });
    });

    test('释放后不留定时器、不再发', () {
      fakeAsync((async) {
        final terminal = _SizeOnlyEngine();
        final sink = _Sink();
        terminal.bind(sink.input, resize: sink.resize);
        terminal.resize(80, 40);
        terminal.resize(80, 30);
        terminal.dispose();
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(sink.sizes, [(80, 40)]);
      });
    });
  });
}

/// 只会报尺寸的最小引擎，用来单测基类的尺寸规矩。
final class _SizeOnlyEngine extends TerminalSessionAdapterBase {
  void resize(int columns, int rows) => emitResize(columns, rows, 0, 0);

  @override
  String get engine => 'test';
  @override
  void feed(Uint8List bytes) {}
  @override
  void showNotice(String text) {}
  @override
  void sendText(String text) {}
  @override
  void sendKey(TerminalSpecialKey key) {}
  @override
  bool get isAlternateScreen => false;
  @override
  int get viewRows => 0;
  @override
  List<TerminalTextLine> recentLines(int count) => const [];
  @override
  String allText() => '';
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  void disposeEngine() {}
}
