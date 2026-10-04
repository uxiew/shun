@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('MouseEvent', () {
    late MouseEvent event;

    setUp(() => event = MouseEvent());

    tearDown(() => event.dispose());

    group('constructor', () {
      test('initializes default state', () {
        expect(event.action, MouseAction.press);
        expect(event.button, isNull);
        expect(event.mods, const Mods.none());
      });
    });

    group('accessors', () {
      test('store latest values', () {
        event.action = MouseAction.release;
        expect(event.action, MouseAction.release);

        event.action = MouseAction.motion;
        expect(event.action, MouseAction.motion);

        event.button = MouseButton.left;
        expect(event.button, MouseButton.left);

        event.button = MouseButton.right;
        expect(event.button, MouseButton.right);

        event.mods = const Mods.ctrl() | const Mods.shift();
        expect(event.mods.hasCtrl, isTrue);
        expect(event.mods.hasShift, isTrue);
        expect(event.mods.hasAlt, isFalse);

        event.setPosition(x: 10.5, y: 20.5);
        final (x, y) = event.position;
        expect(x, closeTo(10.5, 0.01));
        expect(y, closeTo(20.5, 0.01));
      });

      test('clears nullable button', () {
        event.button = MouseButton.left;
        event.clearButton();
        expect(event.button, isNull);
      });
    });
  });
}
