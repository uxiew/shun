@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('MouseEncoder', () {
    late MouseEncoder encoder;
    late MouseEvent event;

    setUp(() {
      encoder = MouseEncoder();
      event = MouseEvent()
        ..action = MouseAction.press
        ..button = MouseButton.left
        ..setPosition(x: 10.0, y: 5.0);
    });

    tearDown(() {
      event.dispose();
      encoder.dispose();
    });

    group('encode', () {
      test('returns empty without tracking mode', () {
        expect(encoder.encode(event), isEmpty);
      });

      test('returns SGR sequence after terminal sync enables tracking', () {
        final terminal = Terminal(cols: 80, rows: 24);
        addTearDown(terminal.dispose);

        terminal.write(.fromList('\x1b[?1000h\x1b[?1006h'.codeUnits));

        encoder.sync(terminal);
        encoder.setSize(
          const MouseEncoderSize(
            screenWidth: 640,
            screenHeight: 384,
            cellWidth: 8,
            cellHeight: 16,
          ),
        );

        event
          ..action = MouseAction.press
          ..button = MouseButton.left
          ..setPosition(x: 24.0, y: 32.0);

        final result = encoder.encode(event);
        expect(result, startsWith('\x1b[<'));
        expect(result, endsWith('M'));
      });

      test('returns SGR sequence with manual tracking and format', () {
        encoder.setTrackingMode(MouseTracking.normal);
        encoder.setFormat(MouseFormat.sgr);
        encoder.setSize(
          const MouseEncoderSize(
            screenWidth: 640,
            screenHeight: 384,
            cellWidth: 8,
            cellHeight: 16,
          ),
        );

        event
          ..action = MouseAction.press
          ..button = MouseButton.left
          ..setPosition(x: 24.0, y: 32.0);

        final result = encoder.encode(event);
        expect(result, startsWith('\x1b[<'));
        expect(result, endsWith('M'));
      });
    });

    group('setSize', () {
      test('accepts padding values', () {
        encoder.setSize(
          const MouseEncoderSize(
            screenWidth: 800,
            screenHeight: 600,
            cellWidth: 8,
            cellHeight: 16,
            paddingTop: 4,
            paddingBottom: 4,
            paddingLeft: 4,
            paddingRight: 4,
          ),
        );

        expect(encoder.encode(event), isEmpty);
      });
    });

    group('reset', () {
      test('clears manually configured tracking mode', () {
        encoder.setTrackingMode(MouseTracking.normal);
        encoder.setFormat(MouseFormat.sgr);
        encoder.reset();

        expect(encoder.encode(event), isEmpty);
      });
    });
  });
}
