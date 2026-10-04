import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';

void main() {
  final terminal = Terminal(cols: 40, rows: 5);
  final renderState = RenderState();
  final rows = RowIterator();
  final cells = CellIterator();

  terminal.write(
    Uint8List.fromList(
      'Hello, \x1b[1;32mworld\x1b[0m!\r\n'
              '\x1b[4munderlined\x1b[0m text\r\n'
              '\x1b[38;2;255;128;0morange\x1b[0m\r\n'
          .codeUnits,
    ),
  );

  switch (renderState.update(terminal)) {
    case .clean:
      print('Frame is clean, nothing to draw.');
    case .partial:
      print('Partial redraw needed.');
    case .full:
      print('Full redraw needed.');
  }

  final colors = renderState.colors;
  final fg = colors.foreground;
  final bg = colors.background;
  print('Default fg: RGB(${fg.r}, ${fg.g}, ${fg.b})');
  print('Default bg: RGB(${bg.r}, ${bg.g}, ${bg.b})');
  print('Palette entries: ${colors.palette.length}');

  rows.reset(renderState);
  while (rows.next()) {
    if (!rows.dirty) continue;

    final buf = StringBuffer();
    cells.reset(rows);
    while (cells.next()) {
      if (!cells.hasText) continue;
      buf.write(cells.content);
    }
    final text = buf.toString().trimRight();
    if (text.isNotEmpty) print('  $text');
    rows.dirty = false;
  }

  renderState.dirty = DirtyState.clean;
  print('After clearing: ${renderState.dirty}');

  cells.dispose();
  rows.dispose();
  renderState.dispose();
  terminal.dispose();
}
