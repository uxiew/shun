@Tags(['ffi'])
library;

import 'package:libghostty/src/bindings/mouse/ffi.dart';
import 'package:libghostty/src/generated/libghostty_enums.g.dart';
import 'package:libghostty/src/types/geometry.dart';
import 'package:test/test.dart';

void main() {
  group('FfiMouseBindings', () {
    late FfiMouseBindings bindings;

    setUp(() {
      bindings = const FfiMouseBindings();
    });

    test('round trips mouse event state and optional button', () {
      final event = bindings.mouseEventNew();
      addTearDown(() => bindings.mouseEventFree(event));

      expect(bindings.mouseEventGetButton(event), isNull);
      bindings.mouseEventSetAction(event, MouseAction.press);
      bindings.mouseEventSetButton(event, MouseButton.left);
      bindings.mouseEventSetMods(event, 4);
      bindings.mouseEventSetPosition(event, 12.5, 8.25);

      expect(bindings.mouseEventGetAction(event), MouseAction.press);
      expect(bindings.mouseEventGetButton(event), MouseButton.left);
      expect(bindings.mouseEventGetMods(event), 4);
      expect(bindings.mouseEventGetPosition(event), (12.5, 8.25));

      bindings.mouseEventClearButton(event);
      expect(bindings.mouseEventGetButton(event), isNull);
    });

    test('configures and encodes a mouse event', () {
      final event = bindings.mouseEventNew();
      final encoder = bindings.mouseEncoderNew();
      addTearDown(() {
        bindings.mouseEncoderFree(encoder);
        bindings.mouseEventFree(event);
      });

      bindings.mouseEventSetAction(event, MouseAction.press);
      bindings.mouseEventSetButton(event, MouseButton.left);
      bindings.mouseEventSetPosition(event, 12, 8);
      bindings.mouseEncoderSetSize(
        encoder,
        const MouseEncoderSize(
          screenWidth: 800,
          screenHeight: 600,
          cellWidth: 10,
          cellHeight: 20,
        ),
      );
      bindings.mouseEncoderSetFormat(encoder, MouseFormat.x10);
      bindings.mouseEncoderSetTrackingMode(encoder, MouseTrackingMode.normal);

      expect(bindings.mouseEncoderEncode(encoder, event), isA<String>());
    });
  });
}
