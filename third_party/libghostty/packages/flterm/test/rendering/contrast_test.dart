import 'package:flterm/src/rendering/contrast.dart';
import 'package:flutter_test/flutter_test.dart';

double ratio(int a, int b) =>
    contrastRatio(relativeLuminance(a), relativeLuminance(b));

int channel(int rgb, int shift) => (rgb >> shift) & 0xFF;

void main() {
  group('contrast (shun)', () {
    test('matches the WCAG reference values', () {
      expect(ratio(0x000000, 0xFFFFFF), closeTo(21, 0.01));
      expect(ratio(0xFFFFFF, 0xFFFFFF), closeTo(1, 0.0001));
      // WebAIM 的例子：#767676 对白是 4.54。
      expect(ratio(0x767676, 0xFFFFFF), closeTo(4.54, 0.01));
    });

    test('leaves colors that already meet the minimum alone', () {
      expect(contrastedRgb(0x000000, 0xFFFFFF, 3), 0x000000);
      expect(contrastedRgb(0xCC6666, 0x1D1F21, 3), 0xCC6666);
    });

    test('darkens yellow on white just enough and keeps it yellow', () {
      const yellow = 0xF0C674;
      final adjusted = contrastedRgb(yellow, 0xFFFFFF, 3);

      expect(ratio(adjusted, 0xFFFFFF), greaterThanOrEqualTo(3));
      // 刚好够，不是一路压到黑。
      expect(ratio(adjusted, 0xFFFFFF), lessThan(3.2));
      // 还是红 > 绿 > 蓝的黄色。
      expect(channel(adjusted, 16), greaterThan(channel(adjusted, 8)));
      expect(channel(adjusted, 8), greaterThan(channel(adjusted, 0)));
    });

    test('lifts black text on a dark background toward white', () {
      final adjusted = contrastedRgb(0x1D1F21, 0x1A1B26, 3);

      expect(ratio(adjusted, 0x1A1B26), greaterThanOrEqualTo(3));
      expect(
        relativeLuminance(adjusted),
        greaterThan(relativeLuminance(0x1D1F21)),
      );
    });

    test('text identical to the background becomes readable', () {
      final adjusted = contrastedRgb(0xFFFFFF, 0xFFFFFF, 3);

      expect(ratio(adjusted, 0xFFFFFF), greaterThanOrEqualTo(3));
    });

    test('a lighter foreground on a mid background still crosses over', () {
      // 背景偏暗中灰、前景略亮：往黑挤时对比度先降后升。
      const background = 0x808080;
      final adjusted = contrastedRgb(0x8A8A8A, background, 3);

      expect(ratio(adjusted, background), greaterThanOrEqualTo(3));
    });

    test('falls back to the extreme when even it is not enough', () {
      // 中灰上纯黑纯白都到不了 7。
      final adjusted = contrastedRgb(0x777777, 0x777777, 7);

      expect(adjusted, anyOf(0x000000, 0xFFFFFF));
    });
  });
}
