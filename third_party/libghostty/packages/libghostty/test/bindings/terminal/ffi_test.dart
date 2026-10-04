@Tags(['ffi'])
library;

import 'dart:typed_data';

import 'package:libghostty/src/bindings/terminal/ffi.dart';
import 'package:libghostty/src/bindings/types.dart';
import 'package:libghostty/src/generated/libghostty_enums.g.dart';
import 'package:libghostty/src/types/exceptions.dart';
import 'package:libghostty/src/types/geometry.dart';
import 'package:libghostty/src/types/terminal.dart';
import 'package:test/test.dart';

void main() {
  group('FfiTerminalBindings', () {
    late FfiTerminalBindings bindings;

    setUp(() {
      bindings = FfiTerminalBindings();
    });

    LibGhosttyHandle createTerminal() {
      final terminal = bindings.terminalNew(8, 4);
      addTearDown(() => bindings.terminalFree(terminal));
      return terminal;
    }

    test(
      'creates, queries, and resizes a terminal through the direct adapter',
      () {
        final terminal = createTerminal();

        expect(
          bindings.terminalGetGeometry(terminal),
          const TerminalGeometry(cols: 8, rows: 4, widthPx: 0, heightPx: 0),
        );

        bindings.terminalResize(terminal, 10, 6, 8, 16);
        expect(bindings.terminalGetCols(terminal), 10);
        expect(bindings.terminalGetRows(terminal), 6);
        expect(bindings.terminalGetWidthPx(terminal), 80);
        expect(bindings.terminalGetHeightPx(terminal), 96);
      },
    );

    test(
      'maps optional terminal configuration values to nullable Dart values',
      () {
        final terminal = createTerminal();

        expect(bindings.terminalGetScrollbackMaxBytes(terminal), isA<int>());
        expect(bindings.terminalGetScrollbackMaxLines(terminal), isNull);
        expect(
          bindings.terminalGetKittyImageStorageLimit(terminal),
          isA<int>(),
        );
        expect(bindings.terminalGetKittyImageMediumFile(terminal), isA<bool>());
        expect(
          bindings.terminalGetKittyImageMediumSharedMem(terminal),
          isA<bool>(),
        );
        expect(
          bindings.terminalGetKittyImageMediumTempFile(terminal),
          isA<String>(),
        );
      },
    );

    test('copies VT input and exposes updated selector state', () {
      final terminal = createTerminal();

      bindings.terminalVtWrite(terminal, Uint8List.fromList('abc'.codeUnits));

      expect(bindings.terminalGetCursorX(terminal), 3);
      expect(bindings.terminalGetCursorY(terminal), 0);
      expect(
        bindings.terminalGetActiveScreen(terminal),
        TerminalScreen.primary,
      );
    });

    test('writes through ground and reports partial consumption', () {
      final terminal = createTerminal();

      bindings.terminalVtWrite(terminal, Uint8List.fromList([0x1b, 0x5b]));

      expect(
        bindings.terminalWriteUntilGround(
          terminal,
          Uint8List.fromList('31mA'.codeUnits),
        ),
        3,
      );
      bindings.terminalVtWrite(terminal, Uint8List.fromList([0x1b, 0x5b]));
      expect(
        bindings.terminalWriteUntilGround(
          terminal,
          Uint8List.fromList('31'.codeUnits),
        ),
        isNull,
      );
    });

    test('copies binary unknown sequence callback data', () {
      final terminal = createTerminal();
      TerminalUnknownSequence? sequence;
      bindings.terminalSetUnknownSequenceMaxBytes(terminal, 2);
      bindings.terminalSetOnUnknownSequence(
        terminal,
        (value) => sequence = value,
      );

      bindings.terminalVtWrite(
        terminal,
        Uint8List.fromList([0x1b, 0x5f, 0x00, 0x01, 0x02, 0x1b, 0x5c]),
      );

      expect(sequence?.tag, TerminalUnknownSequenceTag.apc);
      expect(sequence?.content, Uint8List.fromList([0x00, 0x01]));
      expect(sequence?.truncated, isTrue);
    });

    test('maps terminfo byte-limit failures', () {
      final terminal = createTerminal();

      expect(
        () => bindings.terminalSetTerminfoName(terminal, 'a' * 129),
        throwsA(isA<InvalidValueException>()),
      );
    });

    test('rethrows callback failures after the native operation completes', () {
      final terminal = createTerminal();
      final failure = StateError('callback failure');
      bindings.terminalSetOnBell(terminal, () => throw failure);

      expect(
        () => bindings.terminalVtWrite(terminal, Uint8List.fromList([7])),
        throwsA(same(failure)),
      );
      expect(bindings.terminalGetVtProcessingError(terminal), isFalse);
    });

    test('rejects output queries for an invalid terminal handle', () {
      expect(
        () => bindings.terminalGetGeometry(const .fromAddress(0)),
        throwsA(isA<LibGhosttyException>()),
      );
    });
  });
}
