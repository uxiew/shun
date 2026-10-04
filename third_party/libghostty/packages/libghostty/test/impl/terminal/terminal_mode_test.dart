@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('TerminalMode', () {
    group('modeValue', () {
      test('returns DEC private mode numbers', () {
        expect(const TerminalMode.bracketedPaste().modeValue, 2004);
        expect(const TerminalMode.cursorKeys().modeValue, 1);
        expect(const TerminalMode.backArrowKeyMode().modeValue, 67);
      });

      test('returns ANSI mode numbers', () {
        expect(const TerminalMode.insert().modeValue, 4);
        expect(const TerminalMode.kam().modeValue, 2);
      });
    });

    group('isAnsi', () {
      test('returns false for DEC private modes', () {
        expect(const TerminalMode.bracketedPaste().isAnsi, isFalse);
        expect(const TerminalMode.cursorKeys().isAnsi, isFalse);
      });

      test('returns true for ANSI modes', () {
        expect(const TerminalMode.insert().isAnsi, isTrue);
        expect(const TerminalMode.kam().isAnsi, isTrue);
        expect(const TerminalMode.srm().isAnsi, isTrue);
        expect(const TerminalMode.linefeed().isAnsi, isTrue);
      });
    });

    group('encodeReport', () {
      test('returns sequences for DEC private and ANSI modes', () {
        expect(
          const TerminalMode.bracketedPaste().encodeReport(.set),
          isNotEmpty,
        );
        expect(const TerminalMode.insert().encodeReport(.reset), isNotEmpty);
      });
    });
  });
}
