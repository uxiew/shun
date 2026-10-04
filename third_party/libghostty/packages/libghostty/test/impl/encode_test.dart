@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('FocusEvent', () {
    group('encode', () {
      test('returns focus sequences', () {
        expect(FocusEvent.gained.encode(), '\x1b[I');
        expect(FocusEvent.lost.encode(), '\x1b[O');
      });
    });
  });

  group('SizeReportStyle', () {
    group('encode', () {
      test('returns size report sequences', () {
        final mode2048 = SizeReportStyle.mode2048.encode(
          rows: 24,
          columns: 80,
          cellWidth: 8,
          cellHeight: 16,
        );
        expect(mode2048, startsWith('\x1b[48;'));
        expect(mode2048, endsWith('t'));
        expect(mode2048, contains('24'));
        expect(mode2048, contains('80'));

        final csi14T = SizeReportStyle.csi14T.encode(
          rows: 24,
          columns: 80,
          cellWidth: 8,
          cellHeight: 16,
        );
        expect(csi14T, startsWith('\x1b[4;'));
        expect(csi14T, endsWith('t'));

        final csi16T = SizeReportStyle.csi16T.encode(
          rows: 24,
          columns: 80,
          cellWidth: 8,
          cellHeight: 16,
        );
        expect(csi16T, startsWith('\x1b[6;'));
        expect(csi16T, endsWith('t'));

        final csi18T = SizeReportStyle.csi18T.encode(
          rows: 24,
          columns: 80,
          cellWidth: 8,
          cellHeight: 16,
        );
        expect(csi18T, startsWith('\x1b[8;'));
        expect(csi18T, endsWith('t'));
        expect(csi18T, contains('24'));
        expect(csi18T, contains('80'));
      });
    });
  });
}
