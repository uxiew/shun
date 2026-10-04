@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('color utilities', () {
    group('parseColor', () {
      test('parses X11 color names', () {
        final color = parseColor('ForestGreen');
        expect(color, const RgbColor(34, 139, 34));
      });

      test('ignores surrounding spaces and tabs', () {
        final color = parseColor('\t ForestGreen \t');
        expect(color, const RgbColor(34, 139, 34));
      });

      test('throws for invalid color values', () {
        expect(
          () => parseColor('not-a-color'),
          throwsA(isA<InvalidValueException>()),
        );
      });
    });

    group('parsePaletteEntry', () {
      test('returns index and color', () {
        final entry = parsePaletteEntry('0x10=#282c34');
        expect(entry.index, 16);
        expect(entry.color, const RgbColor(40, 44, 52));
      });

      test('accepts surrounding spaces and tabs', () {
        final entry = parsePaletteEntry('\t 0b10000 = ForestGreen \t');
        expect(entry.index, 16);
        expect(entry.color, const RgbColor(34, 139, 34));
      });
    });

    group('defaultColorPalette', () {
      test('returns 256 colors', () {
        final palette = defaultColorPalette();
        expect(palette, hasLength(256));
        expect(palette, everyElement(isA<RgbColor>()));
      });
    });

    group('colorContrast', () {
      test('returns maximum contrast for black and white', () {
        final contrast = colorContrast(
          const RgbColor(0, 0, 0),
          const RgbColor(255, 255, 255),
        );
        expect(contrast, closeTo(21, 0.001));
      });
    });
  });
}
