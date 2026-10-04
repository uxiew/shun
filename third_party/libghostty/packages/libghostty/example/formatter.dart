import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';

void main() {
  final terminal = Terminal(cols: 40, rows: 5);

  terminal.write(Uint8List.fromList('Hello, terminal!\r\n'.codeUnits));
  terminal.write(Uint8List.fromList('\x1b[1mBold text\x1b[m\r\n'.codeUnits));

  final formatter = Formatter(terminal: terminal, format: .plain, trim: true);
  print(formatter.format());
  formatter.dispose();

  terminal.dispose();
}
