import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';

void main() {
  final terminal = Terminal(cols: 80, rows: 24);

  terminal.onWritePty = (data) {
    print('PTY response: ${data.length} bytes');
  };

  terminal.onBell = () {
    print('Bell!');
  };

  terminal.onTitleChanged = () {
    print('Title changed: ${terminal.title}');
  };

  terminal.write(Uint8List.fromList('\x1b]2;My Terminal\x07'.codeUnits));
  terminal.write(Uint8List.fromList([0x07]));

  terminal.dispose();
}
