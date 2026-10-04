import 'package:meta/meta.dart';

/// Renderer size context for mouse encoder pixel-to-cell coordinate conversion.
///
/// Describes the rendered terminal geometry used to convert surface-space
/// pixel positions into encoded cell coordinates. Supply a new value whenever
/// the terminal grid dimensions or cell size change.
///
/// [cellWidth] and [cellHeight] must be non-zero.
@immutable
final class MouseEncoderSize {
  /// Full screen width in pixels.
  final int screenWidth;

  /// Full screen height in pixels.
  final int screenHeight;

  /// Cell width in pixels. Must be non-zero.
  final int cellWidth;

  /// Cell height in pixels. Must be non-zero.
  final int cellHeight;

  /// Top padding in pixels.
  final int paddingTop;

  /// Bottom padding in pixels.
  final int paddingBottom;

  /// Left padding in pixels.
  final int paddingLeft;

  /// Right padding in pixels.
  final int paddingRight;

  const MouseEncoderSize({
    required this.screenWidth,
    required this.screenHeight,
    required this.cellWidth,
    required this.cellHeight,
    this.paddingTop = 0,
    this.paddingBottom = 0,
    this.paddingLeft = 0,
    this.paddingRight = 0,
  });

  @override
  int get hashCode => Object.hash(
    screenWidth,
    screenHeight,
    cellWidth,
    cellHeight,
    paddingTop,
    paddingBottom,
    paddingLeft,
    paddingRight,
  );

  @override
  bool operator ==(Object other) =>
      other is MouseEncoderSize &&
      other.screenWidth == screenWidth &&
      other.screenHeight == screenHeight &&
      other.cellWidth == cellWidth &&
      other.cellHeight == cellHeight &&
      other.paddingTop == paddingTop &&
      other.paddingBottom == paddingBottom &&
      other.paddingLeft == paddingLeft &&
      other.paddingRight == paddingRight;
}

/// Coordinates of a terminal cell.
///
/// [row] and [col] are interpreted in the coordinate space supplied by the
/// API that accepts the position.
///
/// ```dart
/// const position = Position(row: 0, col: 0);
/// ```
@immutable
final class Position {
  /// Row index in the selected coordinate space.
  final int row;

  /// Column index in the selected coordinate space.
  final int col;

  const Position({required this.row, required this.col});

  @override
  int get hashCode => Object.hash(row, col);

  @override
  bool operator ==(Object other) =>
      other is Position && other.row == row && other.col == col;

  /// Returns a copy with the given fields replaced.
  Position copyWith({int? row, int? col}) {
    return Position(row: row ?? this.row, col: col ?? this.col);
  }

  @override
  String toString() => 'Position(row: $row, col: $col)';
}

/// Scrollbar position and dimensions for the terminal viewport.
///
/// Provides the information needed to render a scrollbar widget.
@immutable
final class Scrollbar {
  /// Total scrollable area in rows (active grid + scrollback).
  final int total;

  /// Current viewport offset from the top in rows.
  final int offset;

  /// Number of visible rows in the viewport.
  final int visible;

  const Scrollbar({
    required this.total,
    required this.offset,
    required this.visible,
  });

  @override
  int get hashCode => Object.hash(total, offset, visible);

  @override
  bool operator ==(Object other) =>
      other is Scrollbar &&
      other.total == total &&
      other.offset == offset &&
      other.visible == visible;
}

/// Terminal dimensions in cells and pixels.
///
/// Pixel dimensions are zero when no cell pixel size has been configured.
@immutable
final class TerminalGeometry {
  /// Number of columns in the active grid.
  final int cols;

  /// Number of rows in the active grid.
  final int rows;

  /// Total terminal width in pixels.
  final int widthPx;

  /// Total terminal height in pixels.
  final int heightPx;

  const TerminalGeometry({
    required this.cols,
    required this.rows,
    required this.widthPx,
    required this.heightPx,
  });

  @override
  int get hashCode => Object.hash(cols, rows, widthPx, heightPx);

  @override
  bool operator ==(Object other) =>
      other is TerminalGeometry &&
      other.cols == cols &&
      other.rows == rows &&
      other.widthPx == widthPx &&
      other.heightPx == heightPx;
}

/// Terminal size in cells and pixels for XTWINOPS size query responses.
///
/// Return this from a terminal size callback to respond to CSI 14/16/18 t
/// queries.
@immutable
final class TerminalSizeInfo {
  /// Terminal height in cells.
  final int rows;

  /// Terminal width in cells.
  final int columns;

  /// Width of a single cell in pixels.
  final int cellWidth;

  /// Height of a single cell in pixels.
  final int cellHeight;

  const TerminalSizeInfo({
    required this.rows,
    required this.columns,
    required this.cellWidth,
    required this.cellHeight,
  });

  @override
  int get hashCode => Object.hash(rows, columns, cellWidth, cellHeight);

  @override
  bool operator ==(Object other) =>
      other is TerminalSizeInfo &&
      other.rows == rows &&
      other.columns == columns &&
      other.cellWidth == cellWidth &&
      other.cellHeight == cellHeight;
}
