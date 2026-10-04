@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation/cell_metrics.dart';
import 'package:flterm/src/foundation/terminal_theme.dart';
import 'package:flterm/src/rendering/kitty_image_cache.dart';
import 'package:flterm/src/rendering/kitty_placement_cache.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  group('KittyPlacementCache', () {
    const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

    void writePlacedImage(Terminal terminal) {
      final payload = base64Encode([0xff, 0x00, 0x00]);
      terminal.write(
        Uint8List.fromList(
          '\x1b_Gf=24,s=1,v=1,a=T,i=11,c=1,r=1;$payload\x1b\\'.codeUnits,
        ),
      );
    }

    late Terminal terminal;
    late TerminalPaintState state;
    late KittyImageCache images;
    late KittyPlacementCache placements;

    setUp(() {
      terminal = Terminal(cols: 8, rows: 2)..kittyImageStorageLimit = 1 << 20;
      state = TerminalPaintState(TerminalTheme.dark(), metrics)
        ..cols = 8
        ..rows = 2;
      images = KittyImageCache(onImageReady: () {});
      placements = KittyPlacementCache(state: state, images: images);
      writePlacedImage(terminal);
      placements.sync(terminal, geometryDirty: false);
    });

    tearDown(() {
      images.dispose();
      terminal.dispose();
    });

    group('sync', () {
      test('returns false when generation and geometry are unchanged', () {
        final rebuilt = placements.sync(terminal, geometryDirty: false);

        expect(rebuilt, isFalse);
      });

      test('returns true when geometry changes', () {
        state.devicePixelRatio = 2.0;

        final rebuilt = placements.sync(terminal, geometryDirty: false);

        expect(rebuilt, isTrue);
      });

      test('removes snapshots hidden by terminal scrolling', () {
        terminal.write(Uint8List.fromList('\x1b[2;1H\n'.codeUnits));

        placements.sync(terminal, geometryDirty: true);

        expect(placements.snapshots, isEmpty);
      });
    });
  });
}
