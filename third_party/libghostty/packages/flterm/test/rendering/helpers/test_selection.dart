import 'package:libghostty/libghostty.dart';

final class TestSelection {
  final Position start;
  final Position end;
  final bool rectangle;

  const TestSelection({
    required this.start,
    required this.end,
    this.rectangle = false,
  });

  void applyTo(Terminal terminal) {
    final state = RenderState()..update(terminal);
    try {
      final maxRow = state.rows - 1;
      final maxCol = state.cols - 1;
      if (maxRow < 0 || maxCol < 0) return;

      terminal.selection = Selection.fromRefs(
        start: GridRef.at(
          terminal,
          Position(
            row: _clamp(start.row, 0, maxRow),
            col: _clamp(start.col, 0, maxCol),
          ),
        ),
        end: GridRef.at(
          terminal,
          Position(
            row: _clamp(end.row, 0, maxRow),
            col: _clamp(end.col, 0, maxCol),
          ),
        ),
        rectangle: rectangle,
      );
    } finally {
      state.dispose();
    }
  }

  int _clamp(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}
