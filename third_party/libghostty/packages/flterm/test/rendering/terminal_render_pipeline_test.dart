@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flterm/src/foundation/cell_metrics.dart';
import 'package:flterm/src/foundation/cell_range.dart';
import 'package:flterm/src/foundation/terminal_theme.dart';
import 'package:flterm/src/links/link_snapshot.dart';
import 'package:flterm/src/rendering/atlas/atlas.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flterm/src/rendering/terminal_render_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  group('TerminalRenderPipeline', () {
    const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

    AtlasConfig config({double fontSize = 14}) {
      return AtlasConfig(
        fontSize: fontSize,
        fontWeight: FontWeight.normal,
        fontFamily: 'monospace',
        fontFamilyFallback: const [],
        metrics: metrics,
        devicePixelRatio: 1.0,
      );
    }

    void paint(TerminalRenderPipeline pipeline) {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      pipeline.paint(canvas);
      recorder.endRecording().dispose();
    }

    void writeUtf8(Terminal terminal, String text) {
      terminal.write(Uint8List.fromList(utf8.encode(text)));
    }

    late Terminal terminal;
    late Atlas atlas;
    late TerminalPaintState state;
    late TerminalRenderPipeline pipeline;

    setUp(() {
      terminal = Terminal(cols: 8, rows: 2);
      atlas = Atlas(config());
      state = TerminalPaintState(TerminalTheme.dark(), metrics)
        ..cols = 8
        ..rows = 2;
      pipeline = TerminalRenderPipeline(
        atlas: atlas,
        state: state,
        onImageReady: () {},
      )..configureGrid(2, 8);
    });

    tearDown(() {
      pipeline.dispose();
      atlas.dispose();
      terminal.dispose();
    });

    test('sync resolves cursor glyph and paints current frame', () {
      writeUtf8(terminal, 'A\x1b[1;1H');

      pipeline.sync(terminal, terminalDirty: true);

      expect(state.cursor.visible, isTrue);
      expect(state.cursorAtlasEntry, isNotNull);
      paint(pipeline);
    });

    test('bindAtlas keeps the frame pipeline configured', () {
      writeUtf8(terminal, 'A\x1b[1;1H');
      pipeline.sync(terminal, terminalDirty: true);

      final nextAtlas = Atlas(config(fontSize: 16));
      addTearDown(nextAtlas.dispose);

      pipeline.bindAtlas(nextAtlas);
      pipeline.sync(terminal, terminalDirty: false);

      expect(state.cursorAtlasEntry, isNotNull);
      paint(pipeline);
    });

    test('selection changes repaint through terminal dirty state', () {
      writeUtf8(terminal, 'hello');
      pipeline.sync(terminal, terminalDirty: true);

      terminal.selection = Selection.fromRefs(
        start: GridRef.at(terminal, const Position(row: 0, col: 1)),
        end: GridRef.at(terminal, const Position(row: 0, col: 2)),
      );

      pipeline.sync(terminal, terminalDirty: true);

      paint(pipeline);
    });

    test('sync accepts prepared link snapshots', () {
      writeUtf8(terminal, 'https://a.test');

      pipeline.sync(
        terminal,
        terminalDirty: true,
        linkSnapshot: LinkSnapshot.highlighted(
          const CellRange(
            start: Position(row: 0, col: 0),
            end: Position(row: 0, col: 13),
          ),
        ),
      );

      paint(pipeline);
    });
  });
}
