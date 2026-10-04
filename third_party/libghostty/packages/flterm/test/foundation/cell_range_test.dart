import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CellRange', () {
    group('contains', () {
      test('includes cells between the start and end positions', () {
        const range = CellRange(
          start: Position(row: 1, col: 2),
          end: Position(row: 1, col: 4),
        );

        final result = range.contains(const Position(row: 1, col: 3));

        expect(result, isTrue);
      });

      test('excludes cells outside the end position', () {
        const range = CellRange(
          start: Position(row: 1, col: 2),
          end: Position(row: 1, col: 4),
        );

        final result = range.contains(const Position(row: 1, col: 5));

        expect(result, isFalse);
      });
    });

    group('overlaps', () {
      test('returns true for intersecting ranges', () {
        const first = CellRange(
          start: Position(row: 0, col: 2),
          end: Position(row: 0, col: 6),
        );
        const second = CellRange(
          start: Position(row: 0, col: 4),
          end: Position(row: 0, col: 8),
        );

        final result = first.overlaps(second);

        expect(result, isTrue);
      });

      test('returns false for separated ranges', () {
        const first = CellRange(
          start: Position(row: 0, col: 2),
          end: Position(row: 0, col: 4),
        );
        const second = CellRange(
          start: Position(row: 0, col: 5),
          end: Position(row: 0, col: 8),
        );

        final result = first.overlaps(second);

        expect(result, isFalse);
      });
    });
  });
}
