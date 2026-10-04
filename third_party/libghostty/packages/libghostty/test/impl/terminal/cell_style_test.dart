@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('Style', () {
    group('constructor', () {
      test('initializes default state', () {
        const style = Style();
        expect(style.bold, isFalse);
        expect(style.italic, isFalse);
        expect(style.faint, isFalse);
        expect(style.blink, isFalse);
        expect(style.inverse, isFalse);
        expect(style.overline, isFalse);
        expect(style.invisible, isFalse);
        expect(style.strikethrough, isFalse);
        expect(style.foreground, isA<DefaultColor>());
        expect(style.background, isA<DefaultColor>());
        expect(style.underlineColor, isNull);
        expect(style.underline, UnderlineStyle.none);
      });

      test('stores provided fields', () {
        const style = Style(
          bold: true,
          italic: true,
          faint: true,
          blink: true,
          inverse: true,
          overline: true,
          invisible: true,
          strikethrough: true,
          foreground: RgbColor(255, 128, 0),
          background: PaletteColor(42),
          underline: UnderlineStyle.curly,
          underlineColor: RgbColor(10, 20, 30),
        );
        expect(style.bold, isTrue);
        expect(style.italic, isTrue);
        expect(style.faint, isTrue);
        expect(style.blink, isTrue);
        expect(style.inverse, isTrue);
        expect(style.overline, isTrue);
        expect(style.invisible, isTrue);
        expect(style.strikethrough, isTrue);
        expect(style.foreground, const RgbColor(255, 128, 0));
        expect(style.background, const PaletteColor(42));
        expect(style.underline, UnderlineStyle.curly);
        expect(style.underlineColor, const RgbColor(10, 20, 30));
      });
    });
  });
}
