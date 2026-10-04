import 'package:libghostty/libghostty.dart';

class TerminalDump {
  static List<String> screenContent(Terminal terminal) {
    final rs = RenderState();
    final rows = RowIterator();
    final cells = CellIterator();
    try {
      rs.update(terminal);
      final lines = <String>[];
      rows.reset(rs);
      while (rows.next()) {
        final buffer = StringBuffer();
        cells.reset(rows);
        while (cells.next()) {
          buffer.write(cells.content);
        }
        lines.add(buffer.toString());
      }
      return lines;
    } finally {
      cells.dispose();
      rows.dispose();
      rs.dispose();
    }
  }

  static List<String> nonEmptyContent(Terminal terminal) {
    return screenContent(
      terminal,
    ).map((line) => line.trimRight()).where((line) => line.isNotEmpty).toList();
  }

  static bool hasContentOverlap(Terminal terminal) {
    final lines = nonEmptyContent(terminal);
    return lines.length != lines.toSet().length;
  }
}
