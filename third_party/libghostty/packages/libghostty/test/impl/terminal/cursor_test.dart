@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('CursorShape', () {
    group('values', () {
      test('contains supported shapes', () {
        expect(
          CursorShape.values,
          containsAll([
            CursorShape.block,
            CursorShape.underline,
            CursorShape.bar,
            CursorShape.blockHollow,
          ]),
        );
      });
    });
  });

  group('Cursor', () {
    group('constructor', () {
      test('initializes default state', () {
        const cursor = Cursor();
        expect(cursor.position.row, 0);
        expect(cursor.position.col, 0);
        expect(cursor.visible, isTrue);
        expect(cursor.shape, CursorShape.block);
      });
    });

    group('equality', () {
      test('compares by value', () {
        const a = Cursor(
          position: Position(row: 5, col: 10),
          shape: CursorShape.bar,
        );
        const b = Cursor(
          position: Position(row: 5, col: 10),
          shape: CursorShape.bar,
        );

        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('distinguishes changed properties', () {
        const base = Cursor(position: Position(row: 5, col: 10));

        expect(
          base,
          isNot(equals(const Cursor(position: Position(row: 6, col: 10)))),
        );
        expect(
          base,
          isNot(
            equals(
              const Cursor(position: Position(row: 5, col: 10), visible: false),
            ),
          ),
        );
        expect(
          base,
          isNot(
            equals(
              const Cursor(
                position: Position(row: 5, col: 10),
                shape: CursorShape.underline,
              ),
            ),
          ),
        );
      });
    });

    group('copyWith', () {
      test('overrides selected fields', () {
        const cursor = Cursor(
          position: Position(row: 5, col: 10),
          shape: CursorShape.bar,
        );

        final moved = cursor.copyWith(
          position: const Position(row: 6, col: 11),
        );

        expect(moved.position, const Position(row: 6, col: 11));
        expect(moved.shape, CursorShape.bar);
        expect(moved.visible, isTrue);
      });
    });
  });
}
