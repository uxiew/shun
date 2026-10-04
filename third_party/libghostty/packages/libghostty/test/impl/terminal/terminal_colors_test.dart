@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('Terminal', () {
    late Terminal terminal;

    setUp(() => terminal = Terminal(cols: 80, rows: 24));

    tearDown(() => terminal.dispose());

    group('colors', () {
      test('render state returns foreground, background, and palette', () {
        final renderState = RenderState();
        addTearDown(renderState.dispose);
        renderState.update(terminal);
        final colors = renderState.colors;
        expect(colors.foreground, isA<RgbColor>());
        expect(colors.background, isA<RgbColor>());
        expect(colors.palette, hasLength(256));
      });
    });

    group('color overrides', () {
      test('stores colors', () {
        terminal.foreground = const RgbColor(255, 0, 0);
        expect(terminal.foreground, const RgbColor(255, 0, 0));

        terminal.background = const RgbColor(0, 255, 0);
        expect(terminal.background, const RgbColor(0, 255, 0));

        terminal.cursorColor = const RgbColor(0, 0, 255);
        expect(terminal.cursorColor, const RgbColor(0, 0, 255));
      });

      test('clears colors', () {
        terminal.foreground = const RgbColor(255, 0, 0);
        terminal.foreground = null;
        expect(terminal.foreground, isNull);

        terminal.background = const RgbColor(0, 255, 0);
        terminal.background = null;
        expect(terminal.background, isNull);

        terminal.cursorColor = const RgbColor(0, 0, 255);
        terminal.cursorColor = null;
        expect(terminal.cursorColor, isNull);
      });

      test('foreground matches default when no OSC override exists', () {
        terminal.foreground = const RgbColor(100, 100, 100);
        expect(terminal.foreground, const RgbColor(100, 100, 100));
        expect(terminal.foregroundDefault, const RgbColor(100, 100, 100));
      });
    });

    group('palette', () {
      test('returns 256 RGB colors', () {
        final palette = terminal.palette;
        expect(palette, hasLength(256));
        expect(palette, everyElement(isA<RgbColor>()));
      });

      test('stores colors', () {
        final colors = List.generate(256, (i) => RgbColor(i, 0, 0));
        terminal.palette = colors;
        final result = terminal.palette;
        expect(result, hasLength(256));
        expect(result[0], const RgbColor(0, 0, 0));
        expect(result[128], const RgbColor(128, 0, 0));
        expect(result[255], const RgbColor(255, 0, 0));
      });

      test('resets to defaults when set to null', () {
        final original = terminal.palette;
        terminal.palette = List.generate(256, (i) => RgbColor(i, i, i));
        terminal.palette = null;
        expect(terminal.palette, original);
      });
    });
  });
}
