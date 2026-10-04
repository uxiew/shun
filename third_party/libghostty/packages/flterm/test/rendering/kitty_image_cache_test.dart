@Tags(['ffi'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flterm/src/rendering/kitty_image_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  group('KittyImageCache', () {
    Future<ui.Image> testImage() {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList([0xff, 0xff, 0xff, 0xff]),
        1,
        1,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return completer.future;
    }

    group('dispose', () {
      test('clears ready entries', () async {
        final cache = KittyImageCache(onImageReady: () {});
        addTearDown(cache.dispose);
        final image = await testImage();
        cache.putReady(1, image);

        cache.dispose();

        expect(cache.lookupById(1), isNull);
      });

      test('allows repeated calls', () {
        final cache = KittyImageCache(onImageReady: () {});
        addTearDown(cache.dispose);
        cache.dispose();

        expect(cache.dispose, returnsNormally);
      });
    });

    group('lookup', () {
      Uint8List transmitPixel({required int id, required List<int> rgb}) {
        final payload = base64Encode(rgb);
        return Uint8List.fromList(
          '\x1b_Gf=24,s=1,v=1,a=t,i=$id;$payload\x1b\\'.codeUnits,
        );
      }

      late Terminal terminal;

      setUp(() {
        terminal = Terminal(cols: 4, rows: 2)..kittyImageStorageLimit = 1 << 20;
      });

      tearDown(() {
        terminal.dispose();
      });

      test('invalidates ready entry when image generation changes', () async {
        final cache = KittyImageCache(onImageReady: () {});
        addTearDown(cache.dispose);
        final decoded = await testImage();
        cache.putReady(7, decoded);
        terminal.write(transmitPixel(id: 7, rgb: [0xff, 0x00, 0x00]));
        final image = KittyGraphics.of(terminal)!.image(7)!;

        final entry = cache.lookup(image);

        expect(entry, isA<KittyImagePending>());
      });

      test('discards stale pending decode after generation changes', () async {
        final callbacks = <ui.ImageDecoderCallback>[];
        final cache = KittyImageCache(
          onImageReady: () {},
          decodeImage: (_, _, _, _, callback) {
            callbacks.add(callback);
          },
        );
        addTearDown(cache.dispose);
        final stale = await testImage();
        terminal.write(transmitPixel(id: 8, rgb: [0xff, 0x00, 0x00]));
        final staleImage = KittyGraphics.of(terminal)!.image(8)!;
        cache.lookup(staleImage);
        terminal.write(transmitPixel(id: 8, rgb: [0x00, 0xff, 0x00]));
        final currentImage = KittyGraphics.of(terminal)!.image(8)!;
        cache.lookup(currentImage);

        callbacks[0](stale);

        expect(cache.lookupById(8), isA<KittyImagePending>());
      });
    });
  });
}
