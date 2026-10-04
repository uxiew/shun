@Tags(['ffi'])
library;

import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('Terminal', () {
    group('kittyGraphics', () {
      late Terminal terminal;

      setUp(() {
        terminal = Terminal(cols: 80, rows: 24);
        terminal.kittyImageStorageLimit = 1 << 20;
      });

      tearDown(() {
        terminal.dispose();
      });

      test('returns a handle when enabled at build time', () {
        expect(KittyGraphics.of(terminal), isNotNull);
      });

      group('image', () {
        test('returns null for an unknown id', () {
          expect(KittyGraphics.of(terminal)?.image(99999), isNull);
        });

        test('returns metadata after transmit APC', () {
          terminal.write(_transmitRedPixel());

          final image = KittyGraphics.of(terminal)?.image(42);
          expect(image, isNotNull);
          expect(image!.id, 42);
          expect(image.width, 1);
          expect(image.height, 1);
          expect(image.format, KittyImageFormat.rgb);
        });

        test('returns decoded RGB bytes', () {
          terminal.write(_transmitRedPixel(id: 7));

          final image = KittyGraphics.of(terminal)!.image(7)!;
          expect(
            image.pixelData,
            equals(Uint8List.fromList([0xff, 0x00, 0x00])),
          );
        });
      });

      group('setApcBufferLimit', () {
        test('rejects oversized payloads', () {
          terminal.setApcBufferLimit(1);

          terminal.write(_transmitRedPixel(id: 8));

          expect(KittyGraphics.of(terminal)!.image(8), isNull);
        });

        test('restores default limit when cleared', () {
          terminal.setApcBufferLimit(1);
          terminal.setApcBufferLimit(null);

          terminal.write(_transmitRedPixel(id: 9));

          expect(KittyGraphics.of(terminal)!.image(9), isNotNull);
        });
      });

      group('setKittyApcBufferLimit', () {
        test('rejects oversized payloads', () {
          terminal.setKittyApcBufferLimit(1);

          terminal.write(_transmitRedPixel(id: 10));

          expect(KittyGraphics.of(terminal)!.image(10), isNull);
        });

        test('restores default limit when cleared', () {
          terminal.setKittyApcBufferLimit(1);
          terminal.setKittyApcBufferLimit(null);

          terminal.write(_transmitRedPixel(id: 11));

          expect(KittyGraphics.of(terminal)!.image(11), isNotNull);
        });
      });
    });
  });

  group('LibGhostty', () {
    group('setPngDecoder', () {
      late Terminal terminal;

      setUp(() {
        terminal = Terminal(cols: 80, rows: 24);
        terminal.kittyImageStorageLimit = 1 << 20;
      });

      tearDown(() {
        terminal.dispose();
        LibGhostty.clearPngDecoder();
      });

      test('uses callback result for PNG payload', () {
        final pngBytesSeen = <Uint8List>[];
        LibGhostty.setPngDecoder((bytes) {
          pngBytesSeen.add(Uint8List.fromList(bytes));
          return (
            width: 2,
            height: 1,
            rgba: Uint8List.fromList([
              0xff,
              0x00,
              0x00,
              0xff,
              0x00,
              0xff,
              0x00,
              0xff,
            ]),
          );
        });

        terminal.write(
          Uint8List.fromList('\x1b_Gf=100,a=t,i=55;aGVsbG8=\x1b\\'.codeUnits),
        );

        expect(pngBytesSeen, hasLength(1));
        final image = KittyGraphics.of(terminal)!.image(55);
        expect(image, isNotNull);
        expect(image!.width, 2);
        expect(image.height, 1);
        expect(image.format, KittyImageFormat.rgba);
        expect(image.pixelData, hasLength(8));
      });

      test('rejects payload when callback returns null', () {
        LibGhostty.setPngDecoder((_) => null);

        terminal.write(
          Uint8List.fromList('\x1b_Gf=100,a=t,i=56;aGVsbG8=\x1b\\'.codeUnits),
        );

        expect(KittyGraphics.of(terminal)!.image(56), isNull);
      });

      test('clearPngDecoder stops routing to callback', () {
        var called = 0;
        LibGhostty.setPngDecoder((_) {
          called++;
          return (width: 1, height: 1, rgba: Uint8List(4));
        });
        LibGhostty.clearPngDecoder();

        terminal.write(
          Uint8List.fromList('\x1b_Gf=100,a=t,i=57;aGVsbG8=\x1b\\'.codeUnits),
        );
        expect(called, 0);
        expect(KittyGraphics.of(terminal)!.image(57), isNull);
      });
    });
  });

  group('KittyGraphics', () {
    group('placements', () {
      late Terminal terminal;

      setUp(() {
        terminal = Terminal(cols: 80, rows: 24);
        terminal.kittyImageStorageLimit = 1 << 20;
      });

      tearDown(() {
        terminal.dispose();
      });

      test('returns empty list when no placements exist', () {
        expect(KittyGraphics.of(terminal)?.placements(), isEmpty);
      });

      test('captures placement emitted by transmit and display APC', () {
        terminal.write(
          Uint8List.fromList(
            '\x1b_Gf=24,s=1,v=1,a=T,i=11,c=2,r=1;/wAA\x1b\\'.codeUnits,
          ),
        );

        final placements = KittyGraphics.of(terminal)!.placements();
        expect(placements, hasLength(1));
        final p = placements.single;
        expect(p.imageId, 11);
        expect(p.isVirtual, isFalse);
        expect(p.renderInfo.viewportVisible, isTrue);
        expect(p.renderInfo.viewportCol, 0);
        expect(p.renderInfo.viewportRow, 0);
        expect(p.renderInfo.gridCols, 2);
        expect(p.renderInfo.gridRows, 1);
        expect(p.renderInfo.sourceWidth, 1);
        expect(p.renderInfo.sourceHeight, 1);
      });
    });
  });
}

Uint8List _transmitRedPixel({int id = 42}) {
  return Uint8List.fromList(
    '\x1b_Gf=24,s=1,v=1,a=t,i=$id;/wAA\x1b\\'.codeUnits,
  );
}
