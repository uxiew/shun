import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('Position', () {
    Position create({int row = 1, int col = 2}) => Position(row: row, col: col);

    group('equality', () {
      test('compares by row and column', () {
        final position = create();
        final copy = create();

        expect(position, copy);
      });

      test('produces equal hashes for equal values', () {
        final position = create();
        final copy = create();

        expect(position.hashCode, copy.hashCode);
      });

      test('distinguishes changed values', () {
        final position = create();

        expect(position, isNot(create(row: 2)));
        expect(position, isNot(create(col: 3)));
      });
    });

    group('toString', () {
      test('includes row and column', () {
        const position = Position(row: 1, col: 2);

        final result = position.toString();

        expect(result, 'Position(row: 1, col: 2)');
      });
    });
  });

  group('MouseEncoderSize', () {
    MouseEncoderSize create({int screenWidth = 800}) => MouseEncoderSize(
      screenWidth: screenWidth,
      screenHeight: 600,
      cellWidth: 8,
      cellHeight: 16,
    );

    group('equality', () {
      test('compares equal values structurally', () {
        final first = create();
        final second = create();

        expect(first, second);
      });

      test('produces equal hashes for equal values', () {
        final first = create();
        final second = create();

        expect(first.hashCode, second.hashCode);
      });

      test('distinguishes changed values', () {
        final first = create();
        final second = create(screenWidth: 801);

        expect(first, isNot(second));
      });
    });
  });

  group('Scrollbar', () {
    Scrollbar create({int total = 100}) =>
        Scrollbar(total: total, offset: 10, visible: 24);

    group('equality', () {
      test('compares equal values structurally', () {
        final first = create();
        final second = create();

        expect(first, second);
      });

      test('produces equal hashes for equal values', () {
        final first = create();
        final second = create();

        expect(first.hashCode, second.hashCode);
      });

      test('distinguishes changed values', () {
        final first = create();
        final second = create(total: 101);

        expect(first, isNot(second));
      });
    });
  });

  group('TerminalGeometry', () {
    TerminalGeometry create({int cols = 80}) =>
        TerminalGeometry(cols: cols, rows: 24, widthPx: 640, heightPx: 384);

    group('equality', () {
      test('compares equal values structurally', () {
        final first = create();
        final second = create();

        expect(first, second);
      });

      test('produces equal hashes for equal values', () {
        final first = create();
        final second = create();

        expect(first.hashCode, second.hashCode);
      });

      test('distinguishes changed values', () {
        final first = create();
        final second = create(cols: 81);

        expect(first, isNot(second));
      });
    });
  });

  group('TerminalSizeInfo', () {
    TerminalSizeInfo create({int rows = 24}) =>
        TerminalSizeInfo(rows: rows, columns: 80, cellWidth: 8, cellHeight: 16);

    group('equality', () {
      test('compares equal values structurally', () {
        final first = create();
        final second = create();

        expect(first, second);
      });

      test('produces equal hashes for equal values', () {
        final first = create();
        final second = create();

        expect(first.hashCode, second.hashCode);
      });

      test('distinguishes changed values', () {
        final first = create();
        final second = create(rows: 25);

        expect(first, isNot(second));
      });
    });
  });
}
