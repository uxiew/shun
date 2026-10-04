import 'dart:convert';
import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';

void main() {
  final terminal = Terminal(cols: 80, rows: 24);

  // Register effect callbacks (invoked synchronously during write).
  terminal.onWritePty = (data) => print('PTY: ${data.length} bytes');
  terminal.onBell = () => print('Bell!');
  terminal.onTitleChanged = () => print('Title: ${terminal.title}');

  // Write styled text and a title change.
  terminal.write(
    Uint8List.fromList(
      '\x1b]2;My Terminal\x07\x1b[1;34mHello\x1b[0m, World!\r\n'.codeUnits,
    ),
  );

  // Read screen content via render state and iterators.
  final renderState = RenderState();
  final rows = RowIterator();
  final cells = CellIterator();
  renderState.update(terminal);
  rows.reset(renderState);
  while (rows.next()) {
    final buf = StringBuffer();
    cells.reset(rows);
    while (cells.next()) {
      if (cells.hasText) buf.write(cells.content);
    }
    final line = buf.toString().trimRight();
    if (line.isNotEmpty) print(line);
    rows.dirty = false;
  }
  renderState.dirty = DirtyState.clean;

  // Encode a Ctrl+C key press.
  final encoder = KeyEncoder()..sync(terminal);
  final event = KeyEvent()
    ..mods = const .ctrl()
    ..action = .press
    ..key = .c;
  final seq = encoder.encode(event);
  if (seq.isNotEmpty) print('Key sequence: ${utf8.encode(seq)}');

  event.dispose();
  encoder.dispose();
  cells.dispose();
  rows.dispose();
  renderState.dispose();
  terminal.dispose();
}
