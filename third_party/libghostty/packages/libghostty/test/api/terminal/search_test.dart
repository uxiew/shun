import 'dart:typed_data';

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

import '../../helpers/setup.dart';

void main() {
  setUp(() => testEnvironment);

  group('Search', () {
    late Terminal terminal;
    late Search search;

    setUp(() {
      terminal = Terminal(cols: 80, rows: 24);
      search = Search(terminal);
    });

    tearDown(() {
      search.dispose();
      terminal.dispose();
    });

    test('finds matches after running the search', () {
      terminal.write(Uint8List.fromList('hello world hello'.codeUnits));

      search.setNeedle('hello');
      search.run();

      expect(search.status, SearchStatus.complete);
      expect(search.totalMatches, 2);
      expect(search.matches, hasLength(2));
      expect(search.viewportMatches, hasLength(2));
    });

    test('selects matches and exposes the selected range', () {
      terminal.write(Uint8List.fromList('hello world hello'.codeUnits));

      search.setNeedle('hello');
      search.run();
      search.selectNext();

      expect(search.selectedIndex, 0);
      expect(search.selectedMatch, isNotNull);
      expect(
        search.selectedMatch!.end.positionIn(PointTag.active)!.col,
        greaterThan(0),
      );
    });
  });
}
