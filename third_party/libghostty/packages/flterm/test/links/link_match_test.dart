import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/links/link_match.dart';
import 'package:flterm/src/links/link_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show Position;

void main() {
  group('LinkMatch', () {
    LinkMatch match({
      required Position start,
      required Position end,
      int priority = 0,
      int sourceOrder = 0,
    }) {
      return LinkMatch(
        priority: priority,
        sourceOrder: sourceOrder,
        hoverOnly: false,
        link: ActivatedLink(
          type: LinkType.custom,
          text: 'text',
          range: CellRange(start: start, end: end),
        ),
      );
    }

    group('resolveOverlaps', () {
      test('keeps the highest-priority overlapping match', () {
        final low = match(
          start: const Position(row: 0, col: 0),
          end: const Position(row: 0, col: 8),
        );
        final high = match(
          start: const Position(row: 0, col: 4),
          end: const Position(row: 0, col: 6),
          priority: 1,
        );

        final result = LinkMatch.resolveOverlaps([low, high]);

        expect(result, [high]);
      });

      test('keeps non-overlapping matches', () {
        final first = match(
          start: const Position(row: 0, col: 0),
          end: const Position(row: 0, col: 3),
        );
        final second = match(
          start: const Position(row: 0, col: 5),
          end: const Position(row: 0, col: 8),
        );

        final result = LinkMatch.resolveOverlaps([first, second]);

        expect(result, [first, second]);
      });

      test('keeps earlier source order for otherwise equal matches', () {
        final later = match(
          start: const Position(row: 0, col: 0),
          end: const Position(row: 0, col: 8),
          sourceOrder: 1,
        );
        final earlier = match(
          start: const Position(row: 0, col: 0),
          end: const Position(row: 0, col: 8),
        );

        final result = LinkMatch.resolveOverlaps([later, earlier]);

        expect(result, [earlier]);
      });
    });
  });
}
