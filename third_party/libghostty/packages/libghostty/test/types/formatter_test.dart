import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('FormatterExtra', () {
    FormatterExtra create({bool enabled = true}) =>
        FormatterExtra(cursor: enabled, modes: enabled);

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
        final second = create(enabled: false);

        expect(first, isNot(second));
      });
    });
  });
}
