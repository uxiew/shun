import 'package:flterm/src/links/link_settings.dart' show LinkRule, LinkType;
import 'package:flterm/src/links/terminal_logical_line.dart'
    show TerminalLogicalLine;
import 'package:flterm/src/links/text_link_detector.dart' show TextLinkDetector;
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show Position;

void main() {
  group('TextLinkDetector', () {
    late TextLinkDetector detector;

    setUp(() {
      detector = TextLinkDetector();
    });

    TerminalLogicalLine line(String text) {
      final cells = [
        for (var i = 0; i < text.length; i++) Position(row: 0, col: i),
      ];
      return TerminalLogicalLine(
        text,
        cells,
        cells,
        List<String?>.filled(text.length, null),
      );
    }

    group('builtInMatches', () {
      test('reports text links as built-in text links', () {
        final matches = detector.builtInMatches([
          line('open https://example.test/path.'),
        ], cwd: null).toList();

        final link = matches.single.link;

        expect(link.type, LinkType.text);
        expect(link.text, 'https://example.test/path');
        expect(link.uri, Uri.parse('https://example.test/path'));
      });

      test('reports file metadata for path links', () {
        final matches = detector.builtInMatches([
          line(r'.\.git\logs\refs\heads\backup'),
        ], cwd: null).toList();

        final link = matches.single.link;

        expect(link.file!.path, r'.\.git\logs\refs\heads\backup');
      });
    });

    group('customMatches', () {
      test('reports capture groups for regex rules', () {
        final matches = detector
            .customMatches(
              [line('failed ISSUE-123')],
              LinkRule.regex(id: 'issue', pattern: RegExp(r'ISSUE-(\d+)')),
              0,
            )
            .toList();

        final link = matches.single.link;

        expect(link.type, LinkType.custom);
        expect(link.id, 'issue');
        expect(link.captureGroups, ['123']);
      });

      test('reports null for unmatched optional capture groups', () {
        final matches = detector
            .customMatches(
              [line('failed ISSUE-123')],
              LinkRule.regex(
                id: 'issue',
                pattern: RegExp(r'ISSUE-(\d+)(?:-(\w+))?'),
              ),
              0,
            )
            .toList();

        final link = matches.single.link;

        expect(link.captureGroups, ['123', null]);
      });
    });
  });
}
