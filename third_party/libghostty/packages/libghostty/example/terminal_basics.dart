import 'package:libghostty/libghostty.dart';

void main() {
  final terminal = Terminal(cols: 80, rows: 24);
  final renderState = RenderState();
  final rows = RowIterator();
  final cells = CellIterator();

  terminal.write(
    .fromList('\x1b[1;34mHello\x1b[0m, \x1b[32mWorld\x1b[0m!\r\n'.codeUnits),
  );

  renderState.update(terminal);
  rows.reset(renderState);
  while (rows.next()) {
    final buf = StringBuffer();
    cells.reset(rows);
    while (cells.next()) {
      if (cells.hasText) buf.write(cells.content);
    }
    final text = buf.toString().trimRight();
    if (text.isNotEmpty) print('Row: $text');
  }

  cells.dispose();
  rows.dispose();
  renderState.dispose();
  terminal.dispose();
}
