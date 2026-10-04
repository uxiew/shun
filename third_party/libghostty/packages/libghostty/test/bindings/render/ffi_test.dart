@Tags(['ffi'])
library;

import 'package:libghostty/src/bindings/render/ffi.dart';
import 'package:libghostty/src/bindings/terminal/ffi.dart';
import 'package:libghostty/src/types/exceptions.dart';
import 'package:test/test.dart';

void main() {
  group('FfiRenderBindings', () {
    late FfiRenderBindings render;
    late FfiTerminalBindings terminalBindings;

    setUp(() {
      render = FfiRenderBindings();
      terminalBindings = FfiTerminalBindings();
    });

    group('renderStateGetSummary', () {
      test('returns the current dimensions through the direct adapter', () {
        final terminal = terminalBindings.terminalNew(8, 4);
        final state = render.renderStateNew();
        addTearDown(() {
          render.renderStateFree(state);
          terminalBindings.terminalFree(terminal);
        });

        render.renderStateUpdate(state, terminal);

        final summary = render.renderStateGetSummary(state);

        expect(summary.cols, 8);
        expect(summary.rows, 4);
      });

      test('maps an invalid render handle to the public exception type', () {
        expect(
          () => render.renderStateGetSummary(const .fromAddress(0)),
          throwsA(isA<LibGhosttyException>()),
        );
      });
    });
  });
}
