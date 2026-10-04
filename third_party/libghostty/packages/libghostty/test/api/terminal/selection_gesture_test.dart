import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

import '../../helpers/setup.dart';

void main() {
  setUp(() => testEnvironment);

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
      test('is safe to call twice', () {
        final gesture = SelectionGesture(terminal);

        gesture.dispose();

        expect(gesture.dispose, returnsNormally);
      });

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

      test('rejects all operations after disposal', () {
        final gesture = SelectionGesture(terminal);
        gesture.dispose();

        expect(() => gesture.state, throwsStateError);
        expect(gesture.reset, throwsStateError);
      });

      test('throws when used after terminal disposal', () {
        final gesture = SelectionGesture(terminal);
        terminal.dispose();

        expect(() => gesture.state, throwsA(isA<StateError>()));

        gesture.dispose();
      });
    });

    group('SelectionGestureEvent', () {
      group('dispose', () {
        test('is safe to call twice', () {
          final event = SelectionGestureEvent.press();

          event.dispose();

          expect(event.dispose, returnsNormally);
        });

        test('throws when changed after disposal', () {
          final event = SelectionGestureEvent.press();
          event.dispose();

          expect(() => event.setPosition(1, 1), throwsA(isA<StateError>()));
        });
      });

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

      test('rejects a grid reference from another terminal', () {
        final other = Terminal(cols: 80, rows: 24);
        addTearDown(other.dispose);
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final event = SelectionGestureEvent.press();
        addTearDown(event.dispose);
        event.setRef(GridRef.at(other, const Position(row: 0, col: 0)));

        expect(() => gesture.apply(event), throwsA(isA<ArgumentError>()));
      });

      test('clears a previously assigned grid reference', () {
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final event = SelectionGestureEvent.press();
        addTearDown(event.dispose);
        event.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));

        event.setRef(null);

        expect(
          () => gesture.apply(event),
          throwsA(isA<InvalidValueException>()),
        );
      });

      test('clears custom press behaviors to their defaults', () {
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final event = SelectionGestureEvent.press();
        addTearDown(event.dispose);
        event.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        event.setBehaviors(
          const SelectionGestureBehaviors(
            singleClick: .line,
            doubleClick: .line,
            tripleClick: .line,
          ),
        );

        event.setBehaviors(null);
        gesture.apply(event);

        expect(gesture.state.behavior, SelectionGestureBehavior.cell);
      });

      test('treats zero repeat-click metadata as explicit values', () {
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final event = SelectionGestureEvent.press();
        addTearDown(event.dispose);
        event.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        event.setPosition(0, 0);
        event.setRepeatDistance(0);
        event.setRepeatIntervalNs(0);
        event.setTimeNs(0);

        gesture.apply(event);
        gesture.apply(event);

        expect(gesture.state.clickCount, 2);
      });

      test('clears event time to disable repeat-click detection', () {
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final event = SelectionGestureEvent.press();
        addTearDown(event.dispose);
        event.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        event.setPosition(0, 0);
        event.setRepeatDistance(0);
        event.setRepeatIntervalNs(0);
        event.setTimeNs(0);
        event.setTimeNs(null);

        gesture.apply(event);
        gesture.apply(event);

        expect(gesture.state.clickCount, 1);
      });

      test('keeps an empty word-boundary list distinct from defaults', () {
        terminal.write(Uint8List.fromList('ABC DEF'.codeUnits));
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final event = SelectionGestureEvent.press();
        addTearDown(event.dispose);
        event.setRef(GridRef.at(terminal, const Position(row: 0, col: 1)));
        event.setBehaviors(
          const SelectionGestureBehaviors(
            singleClick: .word,
            doubleClick: .word,
            tripleClick: .word,
          ),
        );
        event.setWordBoundaryCodepoints(const []);

        final selection = gesture.apply(event);

        expect(terminal.formatSelection(selection: selection), 'ABC DEF');
      });

      test('clears word boundaries to restore Ghostty defaults', () {
        terminal.write(Uint8List.fromList('ABC DEF'.codeUnits));
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final event = SelectionGestureEvent.press();
        addTearDown(event.dispose);
        event.setRef(GridRef.at(terminal, const Position(row: 0, col: 1)));
        event.setBehaviors(
          const SelectionGestureBehaviors(
            singleClick: .word,
            doubleClick: .word,
            tripleClick: .word,
          ),
        );
        event.setWordBoundaryCodepoints(const []);
        event.setWordBoundaryCodepoints(null);

        final selection = gesture.apply(event);

        expect(terminal.formatSelection(selection: selection), 'ABC');
      });

      test('clears required drag geometry', () {
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final press = SelectionGestureEvent.press();
        addTearDown(press.dispose);
        final drag = SelectionGestureEvent.drag();
        addTearDown(drag.dispose);
        press.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        drag.setRef(GridRef.at(terminal, const Position(row: 0, col: 1)));
        drag.setGeometry(
          const SelectionGestureGeometry(
            columns: 80,
            cellWidth: 8,
            paddingLeft: 0,
            screenHeight: 24,
          ),
        );
        gesture.apply(press);

        drag.setGeometry(null);

        expect(
          () => gesture.apply(drag),
          throwsA(isA<InvalidValueException>()),
        );
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

      test('keeps false as an explicit rectangle value', () {
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final press = SelectionGestureEvent.press();
        addTearDown(press.dispose);
        final drag = SelectionGestureEvent.drag();
        addTearDown(drag.dispose);
        press.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        drag.setRef(GridRef.at(terminal, const Position(row: 1, col: 2)));
        drag.setRectangle(value: false);
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

        expect(selection?.rectangle, isFalse);
      });

      test('clears rectangle to restore its default', () {
        final gesture = SelectionGesture(terminal);
        addTearDown(gesture.dispose);
        final press = SelectionGestureEvent.press();
        addTearDown(press.dispose);
        final drag = SelectionGestureEvent.drag();
        addTearDown(drag.dispose);
        press.setRef(GridRef.at(terminal, const Position(row: 0, col: 0)));
        drag.setRef(GridRef.at(terminal, const Position(row: 1, col: 2)));
        drag.setRectangle(value: true);
        drag.setRectangle(value: null);
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

        expect(selection?.rectangle, isFalse);
      });
    });
  });
}
