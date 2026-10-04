@Tags(['wasm'])
library;

import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

import '../helpers/setup.dart';

void main() {
  setUpAll(setUpWasm);

  group('Selection', () {
    late Terminal terminal;

    setUp(() {
      terminal = Terminal(cols: 80, rows: 24);
    });

    tearDown(() {
      terminal.dispose();
    });

    group('fromRefs', () {
      test('preserves endpoint refs', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final start = GridRef.at(terminal, const Position(row: 0, col: 0));
        final end = GridRef.at(terminal, const Position(row: 0, col: 2));

        final selection = Selection.fromRefs(start: start, end: end);

        expect(selection.start, start);
        expect(selection.end, end);
      });

      test('preserves rectangle mode', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final start = GridRef.at(terminal, const Position(row: 0, col: 0));
        final end = GridRef.at(terminal, const Position(row: 0, col: 2));

        final selection = Selection.fromRefs(
          start: start,
          end: end,
          rectangle: true,
        );

        expect(selection.rectangle, isTrue);
      });

      test('rejects refs from another terminal', () {
        final other = Terminal(cols: 80, rows: 24);
        addTearDown(other.dispose);
        final start = GridRef.at(terminal, const Position(row: 0, col: 0));
        final end = GridRef.at(other, const Position(row: 0, col: 0));

        expect(
          () => Selection.fromRefs(start: start, end: end),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('contains', () {
      test('reports included points', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final selection = Selection.fromRefs(
          start: GridRef.at(terminal, const Position(row: 0, col: 0)),
          end: GridRef.at(terminal, const Position(row: 0, col: 2)),
        );

        final contains = selection.contains(const Position(row: 0, col: 1));

        expect(contains, isTrue);
      });

      test('reports excluded points', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final selection = Selection.fromRefs(
          start: GridRef.at(terminal, const Position(row: 0, col: 0)),
          end: GridRef.at(terminal, const Position(row: 0, col: 2)),
        );

        final contains = selection.contains(const Position(row: 0, col: 4));

        expect(contains, isFalse);
      });
    });

    group('adjust', () {
      test('moves the logical end endpoint', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final selection = Selection.fromRefs(
          start: GridRef.at(terminal, const Position(row: 0, col: 0)),
          end: GridRef.at(terminal, const Position(row: 0, col: 1)),
        );

        final adjusted = selection.adjust(.right);

        expect(adjusted.format(), 'ABC');
      });
    });

    group('ordered', () {
      test('returns requested endpoint order', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final selection = Selection.fromRefs(
          start: GridRef.at(terminal, const Position(row: 0, col: 2)),
          end: GridRef.at(terminal, const Position(row: 0, col: 0)),
        );

        final ordered = selection.ordered(.forward);

        expect(ordered.order, SelectionOrder.forward);
      });
    });

    group('equal', () {
      test('compares selections through libghostty', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final selection = Selection.fromRefs(
          start: GridRef.at(terminal, const Position(row: 0, col: 0)),
          end: GridRef.at(terminal, const Position(row: 0, col: 2)),
        );
        final other = Selection.fromRefs(
          start: GridRef.at(terminal, const Position(row: 0, col: 0)),
          end: GridRef.at(terminal, const Position(row: 0, col: 2)),
        );

        final equal = selection.equal(other);

        expect(equal, isTrue);
      });

      test('rejects selections from another terminal', () {
        final other = Terminal(cols: 80, rows: 24);
        addTearDown(other.dispose);
        final selection = Selection.fromRefs(
          start: GridRef.at(terminal, const Position(row: 0, col: 0)),
          end: GridRef.at(terminal, const Position(row: 0, col: 2)),
        );
        final otherSelection = Selection.fromRefs(
          start: GridRef.at(other, const Position(row: 0, col: 0)),
          end: GridRef.at(other, const Position(row: 0, col: 2)),
        );

        expect(
          () => selection.equal(otherSelection),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('format', () {
      test('returns selected content', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final selection = Selection.fromRefs(
          start: GridRef.at(terminal, const Position(row: 0, col: 1)),
          end: GridRef.at(terminal, const Position(row: 0, col: 3)),
        );

        final text = selection.format();

        expect(text, 'BCD');
      });
    });
  });
}
