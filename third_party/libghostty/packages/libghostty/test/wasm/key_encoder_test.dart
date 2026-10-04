@Tags(['wasm'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

import 'helpers/setup.dart';

void main() {
  setUpAll(setUpWasm);

  group('KeyEncoder', () {
    late KeyEncoder encoder;
    late KeyEvent event;

    setUp(() {
      encoder = KeyEncoder();
      event = KeyEvent();
    });

    tearDown(() {
      event.dispose();
      encoder.dispose();
    });

    group('encode', () {
      String encode(Key key, {Mods mods = const Mods.none()}) {
        event.action = KeyAction.press;
        event.key = key;
        event.mods = mods;
        return encoder.encode(event);
      }

      test('returns default key sequences', () {
        expect(encode(Key.c, mods: const Mods.ctrl()), '\x03');
        expect(encode(Key.enter), '\r');
        expect(encode(Key.backspace), '\x7f');
        expect(encode(Key.escape), '\x1b');
        expect(encode(Key.shiftLeft), isEmpty);
        expect(encode(Key.arrowUp), '\x1b[A');
      });
    });

    group('setBackArrowKeyMode', () {
      test('makes Backspace return backspace', () {
        encoder.setBackArrowKeyMode(enabled: true);

        event.action = KeyAction.press;
        event.key = Key.backspace;

        final result = encoder.encode(event);
        expect(result, '\x08');
      });
    });

    group('setCursorKeyApplication', () {
      test('makes ArrowUp use SS3', () {
        encoder.setCursorKeyApplication(enabled: true);

        event.action = KeyAction.press;
        event.key = Key.arrowUp;

        final result = encoder.encode(event);
        expect(result, '\x1bOA');
      });
    });

    group('setKittyFlags', () {
      test('uses Kitty protocol sequence', () {
        encoder.setKittyFlags(const KittyKeyFlags.all());

        event.action = KeyAction.press;
        event.key = Key.c;
        event.mods = const Mods.ctrl();
        event.utf8 = 'c';
        event.unshiftedCodepoint = 0x63;

        final result = encoder.encode(event);
        expect(result, contains('['));
      });

      test('returns long sequence without truncation', () {
        encoder.setKittyFlags(const KittyKeyFlags.all());

        event.action = KeyAction.press;
        event.key = Key.a;
        event.utf8 = 'a' * 100;
        event.unshiftedCodepoint = 0x61;

        final result = encoder.encode(event);
        expect(result, startsWith('\x1b'));
      });
    });

    group('sync', () {
      test('applies terminal back-arrow key mode', () {
        final terminal = Terminal(cols: 80, rows: 24);
        addTearDown(terminal.dispose);
        terminal.modeSet(const TerminalMode.backArrowKeyMode(), value: true);

        encoder.sync(terminal);
        event.action = KeyAction.press;
        event.key = Key.backspace;

        final result = encoder.encode(event);
        expect(result, '\x08');
      });
    });
  });
}
