part of 'terminal.dart';

/// Dirty state of a render state after [RenderState.update].
enum DirtyState {
  /// Not dirty: rendering can be skipped entirely.
  clean,

  /// Some rows changed: renderer can redraw incrementally using per-row
  /// dirty flags via [RowIterator.dirty].
  partial,

  /// Global state changed (e.g. colors, cursor shape, screen switch):
  /// renderer should redraw everything.
  full;

  factory DirtyState._fromRaw(RenderStateDirty value) => switch (value) {
    RenderStateDirty.false$ => DirtyState.clean,
    RenderStateDirty.partial => DirtyState.partial,
    RenderStateDirty.full => DirtyState.full,
  };
}

/// Stateful render snapshot of a terminal's visible viewport, optimized for
/// repeated updates and incremental redrawing of dirty regions.
///
/// A [RenderState] holds one native snapshot handle and is reusable across
/// frames. Pair it with pre-allocated [RowIterator] and [CellIterator]
/// instances to walk the snapshot without per-frame allocation.
///
/// ## Lifecycle
///
/// Construct once, call [update] each frame to refresh the snapshot from a
/// [Terminal], then iterate rows and cells using [RowIterator] / [CellIterator]
/// bound with [RowIterator.reset] / [CellIterator.reset]. After rendering,
/// clear the per-row dirty flags via [RowIterator.dirty] and set [dirty] back
/// to [DirtyState.clean]. When done with the state entirely, call [dispose].
///
/// The key design principle is that the render state only needs access to the
/// [Terminal] during the [update] call. Between updates, all data can be read
/// without holding any lock on the terminal, enabling safe multi-threaded
/// rendering.
///
/// ## Dirty Tracking
///
/// Dirty state is tracked at two independent layers: a global [dirty] state
/// and per-row flags via [RowIterator.dirty]. [update] sets these but does
/// not clear them. After rendering, set [dirty] back to [DirtyState.clean]
/// and clear each processed row's flag via [RowIterator.dirty].
///
/// ```dart
/// final renderState = RenderState();
/// final rows = RowIterator();
/// final cells = CellIterator();
///
/// void renderFrame(Terminal terminal) {
///   final dirty = renderState.update(terminal);
///   if (dirty == DirtyState.clean) return;
///
///   rows.reset(renderState);
///   while (rows.next()) {
///     if (dirty == DirtyState.partial && !rows.dirty) continue;
///     cells.reset(rows);
///     while (cells.next()) {
///       drawCell(cells.col, rows.index, cells.codepoint, cells.style);
///     }
///     rows.dirty = false;
///   }
///   renderState.dirty = DirtyState.clean;
/// }
/// ```
final class RenderState {
  static final _finalizer = Finalizer<int>(bindings.renderStateFree);

  final int _handle;

  var _dirty = DirtyState.clean;
  var _cols = 0;
  var _rows = 0;

  /// Creates an empty render state.
  ///
  /// Call [update] before reading any viewport data. Throws
  /// [OutOfMemoryException] if the native allocation fails.
  RenderState() : _handle = check(bindings.renderStateNew()) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Resolved color information from the last [update]: foreground,
  /// background, cursor color, and the full 256-color palette.
  TerminalColors get colors => check(bindings.renderStateGetColors(_handle));

  /// Viewport width in cells from the last [update].
  int get cols => _cols;

  /// Cursor state from the last [update]: position, visibility, blink,
  /// shape, and password input flag. If the cursor is outside the
  /// viewport, [Cursor.position] defaults to zero and [Cursor.wideTail]
  /// defaults to false.
  Cursor get cursor {
    final raw = check(bindings.renderStateGetCursor(_handle));
    if (!raw.inViewport) {
      return Cursor(
        visible: raw.visible,
        blinking: raw.blinking,
        passwordInput: raw.passwordInput,
        shape: raw.visualStyle,
      );
    }
    return Cursor(
      position: Position(row: raw.viewportY, col: raw.viewportX),
      visible: raw.visible,
      blinking: raw.blinking,
      wideTail: raw.viewportWideTail,
      passwordInput: raw.passwordInput,
      shape: raw.visualStyle,
    );
  }

  /// Global dirty state from the last [update].
  DirtyState get dirty => _dirty;

  /// Sets the global dirty state, typically to [DirtyState.clean] after a
  /// frame has been rendered.
  ///
  /// Only affects the render-state-wide flag. Per-row dirty flags are
  /// independent; clear them via [RowIterator.dirty] during (or after)
  /// the render loop.
  set dirty(DirtyState value) {
    checkCode(
      bindings.renderStateSetDirty(_handle, switch (value) {
        DirtyState.clean => RenderStateDirty.false$,
        DirtyState.partial => RenderStateDirty.partial,
        DirtyState.full => RenderStateDirty.full,
      }),
    );
    _dirty = value;
  }

  /// Viewport height in cells from the last [update].
  int get rows => _rows;

  /// Releases the native render state handle.
  ///
  /// Must be called to free resources; the render state must not be used
  /// afterward.
  void dispose() {
    _finalizer.detach(this);
    bindings.renderStateFree(_handle);
  }

  /// Snapshots [terminal]'s state and consumes its dirty flag.
  ///
  /// After this call, all render state properties ([cols], [rows], [colors],
  /// [cursor]) reflect the terminal's current state, and [dirty] indicates
  /// what changed. Does not clear this render state's own dirty tracking;
  /// after rendering, set [dirty] to [DirtyState.clean] and clear per-row
  /// flags via [RowIterator.dirty] during the render loop.
  ///
  /// Any [RowIterator] or [CellIterator] previously bound to this render
  /// state must be rebound via [RowIterator.reset] / [CellIterator.reset]
  /// before use.
  ///
  /// Throws [OutOfMemoryException] if updating requires allocation and
  /// that allocation fails.
  DirtyState update(Terminal terminal) {
    checkCode(bindings.renderStateUpdate(_handle, terminal._handle));
    final summary = check(bindings.renderStateGetSummary(_handle));
    _dirty = DirtyState._fromRaw(summary.dirty);
    _cols = summary.cols;
    _rows = summary.rows;
    return _dirty;
  }
}
