@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/links/link_resolver.dart';
import 'package:flterm/src/links/link_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show Position, Terminal;

void main() {
  group('LinkResolver', () {
    late Terminal terminal;
    late LinkResolver resolver;

    setUp(() {
      terminal = Terminal(cols: 80, rows: 5);
      resolver = LinkResolver();
    });

    tearDown(() => terminal.dispose());

    void write(String text) {
      terminal.write(Uint8List.fromList(utf8.encode(text)));
    }

    ActivatedLink? linkAt(int col, {LinkSettings? settings}) {
      return resolver.linkAt(
        terminal,
        Position(row: 0, col: col),
        settings ?? const LinkSettings(types: {LinkType.text}),
        rows: 5,
        cols: 80,
        cwd: '/workspace',
      );
    }

    group('linkAt', () {
      test('resolves OSC 8 hyperlinks from cell metadata', () {
        write('\x1b]8;;https://example.test\x07label\x1b]8;;\x07');

        final link = linkAt(1, settings: const LinkSettings())!;

        expect(link.type, LinkType.osc8);
        expect(link.id, isNull);
        expect(link.text, 'label');
        expect(link.uri, Uri.parse('https://example.test'));
        expect(link.range.start, const Position(row: 0, col: 0));
        expect(link.range.end, const Position(row: 0, col: 4));
      });

      test('resolves URLs with built-in text detection', () {
        write('open https://example.test/path.');

        final link = linkAt(7)!;

        expect(link.type, LinkType.text);
        expect(link.id, isNull);
        expect(link.text, 'https://example.test/path');
        expect(link.uri, Uri.parse('https://example.test/path'));
        expect(link.file, isNull);
      });

      test('resolves relative file paths with line and column suffixes', () {
        write('./lib/main.dart:12:4');

        final link = linkAt(2)!;

        expect(link.type, LinkType.text);
        expect(link.id, isNull);
        expect(link.text, './lib/main.dart:12:4');
        expect(link.file, isNotNull);
        expect(link.file!.path, './lib/main.dart');
        expect(link.file!.line, 12);
        expect(link.file!.column, 4);
        expect(link.file!.cwd, '/workspace');
        expect(link.file!.resolvedPath, '/workspace/lib/main.dart');
      });

      test('resolves current directory path from file URI cwd', () {
        write('du -h .');

        final link = resolver.linkAt(
          terminal,
          const Position(row: 0, col: 6),
          const LinkSettings(types: {LinkType.text}),
          rows: 5,
          cols: 80,
          cwd: 'file:///workspace/project',
        )!;

        expect(link.text, '.');
        expect(link.file!.path, '.');
        expect(link.file!.resolvedPath, '/workspace/project');
      });

      test('resolves relative file paths from hostname file URI cwd', () {
        write('./.git/logs/refs/heads/backup');

        final link = resolver.linkAt(
          terminal,
          const Position(row: 0, col: 4),
          const LinkSettings(types: {LinkType.text}),
          rows: 5,
          cols: 80,
          cwd: 'file:///opt/workspace/app',
        )!;

        expect(link.file!.path, './.git/logs/refs/heads/backup');
        expect(
          link.file!.resolvedPath,
          '/opt/workspace/app/.git/logs/refs/heads/backup',
        );
      });

      test('resolves Windows relative file paths from file URI cwd', () {
        write(r'.\.git\logs\refs\heads\backup');

        final link = resolver.linkAt(
          terminal,
          const Position(row: 0, col: 4),
          const LinkSettings(types: {LinkType.text}),
          rows: 5,
          cols: 80,
          cwd: 'file:///C:/Project/app',
        )!;

        expect(link.file!.path, r'.\.git\logs\refs\heads\backup');
        expect(
          link.file!.resolvedPath,
          r'C:\Project\app\.git\logs\refs\heads\backup',
        );
      });

      test('resolves Windows absolute file paths without cwd', () {
        write(r'C:\Project\app\main.dart:12:4');

        final link = resolver.linkAt(
          terminal,
          const Position(row: 0, col: 3),
          const LinkSettings(types: {LinkType.text}),
          rows: 5,
          cols: 80,
          cwd: null,
        )!;

        expect(link.file!.path, r'C:\Project\app\main.dart');
        expect(link.file!.line, 12);
        expect(link.file!.column, 4);
        expect(link.file!.resolvedPath, r'C:\Project\app\main.dart');
      });

      test('resolves relative file paths before following prose', () {
        write('./lib/main.dart is mentioned');

        final link = linkAt(2)!;

        expect(link.text, './lib/main.dart');
        expect(link.range.end, const Position(row: 0, col: 14));
        expect(linkAt(16), isNull);
      });

      test('resolves spaced relative file path segments', () {
        write('../test folder/file.txt next');

        final link = linkAt(3)!;

        expect(link.text, '../test folder/file.txt');
      });

      test('reports capture groups for custom regex rules', () {
        write('failed ISSUE-123');

        final link = linkAt(
          10,
          settings: LinkSettings(
            types: const {LinkType.text, LinkType.custom},
            rules: [
              LinkRule.regex(id: 'issue', pattern: RegExp(r'ISSUE-(\d+)')),
            ],
          ),
        )!;

        expect(link.type, LinkType.custom);
        expect(link.id, 'issue');
        expect(link.text, 'ISSUE-123');
        expect(link.captureGroups, ['123']);
      });

      test(
        'prefers higher-priority custom matches over built-in text links',
        () {
          write('https://example.test/issue/123');

          final link = linkAt(
            10,
            settings: LinkSettings(
              rules: [
                LinkRule.regex(
                  id: 'issue-url',
                  pattern: RegExp(r'https://example\.test/issue/(\d+)'),
                  priority: 10,
                ),
              ],
            ),
          )!;

          expect(link.type, LinkType.custom);
          expect(link.id, 'issue-url');
          expect(link.captureGroups, ['123']);
        },
      );

      test('does not scan beyond the visible grid dimensions', () {
        write('https://example.test');

        final link = resolver.linkAt(
          terminal,
          const Position(row: 0, col: 1),
          const LinkSettings(types: {LinkType.text}),
          rows: 0,
          cols: 80,
          cwd: null,
        );

        expect(link, isNull);
      });
    });

    group('buildSnapshot', () {
      test('highlights only cells inside the resolved text link', () {
        write('https://a.test tail');

        final snapshot = resolver.buildSnapshot(
          terminal,
          const LinkSettings(types: {LinkType.text}),
          rows: 5,
          cols: 80,
          highlighted: const CellRange(
            start: Position(row: 0, col: 0),
            end: Position(row: 0, col: 79),
          ),
        );

        expect(snapshot.isHighlighted(const Position(row: 0, col: 13)), isTrue);
        expect(
          snapshot.isHighlighted(const Position(row: 0, col: 14)),
          isFalse,
        );
      });

      test('highlights hover-only custom matches', () {
        write('see ISSUE-123 tail');

        final snapshot = resolver.buildSnapshot(
          terminal,
          LinkSettings(
            rules: [LinkRule.regex(id: 'issue', pattern: RegExp(r'ISSUE-\d+'))],
          ),
          rows: 5,
          cols: 80,
          highlighted: const CellRange(
            start: Position(row: 0, col: 4),
            end: Position(row: 0, col: 12),
          ),
        );

        expect(snapshot.isHighlighted(const Position(row: 0, col: 8)), isTrue);
      });

      test('does not highlight outside hover-only custom matches', () {
        write('see ISSUE-123 tail');

        final snapshot = resolver.buildSnapshot(
          terminal,
          LinkSettings(
            rules: [LinkRule.regex(id: 'issue', pattern: RegExp(r'ISSUE-\d+'))],
          ),
          rows: 5,
          cols: 80,
          highlighted: const CellRange(
            start: Position(row: 0, col: 4),
            end: Position(row: 0, col: 79),
          ),
        );

        expect(
          snapshot.isHighlighted(const Position(row: 0, col: 13)),
          isFalse,
        );
      });
    });
  });
}
