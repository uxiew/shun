import 'dart:convert';

import 'package:xterm2/xterm.dart';

/// 把终端字节画成「屏幕上看得到的文字」，用来比较两条路径的结果。
/// 两条路径用同一个模拟器（xterm2），比较的是 Mosh 传过来的东西对不对，不是模拟器本身。
class Screen {
  Screen(this.cols, this.rows) : terminal = Terminal(maxLines: 10000) {
    terminal.resize(cols, rows);
  }

  final int cols;
  final int rows;
  final Terminal terminal;
  late final _decoder = const Utf8Decoder(
    allowMalformed: true,
  ).startChunkedConversion(_StringSink(terminal.write));
  int bytes = 0;

  void feed(List<int> data) {
    bytes += data.length;
    _decoder.add(data);
  }

  void resize(int c, int r) => terminal.resize(c, r);

  /// 当前可见区每行去掉右侧空白。没写过的格子按空格算（xterm2 的 getText 会直接跳过它们，
  /// 「第 10 列的 mid」会被读成「第 1 列的 mid」），宽字符的第二格不重复输出。
  List<String> lines() {
    final buffer = terminal.buffer;
    return [
      for (var i = 0; i < terminal.viewHeight; i++)
        _row(buffer.lines[buffer.scrollBack + i]),
    ];
  }

  String _row(BufferLine line) {
    final out = StringBuffer();
    for (var x = 0; x < line.length; x++) {
      final width = line.getWidth(x);
      if (width == 0 && x > 0 && line.getWidth(x - 1) == 2) continue;
      final code = line.getCodePoint(x);
      if (code == 0) {
        out.write(' ');
      } else {
        out.write(line.getText(x, x + (width == 2 ? 2 : 1)));
      }
    }
    return out.toString().trimRight();
  }

  String text() => lines().join('\n');

  (int, int) get cursor => (terminal.buffer.cursorX, terminal.buffer.cursorY);
}

class _StringSink implements Sink<String> {
  _StringSink(this._write);
  final void Function(String) _write;
  @override
  void add(String data) => _write(data);
  @override
  void close() {}
}
