@Tags(['wasm'])
library;

import 'dart:convert';

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

import '../helpers/setup.dart';

void main() {
  setUpAll(setUpWasm);

  group('OscParser', () {
    late OscParser parser;

    setUp(() {
      parser = OscParser();
    });

    tearDown(() {
      parser.dispose();
    });

    group('end', () {
      test('returns window commands', () {
        parser.feedBytes(utf8.encode('0;My Terminal Title'));

        final title = parser.end(0x07);
        expect(title.type, OscCommandType.changeWindowTitle);
        expect(title.windowTitle, 'My Terminal Title');

        parser.reset();
        parser.feedBytes(utf8.encode('1;icon-name'));

        final icon = parser.end(0x07);
        expect(icon.type, OscCommandType.changeWindowIcon);
      });

      test('returns invalid command for invalid sequence', () {
        parser.feedByte(0xFF);
        final command = parser.end(0x07);
        expect(command.type, OscCommandType.invalid);
      });
    });

    group('reset', () {
      test('clears previous command state', () {
        parser.feedBytes(utf8.encode('0;First'));
        parser.end(0x07);

        parser.reset();
        parser.feedBytes(utf8.encode('0;Second'));

        final second = parser.end(0x07);
        expect(second.windowTitle, 'Second');
      });
    });

    group('windowTitle', () {
      test('returns null for non-title commands', () {
        parser.feedBytes(utf8.encode('7;file:///home'));
        final command = parser.end(0x07);
        expect(command.type, OscCommandType.reportPwd);
        expect(command.windowTitle, isNull);
      });
    });
  });
}
