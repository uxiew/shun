part of 'terminal.dart';

/// Row-local selected column range in a [RenderState] snapshot.
///
/// Both columns are inclusive. [RowIterator.selection] returns null when the
/// current row does not intersect the selection captured by the render state.
typedef RowSelectionRange = ({int startCol, int endCol});

/// Reusable iterator over the rows of a [RenderState] snapshot.
///
/// Allocate once and reuse across frames. Advance with [next] and read the
/// current row via the getter properties; there is no standalone row object.
///
/// Bind to a [RenderState] with [reset]; call [reset] again after every
/// [RenderState.update] so the iterator tracks the fresh snapshot.
///
/// ```dart
/// final rows = RowIterator();
///
/// rows.reset(renderState);
/// while (rows.next()) {
///   if (rows.dirty) print('row ${rows.index} changed');
/// }
/// ```
final class RowIterator {
  static final _finalizer = Finalizer<int>(bindings.rowIteratorFree);

  final int _handle;

  late RawRowSummary _rowSummary;
  var _rowSummaryValid = false;
  var _index = -1;

  /// Creates an unbound row iterator.
  ///
  /// Must be populated with [reset] before [next] is called.
  /// Throws [OutOfMemoryException] if the native allocation fails.
  RowIterator() : _handle = check(bindings.rowIteratorNew()) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Whether the current row has been modified since its dirty flag was
  /// last cleared.
  bool get dirty => check(bindings.rowIteratorGetDirty(_handle));

  /// Sets or clears the dirty flag for the current row.
  set dirty(bool value) {
    checkCode(bindings.rowIteratorSetDirty(_handle, dirty: value));
  }

  /// Whether any cell in the current row contains a grapheme cluster
  /// (multi-codepoint character).
  bool get hasGrapheme {
    _ensureMetadata();
    return _rowSummary.grapheme;
  }

  /// Whether any cell in the current row has a hyperlink (OSC 8).
  bool get hasHyperlink {
    _ensureMetadata();
    return _rowSummary.hyperlink;
  }

  /// Whether any cell in the current row has a Kitty virtual placeholder.
  bool get hasKittyVirtualPlaceholder {
    _ensureMetadata();
    return _rowSummary.kittyVirtualPlaceholder;
  }

  /// Whether any cell in the current row has non-default styling.
  bool get hasStyled {
    _ensureMetadata();
    return _rowSummary.styled;
  }

  /// Viewport-relative row index of the current row (zero-based).
  ///
  /// Undefined before the first successful [next] call.
  int get index => _index;

  /// Selected column range for the current row, or null when the row does
  /// not intersect the selection captured by the render state.
  ///
  /// The returned columns are row-local and inclusive.
  RowSelectionRange? get selection {
    final (code, selection) = bindings.rowIteratorGetSelection(_handle);
    if (code == .noValue) return null;
    return check((code, selection));
  }

  /// Semantic prompt state of the current row.
  SemanticPrompt get semanticPrompt {
    _ensureMetadata();
    return _rowSummary.semanticPrompt;
  }

  /// Whether the current row is soft-wrapped into the next row.
  bool get wrap {
    _ensureMetadata();
    return _rowSummary.wrap;
  }

  /// Whether the current row is a continuation of a soft-wrap from the
  /// previous row.
  bool get wrapContinuation {
    _ensureMetadata();
    return _rowSummary.wrapContinuation;
  }

  /// Releases the native iterator handle.
  ///
  /// Must be called to free resources; the iterator must not be used
  /// afterward.
  void dispose() {
    _finalizer.detach(this);
    bindings.rowIteratorFree(_handle);
  }

  /// Advances to the next row. Returns true when a row is available and
  /// the getter properties reflect it; returns false when the snapshot
  /// is exhausted.
  bool next() {
    final hasNext = bindings.rowIteratorNext(_handle);
    if (hasNext) {
      _rowSummaryValid = false;
      _index++;
    }
    return hasNext;
  }

  /// Rebinds this iterator to [renderState] and rewinds to the start.
  ///
  /// The render state must have been populated via [RenderState.update].
  /// Any [CellIterator] previously bound to this iterator must be rebound
  /// via [CellIterator.reset] before further use.
  void reset(RenderState renderState) {
    checkCode(bindings.rowIteratorInit(_handle, renderState._handle));
    _rowSummaryValid = false;
    _index = -1;
  }

  void _ensureMetadata() {
    if (!_rowSummaryValid) _refreshMetadata();
  }

  void _refreshMetadata() {
    final rawRow = check(bindings.rowIteratorGetRawRow(_handle));
    _rowSummary = check(bindings.rowGetSummary(rawRow));
    _rowSummaryValid = true;
  }
}
