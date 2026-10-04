@Tags(['ffi'])
library;

import 'dart:typed_data';

import 'package:libghostty/src/bindings/selection/ffi.dart';
import 'package:libghostty/src/bindings/terminal/ffi.dart';
import 'package:test/test.dart';

void main() {
  group('FfiSelectionBindings', () {
    late FfiSelectionBindings selection;
    late FfiTerminalBindings terminalBindings;

    setUp(() {
      selection = FfiSelectionBindings();
      terminalBindings = FfiTerminalBindings();
    });

    test('creates and clears a selection gesture event', () {
      final event = selection.selectionGestureEventNew(.press);
      addTearDown(() => selection.selectionGestureEventFree(event));

      selection.selectionGestureEventClear(event, .position);

      expect(event.value, isNonZero);
    });

    test('formats a selected terminal range through the direct adapter', () {
      final terminal = terminalBindings.terminalNew(8, 2);
      addTearDown(() => terminalBindings.terminalFree(terminal));
      terminalBindings.terminalVtWrite(
        terminal,
        Uint8List.fromList([65, 66, 67]),
      );

      final selected = selection.terminalSelectAll(terminal);
      final formatted = selection.terminalSelectionFormat(
        terminal,
        .plain,
        selection: selected,
      );

      expect(selected, isNotNull);
      expect(formatted, contains('ABC'));
    });
  });
}
