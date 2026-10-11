import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:xterm2/xterm.dart';

/// 原版 Netcatty 的终端引擎 xterm2 的适配器，**只给测试用**：R20 起它不在安装包里（docs/06 E 步），
/// 留着是为了和 Ghostty 吃同一份字节素材做对照（`terminal_vt_corpus_test.dart`），
/// 以及拿 [xtermKeySequence] 核对 Ghostty 编出来的按键（`terminal_input_routing_test.dart`）。
/// 删了它，这两样就没有对照了。
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
  /// 不用它。这里按 xterm 的规矩自己编（[xtermKeySequence]），快捷键栏的修饰键也在这里套上、用掉：
  /// 先清掉再发，输出回调里的 consume 就不会再套一遍。原来交给 consume 套，它只认得 ESC [ A 这种三个字的序列，
  /// Ctrl+PgUp 发出去还是 ESC [ 5 ~，Ctrl 丢了。
  @override
  void sendKey(TerminalSpecialKey key) {
    if (isDisposed) return;
    final modifiers = input.modifiers;
    final text = xtermKeySequence(
      key,
      shift: modifiers.contains('shift'),
      alt: modifiers.contains('alt'),
      ctrl: modifiers.contains('ctrl'),
      applicationCursorKeys: terminal.cursorKeysMode,
    );
    input.clearModifiers();
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

/// 功能键按 xterm 的规矩编成字节（Ghostty 由 libghostty 编，结果一样，见 `terminal_input_routing_test.dart`）。
///
/// 修饰键编成参数 m = 1 + Shift(1) + Alt(2) + Ctrl(4)：方向键、Home/End、F1–F4 带修饰键时是 `ESC [ 1 ; m X`，
/// 不带时方向键和 Home/End 跟着远端的应用光标键模式（vim、less 会打开）选 `ESC O X` 还是 `ESC [ X`，F1–F4 是 `ESC O P`…；
/// PgUp/PgDn、Insert/Delete、F5–F12 是 `ESC [ n ~`，带修饰键是 `ESC [ n ; m ~`。
/// Esc、Tab、回车、退格没有参数写法：Alt 在前面加一个 ESC；Shift+Tab 是反向 Tab `ESC [ Z`；Ctrl+退格是 0x08。
@visibleForTesting
String xtermKeySequence(
  TerminalSpecialKey key, {
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
  bool applicationCursorKeys = false,
}) {
  final m = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
  String letter(String x, {required bool followsCursorMode}) {
    if (m > 1) return '\x1b[1;$m$x';
    return followsCursorMode && !applicationCursorKeys ? '\x1b[$x' : '\x1bO$x';
  }

  String tilde(int n) => m > 1 ? '\x1b[$n;$m~' : '\x1b[$n~';
  String altPrefix(String text) => alt ? '\x1b$text' : text;

  return switch (key) {
    TerminalSpecialKey.arrowUp => letter('A', followsCursorMode: true),
    TerminalSpecialKey.arrowDown => letter('B', followsCursorMode: true),
    TerminalSpecialKey.arrowRight => letter('C', followsCursorMode: true),
    TerminalSpecialKey.arrowLeft => letter('D', followsCursorMode: true),
    TerminalSpecialKey.home => letter('H', followsCursorMode: true),
    TerminalSpecialKey.end => letter('F', followsCursorMode: true),
    TerminalSpecialKey.f1 => letter('P', followsCursorMode: false),
    TerminalSpecialKey.f2 => letter('Q', followsCursorMode: false),
    TerminalSpecialKey.f3 => letter('R', followsCursorMode: false),
    TerminalSpecialKey.f4 => letter('S', followsCursorMode: false),
    TerminalSpecialKey.insert => tilde(2),
    TerminalSpecialKey.delete => tilde(3),
    TerminalSpecialKey.pageUp => tilde(5),
    TerminalSpecialKey.pageDown => tilde(6),
    TerminalSpecialKey.f5 => tilde(15),
    TerminalSpecialKey.f6 => tilde(17),
    TerminalSpecialKey.f7 => tilde(18),
    TerminalSpecialKey.f8 => tilde(19),
    TerminalSpecialKey.f9 => tilde(20),
    TerminalSpecialKey.f10 => tilde(21),
    TerminalSpecialKey.f11 => tilde(23),
    TerminalSpecialKey.f12 => tilde(24),
    TerminalSpecialKey.escape => altPrefix('\x1b'),
    TerminalSpecialKey.tab => altPrefix(shift ? '\x1b[Z' : '\t'),
    TerminalSpecialKey.enter => altPrefix('\r'),
    TerminalSpecialKey.backspace => altPrefix(ctrl ? '\x08' : '\x7f'),
  };
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
