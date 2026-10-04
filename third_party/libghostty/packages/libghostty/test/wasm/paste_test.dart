@Tags(['wasm'])
library;

import 'dart:convert';

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

import 'helpers/setup.dart';

void main() {
  setUpAll(setUpWasm);

  group('pasteIsSafe', () {
    test('rejects unsafe content', () {
      expect(pasteIsSafe('rm -rf /\n'), isFalse);
      expect(pasteIsSafe('\x1b[201~injected'), isFalse);
    });

    test('accepts safe content', () {
      expect(pasteIsSafe(''), isTrue);
      expect(pasteIsSafe('a'), isTrue);
      expect(pasteIsSafe('hello world'), isTrue);
      expect(pasteIsSafe('hello world\ttab'), isTrue);
    });
  });

  group('pasteEncode', () {
    test('wraps with bracketed paste markers when bracketed', () {
      final result = pasteEncode('hello', bracketed: true);
      final decoded = utf8.decode(result);
      expect(decoded, '\x1b[200~hello\x1b[201~');
    });

    test('omits bracketed paste markers when not bracketed', () {
      final result = pasteEncode('hello', bracketed: false);
      final decoded = utf8.decode(result);
      expect(decoded, 'hello');
    });

    test('replaces newlines with carriage returns when not bracketed', () {
      final result = pasteEncode('a\nb', bracketed: false);
      final decoded = utf8.decode(result);
      expect(decoded, 'a\rb');
    });
  });
}
