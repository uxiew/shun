@Tags(['wasm'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

import '../../helpers/setup.dart';

void main() {
  setUp(() => testEnvironment);

  group('Terminal', () {
    late Terminal terminal;

    setUp(() => terminal = Terminal(cols: 80, rows: 24));
    tearDown(() => terminal.dispose());

    group('kittyTempFileDirectory', () {
      test('returns null when Kitty Graphics is unavailable', () {
        final result = terminal.kittyTempFileDirectory;

        expect(result, isNull);
      });

      test('ignores configuration when Kitty Graphics is unavailable', () {
        terminal.setKittyTempFileDirectory('/tmp/kitty');

        final result = terminal.kittyTempFileDirectory;

        expect(result, isNull);
      });
    });
  });
}
