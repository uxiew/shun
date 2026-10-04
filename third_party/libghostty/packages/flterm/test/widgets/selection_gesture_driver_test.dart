@Tags(['ffi'])
library;

import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets/selection_gesture_driver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  group('SelectionGestureDriver', () {
    late Terminal terminal;
    late SelectionGestureDriver driver;

    setUp(() {
      terminal = Terminal(cols: 20, rows: 5);
      driver = SelectionGestureDriver(terminal);
    });

    tearDown(() {
      driver.dispose();
      terminal.dispose();
    });

    void writeUtf8(String text) {
      terminal.write(Uint8List.fromList(text.codeUnits));
    }

    GridRef refAt({required int col, required int row}) {
      return GridRef.at(terminal, Position(row: row, col: col));
    }

    group('drag', () {
      test('uses word boundaries from press', () {
        writeUtf8('alpha_beta gamma');
        driver.press(
          ref: refAt(col: 11, row: 0),
          localPosition: const Offset(88, 0),
          settings: const TerminalGestureSettings(
            selectionBehaviors: SelectionGestureBehaviors(
              singleClick: .word,
              doubleClick: .word,
              tripleClick: .line,
            ),
            wordBoundaries: '_',
          ),
        );

        final selection = driver.drag(
          ref: refAt(col: 6, row: 0),
          localPosition: const Offset(48, 0),
          rectangle: false,
          geometry: const SelectionGestureGeometry(
            columns: 20,
            cellWidth: 8,
            paddingLeft: 0,
            screenHeight: 80,
          ),
        );

        expect(terminal.formatSelection(selection: selection), 'beta gamma');
      });
    });
  });
}
