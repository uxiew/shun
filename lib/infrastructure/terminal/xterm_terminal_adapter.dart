import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import 'terminal_session_adapter.dart';

/// 旧引擎 xterm2 的适配器：迁移期的对照基线（docs/06 A、D 步），Ghostty 成为默认后退出生产路径。
///
/// xterm2 只收字符串，所以解码留在这里，而且整条流共用一个 UTF-8 解码器：
/// 以前在 SSH 层按网络块各自解码，一个汉字（3 字节）或 emoji（4 字节）被切在两块之间时，
/// 两半各变成 U+FFFD，中文随机乱码（A03 / TER01）。
final class XtermTerminalAdapter extends TerminalSessionAdapterBase {
  XtermTerminalAdapter({int maxLines = 10000, super.input})
      : terminal = _Terminal(maxLines: maxLines) {
    // 只接输入和尺寸。打开链接、通知、工作目录这些效果回调保持 null，远端的请求没人执行（SEC09）。
    // 剪贴板两个回调不能留 null：xterm2 的 TerminalView 挂上时见它们是 null 就接上自己的实现，
    // 终端有焦点时真去读写手机剪贴板，读到的内容还 base64 回给远端（R19 挂着视图测出来的，
    // R16/R17 只测了不挂视图的适配器）。所以这里接成「什么都不做」，视图就不会再接。
    terminal
      ..onOutput = ((data) =>
          emitInput(Uint8List.fromList(utf8.encode(input.consume(data)))))
      ..onResize = emitResize
      ..onClipboardStore = _ignoreClipboardWrite
      ..onClipboardQuery = _refuseClipboardRead;
    _decoder = _newDecoder();
  }

  /// 只给 xterm2 专用视图（`presentation/terminal/xterm_terminal_view.dart`）和测试用。
  /// 连接层、会话控制器不该碰它，见 `test/terminal_layering_test.dart`。
  final Terminal terminal;

  late ByteConversionSink _decoder;

  static void _ignoreClipboardWrite(String selector, String text) {}

  /// 返回 null：xterm2 不应答这次查询。
  static String? _refuseClipboardRead(String selector) => null;

  ByteConversionSink _newDecoder() =>
      const Utf8Decoder(allowMalformed: true).startChunkedConversion(
        StringConversionSink.fromStringSink(_TerminalWriter(terminal)),
      );

  @override
  String get engine => 'xterm2';

  @override
  void feed(Uint8List bytes) {
    if (isDisposed) return;
    _decoder.add(bytes);
  }

  @override
  void showNotice(String text) {
    if (isDisposed) return;
    terminal.write(text);
  }

  /// 新代次从干净的解码状态开始：旧连接最后一块可能停在半个字符上，
  /// 不丢掉的话会和新 shell 的第一个字节拼成乱码。
  @override
  void onRebind() {
    _decoder = _newDecoder();
  }

  @override
  void sendText(String text) {
    if (isDisposed) return;
    terminal.textInput(text);
  }

  /// xterm2 的按键表 keyInput 编修饰键有错（Alt+↑ 编成了 Ctrl 的 ESC[1;5A，Alt+Tab 丢掉 Alt），
  /// 不用它。这里按远端的光标键模式挑前缀，修饰键照旧由输出回调里的 consume 套：
  /// 不带修饰键时应用光标键模式发 ESC O A，带修饰键一律用 ESC [ 1;n A（xterm 的规矩）。
  @override
  void sendKey(TerminalSpecialKey key) {
    if (isDisposed) return;
    final cursorLetter = switch (key) {
      TerminalSpecialKey.arrowUp => 'A',
      TerminalSpecialKey.arrowDown => 'B',
      TerminalSpecialKey.arrowRight => 'C',
      TerminalSpecialKey.arrowLeft => 'D',
      TerminalSpecialKey.home => 'H',
      TerminalSpecialKey.end => 'F',
      _ => null,
    };
    final String text;
    if (cursorLetter != null) {
      text = input.modifiers.isEmpty && terminal.cursorKeysMode
          ? '\x1bO$cursorLetter'
          : '\x1b[$cursorLetter';
    } else {
      text = switch (key) {
        TerminalSpecialKey.escape => '\x1b',
        TerminalSpecialKey.tab => '\t',
        TerminalSpecialKey.pageUp => '\x1b[5~',
        TerminalSpecialKey.pageDown => '\x1b[6~',
        _ => throw StateError('$key'),
      };
    }
    // Shift+Tab 是反向 Tab（ESC [ Z），consume 不认识，这里先换掉。
    if (key == TerminalSpecialKey.tab && input.modifiers.contains('shift')) {
      input.setModifiers(input.modifiers.difference(const {'shift'}));
      terminal.textInput('\x1b[Z');
      return;
    }
    terminal.textInput(text);
  }

  /// xterm2 的 paste：按远端的 2004 模式包标记或把换行换成 CR，控制字符换成空格、转义序列整段去掉。
  /// 先清修饰键：xterm2 的输出回调里会给发出去的字套修饰键，不清的话粘贴的第一个字会变成 Ctrl/Alt 组合。
  @override
  void paste(String text) {
    if (isDisposed || text.isEmpty) return;
    input.clearModifiers();
    terminal.paste(text);
  }

  @override
  bool get bracketedPasteMode => !isDisposed && terminal.bracketedPasteMode;

  @override
  bool get isAlternateScreen => terminal.isUsingAltBuffer;

  @override
  int get viewRows => terminal.viewHeight;

  @override
  List<TerminalTextLine> recentLines(int count) {
    final lines = terminal.buffer.lines;
    final start = count >= lines.length ? 0 : lines.length - count;
    return [
      for (var index = start; index < lines.length; index++)
        TerminalTextLine(
          lines[index].getText(),
          wrapped: lines[index].isWrapped,
        ),
    ];
  }

  @override
  String allText() => terminal.buffer.getText();

  @override
  void addListener(VoidCallback listener) => terminal.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      terminal.removeListener(listener);

  @override
  void disposeEngine() {
    terminal.onOutput = null;
    terminal.onResize = null;
    terminal.dispose();
  }
}

/// 不回报窗口标题（CSI 21 t）。远端可以先把标题设成一段命令、再要求终端「报一下标题」，
/// 终端回的字节就进了 shell 的输入，等于远端替用户打了字（老牌的标题回显注入）。
/// xterm、Ghostty 默认都不回，xterm2 无条件回（R19 测出来的，SEC08）。
class _Terminal extends Terminal {
  _Terminal({super.maxLines});

  @override
  void reportTitle() {}
}

class _TerminalWriter implements StringSink {
  _TerminalWriter(this.terminal);
  final Terminal terminal;

  @override
  void write(Object? object) {
    final text = '$object';
    if (text.isNotEmpty) terminal.write(text);
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');
}
