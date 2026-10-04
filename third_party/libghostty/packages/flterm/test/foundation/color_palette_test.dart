import 'package:flterm/src/foundation/color_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart'
    show RgbColor, defaultColorPalette, generateColorPalette;

void main() {
  group('ColorPalette', () {
    const bg = Color(0xFF181818);
    const fg = Color(0xFFD8D8D8);

    const ansiColors = [
      Color(0xFF282828),
      Color(0xFFCC4242),
      Color(0xFF66994C),
      Color(0xFFE5B566),
      Color(0xFF668ECC),
      Color(0xFFB266B2),
      Color(0xFF4CB2B2),
      Color(0xFFAAAAAA),
      Color(0xFF505050),
      Color(0xFFE66464),
      Color(0xFF8CBE6E),
      Color(0xFFF0C878),
      Color(0xFF82A0DC),
      Color(0xFFC882C8),
      Color(0xFF64C8C8),
      Color(0xFFDCDCDC),
    ];

    RgbColor toRgbColor(Color color) {
      return RgbColor(
        (color.r * 255.0).round(),
        (color.g * 255.0).round(),
        (color.b * 255.0).round(),
      );
    }

    Color toColor(RgbColor color) {
      return Color(color.toArgb32);
    }

    List<RgbColor> libghosttyBase() {
      final base = defaultColorPalette();
      for (var i = 0; i < ansiColors.length; i++) {
        base[i] = toRgbColor(ansiColors[i]);
      }
      return base;
    }

    void expectMatchesLibghosttyGenerated(
      ColorPalette palette, {
      required Color background,
      required Color foreground,
      required bool harmonious,
    }) {
      final expected = generateColorPalette(
        base: libghosttyBase(),
        background: toRgbColor(background),
        foreground: toRgbColor(foreground),
        harmonious: harmonious,
      ).map(toColor).toList();

      for (var i = 0; i < expected.length; i++) {
        expect(palette[i], expected[i], reason: 'index $i');
      }
    }

    void expectAnsiColors(ColorPalette palette) {
      for (var i = 0; i < 16; i++) {
        expect(palette[i], ansiColors[i], reason: 'index $i');
      }
    }

    group('constructor', () {
      late ColorPalette palette;

      setUp(
        () => palette = ColorPalette(
          ansiColors: ansiColors,
          background: bg,
          foreground: fg,
        ),
      );

      test('exposes background, foreground, and ansiColors as fields', () {
        expect(palette.background, bg);
        expect(palette.foreground, fg);
        expect(palette.ansiColors, ansiColors);
      });

      test('uses provided ANSI colors', () {
        expectAnsiColors(palette);
      });

      test('returns xterm cube colors', () {
        expect(palette[16], const Color(0xFF000000));
        expect(palette[231], const Color(0xFFFFFFFF));
        expect(palette[196], const Color(0xFFFF0000));
      });

      void expectXtermGrayscaleRamp(ColorPalette palette) {
        for (var i = 232; i < 256; i++) {
          final v = (i - 232) * 10 + 8;
          expect(palette[i], Color.fromARGB(255, v, v, v), reason: 'index $i');
        }
      }

      test('grayscale ramp values follow the standard formula', () {
        expectXtermGrayscaleRamp(palette);
      });

      void expectOpaqueColors(ColorPalette palette) {
        for (var i = 0; i < 256; i++) {
          expect((palette[i].a * 255.0).round(), 255, reason: 'index $i');
        }
      }

      test('returns opaque colors for all indices', () {
        expectOpaqueColors(palette);
      });

      test('equality and hashCode include background and foreground', () {
        final other = ColorPalette(
          ansiColors: ansiColors,
          background: bg,
          foreground: fg,
        );
        expect(palette, equals(other));
        expect(palette.hashCode, other.hashCode);

        final differentBg = ColorPalette(
          ansiColors: ansiColors,
          background: const Color(0xFF111111),
          foreground: fg,
        );
        expect(palette, isNot(equals(differentBg)));
      });

      test('copyWith rebuilds the palette in the same (xterm cube) mode', () {
        final newBg = palette.copyWith(background: const Color(0xFF111111));
        expect(newBg.background, const Color(0xFF111111));
        expect(newBg[16], const Color(0xFF000000));
      });

      test('requires exactly 16 ANSI colors', () {
        expect(
          () => ColorPalette(
            ansiColors: const [Color(0xFF000000)],
            background: bg,
            foreground: fg,
          ),
          throwsArgumentError,
        );
      });
    });

    group('generated', () {
      late ColorPalette palette;

      setUp(
        () => palette = ColorPalette.generated(
          ansiColors: ansiColors,
          background: bg,
          foreground: fg,
        ),
      );

      test('uses provided ANSI colors', () {
        expectAnsiColors(palette);
      });

      test('matches libghostty generation for dark themes', () {
        expectMatchesLibghosttyGenerated(
          palette,
          background: bg,
          foreground: fg,
          harmonious: false,
        );
      });

      test('matches libghostty generation for harmonious light themes', () {
        const lightBg = Color(0xFFF0F0F0);
        const lightFg = Color(0xFF1E1E1E);
        final lightPalette = ColorPalette.generated(
          ansiColors: ansiColors,
          background: lightBg,
          foreground: lightFg,
          harmonious: true,
        );

        expectMatchesLibghosttyGenerated(
          lightPalette,
          background: lightBg,
          foreground: lightFg,
          harmonious: true,
        );
      });

      test('matches libghostty generation for non-harmonious light themes', () {
        const lightBg = Color(0xFFF0F0F0);
        const lightFg = Color(0xFF1E1E1E);
        final lightPalette = ColorPalette.generated(
          ansiColors: ansiColors,
          background: lightBg,
          foreground: lightFg,
        );

        expectMatchesLibghosttyGenerated(
          lightPalette,
          background: lightBg,
          foreground: lightFg,
          harmonious: false,
        );
      });

      test('preserves ANSI colors skipped by generation', () {
        expectMatchesLibghosttyGenerated(
          palette,
          background: bg,
          foreground: fg,
          harmonious: false,
        );
        expectAnsiColors(palette);
      });

      test('copyWith preserves the generated mode', () {
        final modified = palette.copyWith(background: const Color(0xFF111111));
        expect(modified[16], const Color(0xFF111111));
      });

      test('requires exactly 16 ANSI colors', () {
        expect(
          () => ColorPalette.generated(
            ansiColors: const [Color(0xFF000000)],
            background: bg,
            foreground: fg,
          ),
          throwsArgumentError,
        );
      });
    });
  });
}
