import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';

void main() {
  final terminal = Terminal(cols: 40, rows: 5);
  terminal.write(Uint8List.fromList('Hello, World!'.codeUnits));

  for (var col = 0; col < 13; col++) {
    final ref = GridRef.at(terminal, Position(row: 0, col: col));
    print('($col, 0): "${ref.content}"');
  }

  terminal.dispose();
}
