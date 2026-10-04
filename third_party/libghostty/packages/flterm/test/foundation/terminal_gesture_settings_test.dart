import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  group('TerminalGestureSettings', () {
    group('constructor', () {
      test('uses expected defaults', () {
        const settings = TerminalGestureSettings();
        expect(settings.dragSelection, isTrue);
        expect(settings.longPressSelection, isTrue);
        expect(settings.selectAllShortcut, isTrue);
        expect(settings.blockSelectionModifier, GestureModifier.alt);
        expect(settings.longPressSelectionShape, TerminalSelectionShape.normal);
        expect(settings.lineSelectMode, LineSelectMode.content);
        expect(settings.selectionBehaviors, SelectionGestureBehaviors.standard);
        expect(settings.wordBoundaries, isNull);
      });

      test('stores disabled affordances', () {
        const settings = TerminalGestureSettings(
          dragSelection: false,
          longPressSelection: false,
          selectAllShortcut: false,
          blockSelectionModifier: null,
        );

        expect(settings.dragSelection, isFalse);
        expect(settings.longPressSelection, isFalse);
        expect(settings.selectAllShortcut, isFalse);
        expect(settings.blockSelectionModifier, isNull);
      });

      test('stores word boundaries', () {
        const settings = TerminalGestureSettings(wordBoundaries: '/🙂');

        expect(settings.wordBoundaries, '/🙂');
      });
    });

    group('equality', () {
      test('compares all fields', () {
        const a = TerminalGestureSettings();
        const b = TerminalGestureSettings();
        const differentDrag = TerminalGestureSettings(dragSelection: false);
        const differentLongPressSelection = TerminalGestureSettings(
          longPressSelection: false,
        );
        const differentSelectAll = TerminalGestureSettings(
          selectAllShortcut: false,
        );
        const differentModifier = TerminalGestureSettings(
          blockSelectionModifier: GestureModifier.meta,
        );
        const differentLongPress = TerminalGestureSettings(
          longPressSelectionShape: TerminalSelectionShape.rectangle,
        );
        const differentLineSelect = TerminalGestureSettings(
          lineSelectMode: LineSelectMode.full,
        );
        const differentBehaviors = TerminalGestureSettings(
          selectionBehaviors: SelectionGestureBehaviors(
            singleClick: SelectionGestureBehavior.word,
            doubleClick: SelectionGestureBehavior.line,
            tripleClick: SelectionGestureBehavior.cell,
          ),
        );
        const differentWordBoundaries = TerminalGestureSettings(
          wordBoundaries: '_',
        );

        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
        expect(a, isNot(equals(differentDrag)));
        expect(a, isNot(equals(differentLongPressSelection)));
        expect(a, isNot(equals(differentSelectAll)));
        expect(a, isNot(equals(differentModifier)));
        expect(a, isNot(equals(differentLongPress)));
        expect(a, isNot(equals(differentLineSelect)));
        expect(a, isNot(equals(differentBehaviors)));
        expect(a, isNot(equals(differentWordBoundaries)));
      });
    });
  });
}
