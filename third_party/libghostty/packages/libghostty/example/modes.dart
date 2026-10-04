import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';

void main() {
  final terminal = Terminal(cols: 80, rows: 24);

  print('Bracketed paste: ${terminal.modeGet(const .bracketedPaste())}');

  terminal.write(Uint8List.fromList('\x1b[?2004h'.codeUnits));
  print('Bracketed paste: ${terminal.modeGet(const .bracketedPaste())}');

  terminal.modeSet(const .bracketedPaste(), value: false);
  print('Bracketed paste: ${terminal.modeGet(const .bracketedPaste())}');

  final report = const TerminalMode.bracketedPaste().encodeReport(.reset);
  print('DECRPM response: ${report.codeUnits}');

  terminal.dispose();
}
