import 'package:flterm/src/links/osc8_link_detector.dart';
import 'package:flterm/src/links/terminal_logical_line.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show Position;

void main() {
  group('Osc8LinkDetector', () {
    TerminalLogicalLine line(String text, List<String?> uris) {
      final cells = [
        for (var i = 0; i < text.length; i++) Position(row: 0, col: i),
      ];
      return TerminalLogicalLine(text, cells, cells, uris);
    }

    group('matches', () {
      test('groups adjacent cells with the same URI', () {
        final detector = Osc8LinkDetector();
        final logicalLine = line('abcdef', [
          null,
          'https://example.test',
          'https://example.test',
          'https://example.test',
          null,
          null,
        ]);

        final matches = detector.matches([logicalLine]).toList();

        expect(matches.single.link.text, 'bcd');
      });
    });
  });
}
