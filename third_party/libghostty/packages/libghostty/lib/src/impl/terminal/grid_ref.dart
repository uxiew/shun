part of 'terminal.dart';

/// A resolved reference to a specific cell position in the terminal grid.
///
/// Created via [GridRef.at]. A grid reference is only valid until the next
/// operation on the terminal instance, including seemingly unrelated
/// operations, so cache any needed information right after creation.
///
/// Not intended for render loops. Use [RenderState] with [RowIterator] and
/// [CellIterator] for performance-critical rendering.
///
/// ```dart
/// final ref = GridRef.at(terminal, const Position(row: 0, col: 0));
/// print(ref.content);
/// print(ref.style);
/// ```
@immutable
final class GridRef {
  final RawGridRef _value;
  final Terminal _terminal;

  /// Resolves the grid cell at [position] in the coordinate space
  /// identified by [pointTag].
  ///
  /// [PointTag.active] and [PointTag.viewport] are fast lookups;
  /// [PointTag.screen] and [PointTag.history] may be expensive for large
  /// scrollback buffers because they traverse the full scrollback page
  /// list.
  ///
  /// Throws [InvalidValueException] if the coordinates are out of range.
  factory GridRef.at(
    Terminal terminal,
    Position position, {
    PointTag pointTag = .active,
  }) => GridRef._(terminal, position, pointTag: pointTag);

  GridRef._(Terminal terminal, Position position, {PointTag pointTag = .active})
    : this._fromValue(
        terminal,
        check(bindings.terminalGridRef(terminal._handle, pointTag, position)),
      );

  const GridRef._fromValue(this._terminal, this._value);

  /// The raw cell handle at this position.
  int get cell => check(bindings.gridRefCell(_value));

  /// The cell's full grapheme cluster as a string, or empty if the cell
  /// has no text.
  String get content {
    final codepoints = graphemes;
    return codepoints.isEmpty ? '' : String.fromCharCodes(codepoints);
  }

  /// The cell's grapheme cluster as a list of Unicode codepoints. The
  /// primary codepoint is first, followed by any combining codepoints.
  /// Empty if the cell has no text.
  List<int> get graphemes => check(bindings.gridRefGraphemes(_value));

  @override
  int get hashCode => Object.hash(GridRef, _terminal, _value);

  /// The hyperlink URI at this position, or null if the cell has no
  /// hyperlink.
  String? get hyperlinkUri {
    final (code, uri) = bindings.gridRefHyperlinkUri(_value);
    if (code == Result.noValue) return null;
    checkCode(code);
    return uri.isEmpty ? null : uri;
  }

  /// Whether the cell is the first cell of a wide character.
  bool get isWide => wide == CellWidth.wide;

  /// The raw row handle at this position.
  int get row => check(bindings.gridRefRow(_value));

  /// Whether this row is soft-wrapped to the next row.
  bool get rowWrap => check(bindings.rowGetWrap(row));

  /// The [Style] of the cell at this position.
  Style get style => check(bindings.gridRefStyle(_value));

  /// The cell's width: [CellWidth.narrow], [CellWidth.wide], or
  /// [CellWidth.spacerTail].
  CellWidth get wide => check(bindings.cellGetWide(cell));

  @override
  bool operator ==(Object other) =>
      other is GridRef &&
      identical(other._terminal, _terminal) &&
      other._value == _value;

  /// Converts this grid reference to coordinates in the given coordinate
  /// space. Returns null if the reference falls outside the requested
  /// system (e.g. a scrollback row cannot be expressed in active
  /// coordinates).
  Position? positionIn(PointTag pointTag) {
    final (code, position) = bindings.terminalPointFromGridRef(
      _terminal._handle,
      _value,
      pointTag,
    );
    if (code == Result.noValue) return null;
    checkCode(code);
    return position;
  }

  @override
  String toString() => 'GridRef(${_value.x},${_value.y})';
}
