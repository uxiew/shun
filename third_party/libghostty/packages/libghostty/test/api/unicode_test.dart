import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

import '../helpers/setup.dart';

void main() {
  setUp(() => testEnvironment);

  group('unicode utilities', () {
    group('unicodeCodepointWidth', () {
      test('returns zero for combining marks', () {
        final width = unicodeCodepointWidth(0x0301);
        expect(width, 0);
      });

      test('returns two for wide codepoints', () {
        final width = unicodeCodepointWidth(0x1F600);
        expect(width, 2);
      });
    });

    group('unicodeGraphemeWidth', () {
      test('returns consumed count and width', () {
        final result = unicodeGraphemeWidth([0x1F469, 0x200D, 0x1F4BB]);
        expect(result.consumed, 3);
        expect(result.width, 2);
      });
    });
  });
}
