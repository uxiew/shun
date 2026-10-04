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
      : terminal = Terminal(maxLines: maxLines) {
    // 只接输入和尺寸。xterm2 的剪贴板读写（OSC 52）、打开链接、通知、颜色查询等效果回调
    // 一个都不接，保持 null：远端发来的这些请求就没人执行，剪贴板查询也不会有应答（SEC09）。
    terminal.onOutput = (data) =>
        emitInput(Uint8List.fromList(utf8.encode(input.consume(data))));
    terminal.onResize = emitResize;
    _decoder = _newDecoder();
  }

  /// 只给 xterm2 专用视图（`presentation/terminal/xterm_terminal_view.dart`）和测试用。
  /// 连接层、会话控制器不该碰它，见 `test/terminal_layering_test.dart`。
  final Terminal terminal;

  late ByteConversionSink _decoder;

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
