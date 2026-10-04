part of 'terminal.dart';

/// A tracked reference to a specific cell position in the terminal grid.
///
/// Created via [TrackedGridRef.at]. Unlike [GridRef], a tracked grid reference
/// follows its cell as the terminal page list changes due to scrolling,
/// pruning, resize/reflow, and similar mutations. Call [snapshot] immediately
/// before reading cell data, and call [dispose] when done.
///
/// If the tracked cell is discarded by reset, screen replacement, or terminal
/// disposal, [hasValue] becomes false and [snapshot] / [positionIn] return null.
///
/// Not intended for render loops. Use [RenderState] with [RowIterator] and
/// [CellIterator] for performance-critical rendering.
///
/// ```dart
/// final tracked = TrackedGridRef.at(
///   terminal,
///   const Position(row: 0, col: 0),
/// );
/// final ref = tracked.snapshot();
/// print(ref?.content);
/// tracked.dispose();
/// ```
final class TrackedGridRef {
  static final _finalizer = Finalizer<int>(bindings.trackedGridRefFree);

  final int _handle;
  final Terminal _terminal;

  /// Resolves and tracks the grid cell at [position] in the coordinate
  /// space identified by [pointTag].
  ///
  /// Throws [InvalidValueException] if the coordinates are out of range.
  factory TrackedGridRef.at(
    Terminal terminal,
    Position position, {
    PointTag pointTag = .active,
  }) => TrackedGridRef._(terminal, position, pointTag: pointTag);

  TrackedGridRef._(
    Terminal terminal,
    Position position, {
    PointTag pointTag = .active,
  }) : _terminal = terminal,
       _handle = check(
         bindings.terminalGridRefTrack(terminal._handle, pointTag, position),
       ) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Whether this reference currently resolves to a meaningful grid position.
  bool get hasValue => bindings.trackedGridRefHasValue(_handle);

  /// Releases the native tracked grid reference handle.
  ///
  /// Must be called to free resources; the reference must not be used
  /// afterward. It is safe to dispose after the creating terminal has been
  /// disposed.
  void dispose() {
    _finalizer.detach(this);
    bindings.trackedGridRefFree(_handle);
  }

  /// Converts this tracked reference to coordinates in the given coordinate
  /// space.
  ///
  /// Returns null if the tracked location has been discarded or cannot be
  /// represented in [pointTag].
  Position? positionIn(PointTag pointTag) {
    final (code, position) = bindings.trackedGridRefPoint(_handle, pointTag);
    if (code == Result.noValue) return null;
    checkCode(code);
    return position;
  }

  /// Moves this tracked reference to a new position.
  ///
  /// The new position is resolved against the same terminal that created this
  /// tracked reference. The terminal must not have been disposed.
  void set(Position position, {PointTag pointTag = .active}) {
    checkCode(
      bindings.trackedGridRefSet(
        _handle,
        _terminal._handle,
        pointTag,
        position,
      ),
    );
  }

  /// Creates a short-lived [GridRef] snapshot for reading cell data.
  ///
  /// The returned [GridRef] follows normal grid-reference lifetime rules.
  /// Returns null if this tracked reference no longer has a meaningful value.
  GridRef? snapshot() {
    final (code, ref) = bindings.trackedGridRefSnapshot(_handle);
    if (code == .noValue) return null;
    checkCode(code);
    return GridRef._fromValue(_terminal, ref);
  }
}
