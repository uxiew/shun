@Tags(['ffi'])
library;

import 'package:libghostty/src/bindings/formatter/ffi.dart';
import 'package:libghostty/src/bindings/terminal/ffi.dart';
import 'package:test/test.dart';

void main() {
  group('FfiFormatterBindings', () {
    test(
      'creates and formats a terminal through direct formatter bindings',
      () {
        final terminalBindings = FfiTerminalBindings();
        final formatterBindings = FfiFormatterBindings();
        final terminal = terminalBindings.terminalNew(8, 2);
        addTearDown(() => terminalBindings.terminalFree(terminal));

        final formatter = formatterBindings.formatterTerminalNew(
          terminal,
          .plain,
        );
        addTearDown(() => formatterBindings.formatterFree(formatter));

        expect(formatterBindings.formatterFormat(formatter), isA<String>());
      },
    );
  });
}
