import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/terminal/terminal_text.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';

import 'support/test_terminal.dart';

GhosttyTerminalAdapter _terminal(int columns, int rows) {
  final terminal = GhosttyTerminalAdapter();
  addTearDown(terminal.dispose);
  resizeTestTerminal(terminal, columns, rows);
  return terminal;
}

void main() {
  test('terminal AI context joins wrapped lines and keeps recent output', () {
    final terminal = _terminal(8, 3);
    terminal.feed(utf8.encode('old line\r\n'));
    terminal.feed(utf8.encode('another old line\r\n'));
    terminal.feed(utf8.encode('abcdefghij\r\n'));
    terminal.feed(utf8.encode('new result\r\n'));

    final context = terminalAiContextText(
      terminal,
      maxLines: 2,
      maxColumns: 20,
    );

    expect(context, contains('abcdefghij'));
    expect(context, contains('new result'));
    expect(context, isNot(contains('old line')));
  });

  test('terminal AI context enforces its character limit', () {
    final terminal = _terminal(20, 3);
    terminal
        .feed(utf8.encode('first output\r\nsecond output\r\nlatest output'));

    final context = terminalAiContextText(terminal, maxCharacters: 13);

    expect(context, 'latest output');
  });
}
