import 'package:libghostty/libghostty.dart' show Position;
import 'package:test/test.dart';

void main() {
  group('Position', () {
    group('equality', () {
      test('compares by row and column', () {
        const position = Position(row: 1, col: 2);
        const copy = Position(row: 1, col: 2);
        const differentRow = Position(row: 2, col: 2);
        const differentCol = Position(row: 1, col: 3);

        expect(position, copy);
        expect(position.hashCode, copy.hashCode);
        expect(position, isNot(differentRow));
        expect(position, isNot(differentCol));
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
}
