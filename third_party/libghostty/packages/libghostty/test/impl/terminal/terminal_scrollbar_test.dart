@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('Scrollbar', () {
    group('constructor', () {
      test('stores fields', () {
        const sb = Scrollbar(total: 100, offset: 10, visible: 24);
        expect(sb.total, 100);
        expect(sb.offset, 10);
        expect(sb.visible, 24);
      });
    });
  });

  group('Terminal', () {
    group('scrollbar', () {
      test('returns current scrollbar state', () {
        final terminal = Terminal(cols: 80, rows: 24);
        addTearDown(terminal.dispose);
        final sb = terminal.scrollbar;
        expect(sb, isA<Scrollbar>());
        expect(sb.visible, greaterThan(0));
      });
    });
  });
}
