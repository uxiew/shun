@Tags(['ffi'])
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
      test('returns the configured directory', () {
        terminal.setKittyTempFileDirectory('/tmp/kitty');

        final result = terminal.kittyTempFileDirectory;

        expect(result, '/tmp/kitty');
      });

      test('returns an empty directory after disabling', () {
        terminal.setKittyTempFileDirectory('/tmp/kitty');
        terminal.setKittyTempFileDirectory(null);

        final result = terminal.kittyTempFileDirectory;

        expect(result, isEmpty);
      });

      test('throws for a directory above the native capacity', () {
        final directory = List.filled(128 * 1024, 'a').join();

        expect(
          () => terminal.setKittyTempFileDirectory(directory),
          throwsA(isA<OutOfMemoryException>()),
        );
      });

      test('accepts an empty directory', () {
        terminal.setKittyTempFileDirectory('');

        final result = terminal.kittyTempFileDirectory;

        expect(result, isEmpty);
      });
    });
  });
}
