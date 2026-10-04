import 'package:flterm/src/links/link_path_resolver.dart' show LinkPathResolver;
import 'package:flterm/src/links/text_link_patterns.dart' show TextLinkPatterns;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TextLinkPatterns', () {
    group('link', () {
      String? firstDetectedText(String input) {
        for (final match in TextLinkPatterns.link.allMatches(input)) {
          final text = LinkPathResolver.trimTextLink(match.group(0)!);
          if (text.isNotEmpty) return text;
        }
        return null;
      }

      void expectDetected(Iterable<({String input, String expected})> cases) {
        for (final case_ in cases) {
          expect(firstDetectedText(case_.input), case_.expected);
        }
      }

      void expectNotDetected(Iterable<String> cases) {
        for (final input in cases) {
          expect(firstDetectedText(input), isNull);
        }
      }

      test('matches supported URL and URI schemes', () {
        expectDetected([
          (input: 'match https://example.com', expected: 'https://example.com'),
          (input: 'match http://example.com', expected: 'http://example.com'),
          (
            input: 'send mailto:test@example.com',
            expected: 'mailto:test@example.com',
          ),
          (input: 'match ftp://example.com', expected: 'ftp://example.com'),
          (input: 'match file://example.com', expected: 'file://example.com'),
          (input: 'match ssh://example.com', expected: 'ssh://example.com'),
          (input: 'match git://example.com', expected: 'git://example.com'),
          (input: 'match tel:+18005551234', expected: 'tel:+18005551234'),
          (
            input: 'match magnet:?xt=urn:btih:1234567890',
            expected: 'magnet:?xt=urn:btih:1234567890',
          ),
          (
            input: 'match ipfs://QmSomeHashValue',
            expected: 'ipfs://QmSomeHashValue',
          ),
          (
            input: 'match ipns://QmSomeHashValue',
            expected: 'ipns://QmSomeHashValue',
          ),
          (
            input: 'match gemini://example.com',
            expected: 'gemini://example.com',
          ),
          (
            input: 'match gopher://example.com',
            expected: 'gopher://example.com',
          ),
          (
            input: 'match news:comp.infosystems.www.servers.unix',
            expected: 'news:comp.infosystems.www.servers.unix',
          ),
        ]);
      });

      test('keeps balanced URL punctuation', () {
        expectDetected([
          (
            input: 'https://example.com/foo(bar) more',
            expected: 'https://example.com/foo(bar)',
          ),
          (
            input: 'https://example.com/foo(bar)baz more',
            expected: 'https://example.com/foo(bar)baz',
          ),
          (
            input: 'square brackets https://example.com/[foo] and more',
            expected: 'https://example.com/[foo]',
          ),
        ]);
      });

      test('trims surrounding URL punctuation', () {
        expectDetected([
          (
            input: 'Link inside (https://example.com) parens',
            expected: 'https://example.com',
          ),
          (
            input: 'Link period https://example.com. More text.',
            expected: 'https://example.com',
          ),
          (
            input: 'Link trailing comma https://example.com, more text.',
            expected: 'https://example.com',
          ),
          (
            input: 'Link in double quotes "https://example.com" and more',
            expected: 'https://example.com',
          ),
          (
            input: "Link in single quotes 'https://example.com' and more",
            expected: 'https://example.com',
          ),
        ]);
      });

      test('matches URL query strings', () {
        expectDetected([
          (
            input:
                'match with query url https://example.com?query=1&other=2 and more',
            expected: 'https://example.com?query=1&other=2',
          ),
        ]);
      });

      test('matches IPv6 URLs', () {
        expectDetected([
          (
            input: 'IPv6 address https://[2001:db8::1]:8080/path',
            expected: 'https://[2001:db8::1]:8080/path',
          ),
          (
            input: 'IPv6 localhost http://[::1]:3000',
            expected: 'http://[::1]:3000',
          ),
          (
            input: 'IPv6 in markdown [link](http://[2001:db8::1]/docs)',
            expected: 'http://[2001:db8::1]/docs',
          ),
        ]);
      });

      test('returns the first URL in a line', () {
        final result = firstDetectedText(
          'some file with https://google.com https://duckduckgo.com links.',
        );

        expect(result, 'https://google.com');
      });

      test('matches absolute POSIX paths', () {
        expectDetected([
          (
            input: '/opt/workspace/code/example.py',
            expected: '/opt/workspace/code/example.py',
          ),
          (
            input: '/opt/workspace/code/../example.py hello world',
            expected: '/opt/workspace/code/../example.py',
          ),
          (
            input: '[link](/srv/project/example)',
            expected: '/srv/project/example',
          ),
        ]);
      });

      test('matches dot-relative paths', () {
        expectDetected([
          (input: '../example.py', expected: '../example.py'),
          (
            input: 'first time ../example.py contributor',
            expected: '../example.py',
          ),
          (input: 'du -h .', expected: '.'),
          (input: 'du -h ..', expected: '..'),
        ]);
      });

      test('matches bare relative paths', () {
        expectDetected([
          (input: 'src/config/url.zig', expected: 'src/config/url.zig'),
          (input: 'app/folder/file.rb:1', expected: 'app/folder/file.rb:1'),
          (
            input: 'lib/terminal/core.zig:42:10',
            expected: 'lib/terminal/core.zig:42:10',
          ),
          (
            input: 'some-pkg/src/file.txt more text',
            expected: 'some-pkg/src/file.txt',
          ),
          (input: '2024/report.txt', expected: '2024/report.txt'),
        ]);
      });

      test('matches home and environment paths', () {
        expectDetected([
          (input: '~/foo/bar.txt', expected: '~/foo/bar.txt'),
          (
            input: '~/.config/editor/config',
            expected: '~/.config/editor/config',
          ),
          (
            input: r'$HOME/src/config/url.zig',
            expected: r'$HOME/src/config/url.zig',
          ),
          (input: r'foo/$BAR/baz', expected: r'foo/$BAR/baz'),
        ]);
      });

      test('matches hidden relative paths', () {
        expectDetected([
          (input: '.config/editor/config', expected: '.config/editor/config'),
          (
            input: 'loaded from .local/share/editor/state.db now',
            expected: '.local/share/editor/state.db',
          ),
        ]);
      });

      test('trims path prose delimiters', () {
        expectDetected([
          (input: '/tmp/test  folder/file.txt', expected: '/tmp/test'),
          (input: '/tmp/foo.txt /tmp/bar.txt', expected: '/tmp/foo.txt'),
          (input: 'src/foo.c,baz.txt', expected: 'src/foo.c'),
          (input: './foo bar,baz', expected: './foo bar'),
          (
            input: './.config/editor: Needs upstream (main)',
            expected: './.config/editor',
          ),
        ]);
      });

      test('keeps single spaces inside paths', () {
        final result = firstDetectedText('../test folder/file.txt');

        expect(result, '../test folder/file.txt');
      });

      test('matches Windows paths', () {
        expectDetected([
          (
            input: r'C:\Project\app\main.dart:12:4',
            expected: r'C:\Project\app\main.dart:12:4',
          ),
          (
            input: r'.\.git\logs\refs\heads\backup',
            expected: r'.\.git\logs\refs\heads\backup',
          ),
        ]);
      });

      test('rejects ambiguous path-like text', () {
        expectNotDetected([
          'foo/bar',
          r'$10/bar.txt',
          r'foo$BAR/baz.txt',
          'foo~/bar.txt',
          '//foo',
        ]);
      });
    });
  });
}
