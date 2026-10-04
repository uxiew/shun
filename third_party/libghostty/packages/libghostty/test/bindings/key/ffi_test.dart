@Tags(['ffi'])
library;

import 'package:libghostty/src/bindings/key/ffi.dart';
import 'package:libghostty/src/generated/libghostty_enums.g.dart';
import 'package:test/test.dart';

void main() {
  group('FfiKeyBindings', () {
    late FfiKeyBindings bindings;

    setUp(() {
      bindings = FfiKeyBindings();
    });

    test('creates and releases a key event', () {
      final event = bindings.keyEventNew();
      addTearDown(() => bindings.keyEventFree(event));

      expect(event.value, isNonZero);
    });

    test('round trips key event state', () {
      final event = bindings.keyEventNew();
      addTearDown(() => bindings.keyEventFree(event));

      bindings.keyEventSetAction(event, .press);
      bindings.keyEventSetKey(event, .c);
      bindings.keyEventSetMods(event, 4);
      bindings.keyEventSetConsumedMods(event, 2);
      bindings.keyEventSetComposing(event, composing: true);
      bindings.keyEventSetUnshiftedCodepoint(event, 0x63);

      expect(bindings.keyEventGetAction(event), KeyAction.press);
      expect(bindings.keyEventGetKey(event), Key.c);
      expect(bindings.keyEventGetMods(event), 4);
      expect(bindings.keyEventGetConsumedMods(event), 2);
      expect(bindings.keyEventGetComposing(event), isTrue);
      expect(bindings.keyEventGetUnshiftedCodepoint(event), 0x63);
    });

    test('replaces retained UTF-8 text and releases it with the event', () {
      final event = bindings.keyEventNew();
      addTearDown(() => bindings.keyEventFree(event));

      bindings.keyEventSetUtf8(event, 'first');
      bindings.keyEventSetUtf8(event, 'second');
      bindings.keyEventSetUtf8(event, null);

      expect(bindings.keyEventGetUtf8(event), isNull);
    });

    test('encodes a key event and retries an out-of-space buffer', () {
      final event = bindings.keyEventNew();
      final encoder = bindings.keyEncoderNew();
      addTearDown(() {
        bindings.keyEncoderFree(encoder);
        bindings.keyEventFree(event);
      });

      bindings.keyEventSetAction(event, .press);
      bindings.keyEventSetKey(event, .c);
      bindings.keyEventSetUtf8(event, 'c');

      expect(bindings.keyEncoderEncode(encoder, event), isA<String>());
    });
  });
}
