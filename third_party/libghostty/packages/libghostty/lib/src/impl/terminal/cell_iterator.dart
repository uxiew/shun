part of 'terminal.dart';

/// Reusable iterator over the cells of a row inside a [RenderState] snapshot.
///
/// Allocate once and reuse across rows and frames. Advance with [next]
/// (sequential) or [select] (random access within the row) and read the
/// current cell via the getter properties; there is no standalone cell
/// object.
///
/// Bind to a row with [reset]; call [reset] again after each
/// [RowIterator.next] or [RenderState.update] so the iterator tracks the
/// current row.
///
/// ```dart
/// final cells = CellIterator();
///
/// rows.reset(renderState);
/// while (rows.next()) {
///   cells.reset(rows);
///   while (cells.next()) {
///     print('col ${cells.col}: ${cells.content}');
///   }
/// }
/// ```
final class CellIterator {
  static final _finalizer = Finalizer<int>(bindings.rowCellsFree);

  final int _handle;

  var _rawCell = 0;
  var _graphemeLen = 0;
  var _codepoint = 0;
  var _styleId = -1;
  var _prevStyleId = -1;
  var _cachedStyle = const Style();
  var _wide = CellWidth.narrow;
  var _col = -1;
  var _isSelected = false;
  var _textValid = false;
  var _metadataValid = false;
  var _selectedValid = false;

  /// Creates an unbound cell iterator.
  ///
  /// Must be populated with [reset] before [next] or [select] is called.
  /// Throws [OutOfMemoryException] if the native allocation fails.
  CellIterator() : _handle = check(bindings.rowCellsNew()) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Resolved background color of the current cell, or null when the cell
  /// has no explicit background. Resolves palette indices through the
  /// active palette; when null, the caller should use the terminal's
  /// default background.
  RgbColor? get background {
    final (code, rgb) = bindings.rowCellsGetBgColor(_handle);
    return code == .success ? rgb : null;
  }

  /// Resolved background as packed ARGB int, or null if unset.
  int? get backgroundArgb {
    final (code, argb) = bindings.rowCellsGetBgColorArgb(_handle);
    return code == .success ? argb : null;
  }

  /// Primary codepoint of the current cell, or 0 if the cell has no text.
  int get codepoint {
    _ensureText();
    return _codepoint;
  }

  /// Column index of the current cell within the row (zero-based).
  ///
  /// Undefined before the first successful [next] or [select] call.
  int get col => _col;

  /// Full grapheme cluster of the current cell as a string, or empty if
  /// the cell has no text.
  String get content {
    _ensureText();
    if (_graphemeLen == 0) return '';
    if (_graphemeLen == 1) return String.fromCharCode(_codepoint);
    return String.fromCharCodes(
      check(bindings.rowCellsGetGraphemes(_handle, _graphemeLen)),
    );
  }

  /// Resolved foreground color of the current cell, or null when the cell
  /// has no explicit foreground. Resolves palette indices through the
  /// active palette. Bold color handling is not applied; handle bold
  /// styling separately. When null, the caller should use the terminal's
  /// default foreground.
  RgbColor? get foreground {
    final (code, rgb) = bindings.rowCellsGetFgColor(_handle);
    return code == .success ? rgb : null;
  }

  /// Resolved foreground as packed ARGB int, or null if unset.
  int? get foregroundArgb {
    final (code, argb) = bindings.rowCellsGetFgColorArgb(_handle);
    return code == .success ? argb : null;
  }

  /// Number of codepoints in the current cell's grapheme cluster (0 =
  /// empty).
  int get graphemeLength {
    _ensureText();
    return _graphemeLen;
  }

  /// Whether the current cell has a hyperlink (OSC 8).
  bool get hasHyperlink {
    _ensureText();
    return check(bindings.cellGetHasHyperlink(_rawCell));
  }

  /// Whether the current cell has non-default styling attributes.
  bool get hasStyling => check(bindings.rowCellsGetHasStyling(_handle));

  /// Whether the current cell contains any text.
  bool get hasText {
    _ensureText();
    return _graphemeLen > 0;
  }

  /// Whether the current cell is protected (DECSCA).
  bool get isProtected {
    _ensureText();
    return check(bindings.cellGetProtected(_rawCell));
  }

  /// Whether the current cell is contained within the current selection.
  ///
  /// Returns true when the cell's column is within the current row's
  /// row-local selection range, and false otherwise. Rendering colors,
  /// inversion, etc are caller policy.
  bool get isSelected {
    if (!_selectedValid) {
      _isSelected = check(bindings.rowCellsGetSelected(_handle));
      _selectedValid = true;
    }
    return _isSelected;
  }

  /// Semantic content type of the current cell.
  SemanticContent get semanticContent {
    _ensureText();
    return check(bindings.cellGetSemanticContent(_rawCell));
  }

  /// Style of the current cell. Cached per style id to avoid redundant
  /// lookups across cells sharing the same style.
  Style get style {
    _ensureMetadata();
    if (_styleId != _prevStyleId) {
      _prevStyleId = _styleId;
      _cachedStyle = check(bindings.rowCellsGetStyle(_handle));
    }
    return _cachedStyle;
  }

  /// Internal style identifier for the current cell. Cells with the same
  /// style id share identical styling attributes.
  int get styleId {
    _ensureMetadata();
    return _styleId;
  }

  /// Cell width: [CellWidth.narrow], [CellWidth.wide], or
  /// [CellWidth.spacerTail] (the second cell of a wide character).
  CellWidth get wide {
    _ensureMetadata();
    return _wide;
  }

  /// Releases the native iterator handle.
  ///
  /// Must be called to free resources; the iterator must not be used
  /// afterward.
  void dispose() {
    _finalizer.detach(this);
    bindings.rowCellsFree(_handle);
  }

  /// Advances to the next cell. Returns true when a cell is available and
  /// the getter properties reflect it; returns false when the row is
  /// exhausted.
  bool next() {
    if (!bindings.rowCellsNext(_handle)) return false;
    _col++;
    _invalidate();
    return true;
  }

  /// Rebinds this iterator to the current row of [rowIterator] and
  /// rewinds to the first cell.
  ///
  /// The row iterator must be positioned on a valid row (i.e. its most
  /// recent [RowIterator.next] must have returned true). Subsequent
  /// [next] / [select] calls read cells from that row.
  void reset(RowIterator rowIterator) {
    checkCode(bindings.rowCellsInit(_handle, rowIterator._handle));
    _col = -1;
    _prevStyleId = -1;
    _invalidate();
  }

  /// Positions the iterator at column [col] within the current row so
  /// subsequent reads reflect that cell.
  ///
  /// Can be used instead of or mixed with [next] for random access.
  /// Calling [next] after [select] advances from the selected position.
  ///
  /// Throws [InvalidValueException] if [col] is out of range.
  void select(int col) {
    checkCode(bindings.rowCellsSelect(_handle, col));
    _col = col;
    _invalidate();
  }

  void _ensureMetadata() {
    if (!_metadataValid) _refreshMetadata();
  }

  void _ensureText() {
    if (!_textValid) _refreshMetadata();
  }

  void _invalidate() {
    _textValid = false;
    _metadataValid = false;
    _selectedValid = false;
  }

  void _refreshMetadata() {
    final rowCell = check(bindings.rowCellsGetSummary(_handle));
    _rawCell = rowCell.rawCell;
    _graphemeLen = rowCell.graphemeLen;
    _isSelected = rowCell.selected;
    _selectedValid = true;

    final cell = check(bindings.cellGetSummary(_rawCell));
    _styleId = cell.styleId;
    _codepoint = _graphemeLen > 0 ? cell.codepoint : 0;
    _wide = cell.wide;
    _textValid = true;
    _metadataValid = true;
  }
}
