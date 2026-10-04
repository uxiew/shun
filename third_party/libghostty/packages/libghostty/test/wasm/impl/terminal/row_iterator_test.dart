@Tags(['wasm'])
library;

import 'dart:typed_data' show Uint8List;

import 'package:libghostty/libghostty.dart'
    show
        GridRef,
        Position,
        RenderState,
        RowIterator,
        Selection,
        SemanticPrompt,
        Terminal;
import 'package:test/test.dart';

import '../../helpers/setup.dart';

void main() {
  setUpAll(setUpWasm);

  group('RowIterator', () {
    late Terminal terminal;
    late RenderState renderState;
    late RowIterator rows;

    setUp(() {
      terminal = Terminal(cols: 10, rows: 3);
      renderState = RenderState();
      rows = RowIterator();
    });

    tearDown(() {
      rows.dispose();
      renderState.dispose();
      terminal.dispose();
    });

    group('properties', () {
      test('returns content flags for an empty row', () {
        renderState.update(terminal);
        rows.reset(renderState);
        rows.next();

        expect(rows.hasGrapheme, isFalse);
        expect(rows.hasStyled, isFalse);
        expect(rows.hasHyperlink, isFalse);
        expect(rows.hasKittyVirtualPlaceholder, isFalse);
        expect(rows.semanticPrompt, SemanticPrompt.none);
      });

      test('reports styled rows', () {
        terminal.write(Uint8List.fromList('\x1b[1mBold'.codeUnits));
        renderState.update(terminal);
        rows.reset(renderState);
        rows.next();

        final result = rows.hasStyled;

        expect(result, isTrue);
      });

      test('tracks row position', () {
        renderState.update(terminal);
        rows.reset(renderState);
        rows.next();
        final first = rows.index;
        rows.next();

        final second = rows.index;

        expect(first, 0);
        expect(second, 1);
      });
    });

    void installSelection() {
      terminal.selection = Selection.fromRefs(
        start: GridRef.at(terminal, const Position(row: 1, col: 1)),
        end: GridRef.at(terminal, const Position(row: 1, col: 3)),
      );
    }

    void bindRows() {
      renderState.update(terminal);
      rows.reset(renderState);
    }

    void moveToRow(int row) {
      for (var i = 0; i <= row; i++) {
        expect(rows.next(), isTrue);
      }
    }

    int rowCount() {
      var count = 0;
      rows.reset(renderState);
      while (rows.next()) {
        count++;
      }
      return count;
    }

    group('selection', () {
      test('returns null for an unselected row', () {
        installSelection();
        bindRows();
        moveToRow(0);

        final result = rows.selection;

        expect(result, isNull);
      });

      test('returns row-local selected columns', () {
        installSelection();
        bindRows();
        moveToRow(1);

        final result = rows.selection;

        expect(result, (startCol: 1, endCol: 3));
      });
    });

    group('reset', () {
      test('rewinds iteration', () {
        terminal.write(Uint8List.fromList('Hello'.codeUnits));
        renderState.update(terminal);
        final first = rowCount();

        final second = rowCount();

        expect(second, first);
      });
    });
  });
}
