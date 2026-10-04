import 'package:meta/meta.dart';

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

  /// Returns a copy with the given fields replaced.
  Position copyWith({int? row, int? col}) {
    return Position(row: row ?? this.row, col: col ?? this.col);
  }

  @override
  int get hashCode => Object.hash(row, col);

  @override
  bool operator ==(Object other) =>
      other is Position && other.row == row && other.col == col;

  @override
  String toString() => 'Position(row: $row, col: $col)';
}
