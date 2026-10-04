import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('Mods', () {
    group('constructors', () {
      test('none has value 0', () {
        expect(const Mods.none().value, 0);
        expect(const Mods.none().isEmpty, isTrue);
      });

      test('named constants have expected bit values', () {
        expect(const Mods.shift().value, 1 << 0);
        expect(const Mods.ctrl().value, 1 << 1);
        expect(const Mods.alt().value, 1 << 2);
        expect(const Mods.superKey().value, 1 << 3);
        expect(const Mods.capsLock().value, 1 << 4);
        expect(const Mods.numLock().value, 1 << 5);
      });

      test('side constants have expected bit values', () {
        expect(const Mods.shiftSide().value, 1 << 6);
        expect(const Mods.ctrlSide().value, 1 << 7);
        expect(const Mods.altSide().value, 1 << 8);
        expect(const Mods.superSide().value, 1 << 9);
      });
    });

    group('|', () {
      test('combines flags', () {
        final combined = const Mods.ctrl() | const Mods.shift();
        expect(combined.hasCtrl, isTrue);
        expect(combined.hasShift, isTrue);
        expect(combined.hasAlt, isFalse);
      });
    });

    group('&', () {
      test('masks flags', () {
        final combined =
            const Mods.ctrl() | const Mods.shift() | const Mods.alt();
        final masked = combined & const Mods.ctrl();
        expect(masked.hasCtrl, isTrue);
        expect(masked.hasShift, isFalse);
        expect(masked.hasAlt, isFalse);
      });
    });

    group('flag getters', () {
      test('identify primary flags', () {
        expect(const Mods.shift().hasShift, isTrue);
        expect(const Mods.shift().hasCtrl, isFalse);

        expect(const Mods.ctrl().hasCtrl, isTrue);
        expect(const Mods.ctrl().hasShift, isFalse);

        expect(const Mods.alt().hasAlt, isTrue);
        expect(const Mods.alt().hasCtrl, isFalse);

        expect(const Mods.superKey().hasSuper, isTrue);
        expect(const Mods.superKey().hasAlt, isFalse);

        expect(const Mods.capsLock().hasCapsLock, isTrue);
        expect(const Mods.capsLock().hasNumLock, isFalse);

        expect(const Mods.numLock().hasNumLock, isTrue);
        expect(const Mods.numLock().hasCapsLock, isFalse);
      });

      test('identify side flags', () {
        final rightShift = const Mods.shift() | const Mods.shiftSide();
        expect(rightShift.isShiftRight, isTrue);
        expect(rightShift.hasShift, isTrue);

        expect(const Mods.shift().isShiftRight, isFalse);

        final rightCtrl = const Mods.ctrl() | const Mods.ctrlSide();
        expect(rightCtrl.isCtrlRight, isTrue);

        final rightAlt = const Mods.alt() | const Mods.altSide();
        expect(rightAlt.isAltRight, isTrue);

        final rightSuper = const Mods.superKey() | const Mods.superSide();
        expect(rightSuper.isSuperRight, isTrue);
      });

      test('isEmpty returns false for non-empty values', () {
        expect(const Mods.shift().isEmpty, isFalse);
        expect((const Mods.ctrl() | const Mods.alt()).isEmpty, isFalse);
      });
    });

    group('^', () {
      test('toggles flags', () {
        final mods = const Mods.ctrl() | const Mods.shift();
        final removed = mods ^ const Mods.ctrl();
        expect(removed.hasCtrl, isFalse);
        expect(removed.hasShift, isTrue);

        final added = const Mods.ctrl() ^ const Mods.alt();
        expect(added.hasCtrl, isTrue);
        expect(added.hasAlt, isTrue);

        final none = const Mods.ctrl() ^ const Mods.ctrl();
        expect(none.isEmpty, isTrue);

        final identity = const Mods.shift() ^ const Mods.none();
        expect(identity, equals(const Mods.shift()));
      });
    });

    group('equality', () {
      test('compares by value', () {
        expect(
          const Mods.ctrl() | const Mods.shift(),
          equals(const Mods.shift() | const Mods.ctrl()),
        );
        expect(const Mods.ctrl(), isNot(equals(const Mods.alt())));
        expect(const Mods.none(), equals(const Mods.none()));

        final a = const Mods.ctrl() | const Mods.shift();
        final b = const Mods.shift() | const Mods.ctrl();
        expect(a.hashCode, equals(b.hashCode));
      });
    });
  });
}
