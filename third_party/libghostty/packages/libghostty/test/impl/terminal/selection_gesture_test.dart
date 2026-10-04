@Tags(['ffi'])
library;

import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('SelectionGesture', () {
    late Terminal terminal;

    setUp(() {
      terminal = Terminal(cols: 80, rows: 24);
    });

    tearDown(() {
      terminal.dispose();
    });

    group('apply', () {
      test('drag produces a selection snapshot', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final press = SelectionGestureEvent.press();
        addTearDown(press.dispose);
        final drag = SelectionGestureEvent.drag();
        addTearDown(drag.dispose);
        press.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        drag.setRef(GridRef.at(terminal, const Position(row: 0, col: 2)));
        drag.setGeometry(
          const SelectionGestureGeometry(
            columns: 80,
            cellWidth: 8,
            paddingLeft: 0,
            screenHeight: 24,
          ),
        );
        gesture.apply(press);

        final selection = gesture.apply(drag);

        expect(terminal.formatSelection(selection: selection), 'AB');
      });
    });

    group('state', () {
      test('reports click count after press', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final press = SelectionGestureEvent.press();
        addTearDown(press.dispose);
        press.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));

        gesture.apply(press);

        expect(gesture.state.clickCount, 1);
      });

      test('reports custom press behavior', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final press = SelectionGestureEvent.press();
        addTearDown(press.dispose);
        press.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        press.setBehaviors(
          const SelectionGestureBehaviors(
            singleClick: .line,
            doubleClick: .word,
            tripleClick: .cell,
          ),
        );

        gesture.apply(press);

        expect(gesture.state.behavior, SelectionGestureBehavior.line);
      });
    });

    group('reset', () {
      test('clears click count', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final press = SelectionGestureEvent.press();
        addTearDown(press.dispose);
        press.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        gesture.apply(press);

        gesture.reset();

        expect(gesture.state.clickCount, 0);
      });
    });

    group('dispose', () {
      test('succeeds while terminal is alive', () {
        final gesture = SelectionGesture(terminal);

        expect(gesture.dispose, returnsNormally);
      });

      test('succeeds after terminal disposal', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final gesture = SelectionGesture(terminal);
        final press = SelectionGestureEvent.press();
        addTearDown(press.dispose);
        press.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        gesture.apply(press);

        terminal.dispose();

        expect(gesture.dispose, returnsNormally);
      });
    });

    group('SelectionGestureEvent', () {
      test('press applies with optional click metadata', () {
        terminal.write(Uint8List.fromList('ABCDE'.codeUnits));
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final press = SelectionGestureEvent.press();
        addTearDown(press.dispose);
        press.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        press.setPosition(4, 8);
        press.setRepeatDistance(12);
        press.setRepeatIntervalNs(500);
        press.setTimeNs(1);
        press.setWordBoundaryCodepoints('_'.codeUnits);

        gesture.apply(press);

        expect(gesture.state.clickCount, 1);
      });

      test('drag can produce a rectangular selection', () {
        terminal.write(Uint8List.fromList('ABC\r\nDEF'.codeUnits));
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final press = SelectionGestureEvent.press();
        addTearDown(press.dispose);
        final drag = SelectionGestureEvent.drag();
        addTearDown(drag.dispose);
        press.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        drag.setRef(GridRef.at(terminal, const Position(row: 1, col: 2)));
        drag.setRectangle(value: true);
        drag.setGeometry(
          const SelectionGestureGeometry(
            columns: 80,
            cellWidth: 8,
            paddingLeft: 0,
            screenHeight: 24,
          ),
        );
        gesture.apply(press);

        final selection = gesture.apply(drag);

        expect(selection?.rectangle, isTrue);
      });
    });
  });
}
