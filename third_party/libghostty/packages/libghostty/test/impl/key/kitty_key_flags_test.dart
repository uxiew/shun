import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('KittyKeyFlags', () {
    group('constructors', () {
      test('create disabled and enabled flags', () {
        expect(const KittyKeyFlags.disabled().isDisabled, isTrue);
        expect(const KittyKeyFlags.all().isDisabled, isFalse);
      });
    });

    group('|', () {
      test('combines flags', () {
        final combined =
            const KittyKeyFlags.disambiguate() |
            const KittyKeyFlags.reportEvents();
        expect(combined.isDisabled, isFalse);
      });
    });

    group('equality', () {
      test('compares by value', () {
        final a =
            const KittyKeyFlags.disambiguate() |
            const KittyKeyFlags.reportEvents();
        final b =
            const KittyKeyFlags.reportEvents() |
            const KittyKeyFlags.disambiguate();
        expect(a, equals(b));

        final hashA =
            const KittyKeyFlags.disambiguate() |
            const KittyKeyFlags.reportAll();
        final hashB =
            const KittyKeyFlags.reportAll() |
            const KittyKeyFlags.disambiguate();
        expect(hashA.hashCode, equals(hashB.hashCode));
      });

      test('distinguishes different values', () {
        expect(
          const KittyKeyFlags.disambiguate(),
          isNot(equals(const KittyKeyFlags.reportEvents())),
        );
      });
    });
  });
}
