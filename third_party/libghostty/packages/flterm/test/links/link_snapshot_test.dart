import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/links/link_match.dart';
import 'package:flterm/src/links/link_settings.dart';
import 'package:flterm/src/links/link_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show Position;

void main() {
  group('LinkSnapshot', () {
    LinkMatch match({
      required Position start,
      required Position end,
      bool hoverOnly = false,
    }) {
      final range = CellRange(start: start, end: end);
      return LinkMatch(
        priority: 0,
        sourceOrder: 0,
        hoverOnly: hoverOnly,
        link: ActivatedLink(
          type: LinkType.custom,
          id: 'test',
          text: 'label',
          range: range,
        ),
      );
    }

    group('contains', () {
      test('returns true for visible link cells', () {
        final snapshot = LinkSnapshot([
          match(
            start: const Position(row: 0, col: 0),
            end: const Position(row: 0, col: 4),
          ),
        ]);

        final result = snapshot.contains(const Position(row: 0, col: 2));

        expect(result, isTrue);
      });

      test('returns false outside visible link cells', () {
        final snapshot = LinkSnapshot([
          match(
            start: const Position(row: 0, col: 0),
            end: const Position(row: 0, col: 4),
          ),
        ]);

        final result = snapshot.contains(const Position(row: 0, col: 5));

        expect(result, isFalse);
      });

      test('returns false for hover-only links before highlight', () {
        final snapshot = LinkSnapshot([
          match(
            start: const Position(row: 0, col: 0),
            end: const Position(row: 0, col: 4),
            hoverOnly: true,
          ),
        ]);

        final result = snapshot.contains(const Position(row: 0, col: 2));

        expect(result, isFalse);
      });
    });

    group('isHighlighted', () {
      test('returns true inside matched highlighted links', () {
        final snapshot = LinkSnapshot(
          [
            match(
              start: const Position(row: 0, col: 0),
              end: const Position(row: 0, col: 4),
            ),
          ],
          highlighted: const CellRange(
            start: Position(row: 0, col: 0),
            end: Position(row: 0, col: 79),
          ),
        );

        final result = snapshot.isHighlighted(const Position(row: 0, col: 2));

        expect(result, isTrue);
      });

      test('returns false outside matched highlighted links', () {
        final snapshot = LinkSnapshot(
          [
            match(
              start: const Position(row: 0, col: 0),
              end: const Position(row: 0, col: 4),
            ),
          ],
          highlighted: const CellRange(
            start: Position(row: 0, col: 0),
            end: Position(row: 0, col: 79),
          ),
        );

        final result = snapshot.isHighlighted(const Position(row: 0, col: 5));

        expect(result, isFalse);
      });
    });
  });
}
