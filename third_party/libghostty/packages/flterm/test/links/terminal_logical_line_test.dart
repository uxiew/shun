import 'package:flterm/src/foundation.dart' show CellRange;
import 'package:flterm/src/links/terminal_logical_line.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show Position;

void main() {
  group('TerminalLogicalLine', () {
    TerminalLogicalLine line(String text, List<Position> cells) {
      return TerminalLogicalLine(
        text,
        cells,
        cells,
        List<String?>.filled(cells.length, null),
      );
    }

    group('rangeForOffsets', () {
      test('returns the cells covered by text offsets', () {
        final logicalLine = line('abc', [
          const Position(row: 0, col: 2),
          const Position(row: 0, col: 3),
          const Position(row: 0, col: 4),
        ]);

        final result = logicalLine.rangeForOffsets(1, 3);

        expect(
          result,
          const CellRange(
            start: Position(row: 0, col: 3),
            end: Position(row: 0, col: 4),
          ),
        );
      });
    });

    group('textForCellRange', () {
      test('returns the text covered by cell indexes', () {
        final logicalLine = line('abc', [
          const Position(row: 0, col: 2),
          const Position(row: 0, col: 3),
          const Position(row: 0, col: 4),
        ]);

        final result = logicalLine.textForCellRange(1, 2);

        expect(result, 'bc');
      });
    });

    group('rangeForCellRange', () {
      test('returns the cells covered by cell indexes', () {
        final logicalLine = line('abc', [
          const Position(row: 0, col: 2),
          const Position(row: 0, col: 3),
          const Position(row: 0, col: 4),
        ]);

        final result = logicalLine.rangeForCellRange(1, 2);

        expect(
          result,
          const CellRange(
            start: Position(row: 0, col: 3),
            end: Position(row: 0, col: 4),
          ),
        );
      });
    });
  });
}
