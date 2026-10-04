@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('KeyEvent', () {
    late KeyEvent event;

    setUp(() => event = KeyEvent());

    tearDown(() => event.dispose());

    group('constructor', () {
      test('initializes default state', () {
        expect(event.action, KeyAction.press);
        expect(event.key, Key.unidentified);
        expect(event.mods, const Mods.none());
        expect(event.composing, isFalse);
        expect(event.utf8, isNull);
        expect(event.unshiftedCodepoint, 0);
      });
    });

    group('accessors', () {
      test('store latest scalar values', () {
        event.action = KeyAction.press;
        expect(event.action, KeyAction.press);

        event.action = KeyAction.repeat;
        expect(event.action, KeyAction.repeat);

        event.key = Key.a;
        expect(event.key, Key.a);

        event.key = Key.arrowUp;
        expect(event.key, Key.arrowUp);

        event.mods = const Mods.ctrl() | const Mods.shift();
        expect(event.mods.hasCtrl, isTrue);
        expect(event.mods.hasShift, isTrue);
        expect(event.mods.hasAlt, isFalse);

        event.consumedMods = const Mods.alt();
        expect(event.consumedMods.hasAlt, isTrue);
        expect(event.consumedMods.hasCtrl, isFalse);

        event.composing = true;
        expect(event.composing, isTrue);

        event.utf8 = 'a';
        expect(event.utf8, 'a');

        event.unshiftedCodepoint = 0x61;
        expect(event.unshiftedCodepoint, 0x61);
      });

      test('clears nullable text', () {
        event.utf8 = 'x';
        event.utf8 = null;
        expect(event.utf8, isNull);
      });
    });

    group('mutation', () {
      test('preserves unrelated properties when key changes', () {
        event.action = KeyAction.press;
        event.key = Key.a;
        expect(event.key, Key.a);

        event.key = Key.b;
        expect(event.key, Key.b);
        expect(event.action, KeyAction.press);
      });
    });
  });
}
