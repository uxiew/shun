part of 'terminal.dart';

/// Mutable state machine for terminal text selection gestures.
///
/// The gesture converts reusable [SelectionGestureEvent] values into selection
/// snapshots. Returned selections are not installed automatically. The
/// creating terminal must outlive this gesture for [state], [apply], and
/// [reset].
final class SelectionGesture {
  static final _finalizer = Finalizer<({int handle, Terminal terminal})>((
    token,
  ) {
    bindings.selectionGestureFree(token.handle, token.terminal._handleOrNull);
  });

  final int _handle;
  final Terminal _terminal;

  /// Creates a gesture state machine bound to [terminal].
  SelectionGesture(Terminal terminal)
    : _handle = check(bindings.selectionGestureNew()),
      _terminal = terminal {
    _finalizer.attach(this, (
      handle: _handle,
      terminal: _terminal,
    ), detach: this);
  }

  /// Current readable gesture state.
  SelectionGestureState get state {
    final raw = check(
      bindings.selectionGestureGetState(_handle, _terminal._handle),
    );
    return SelectionGestureState(
      clickCount: raw.clickCount,
      dragged: raw.dragged,
      autoscroll: raw.autoscroll,
      behavior: raw.behavior,
      anchor: raw.anchor == null ? null : ._fromValue(_terminal, raw.anchor!),
    );
  }

  /// Applies [event] and returns the produced selection snapshot, if any.
  Selection? apply(SelectionGestureEvent event) {
    final (code, raw) = bindings.selectionGestureEvent(
      _handle,
      _terminal._handle,
      event._handle,
    );
    if (code == .noValue) return null;
    checkCode(code);
    return Selection._fromRaw(_terminal, raw!);
  }

  /// Releases the native gesture handle.
  ///
  /// Must be called to free resources; the gesture must not be used afterward.
  /// It is safe to dispose after the creating terminal has been disposed.
  void dispose() {
    _finalizer.detach(this);
    bindings.selectionGestureFree(_handle, _terminal._handleOrNull);
  }

  /// Clears active gesture state while keeping this gesture reusable.
  void reset() => bindings.selectionGestureReset(_handle, _terminal._handle);
}

/// Selection behavior table for single-, double-, and triple-click gestures.
@immutable
final class SelectionGestureBehaviors {
  /// Standard terminal selection behavior: cell, word, line.
  static const standard = SelectionGestureBehaviors(
    singleClick: .cell,
    doubleClick: .word,
    tripleClick: .line,
  );

  /// Behavior for single-click selection gestures.
  final SelectionGestureBehavior singleClick;

  /// Behavior for double-click selection gestures.
  final SelectionGestureBehavior doubleClick;

  /// Behavior for triple-click selection gestures.
  final SelectionGestureBehavior tripleClick;

  /// Creates a behavior table for gesture press events.
  const SelectionGestureBehaviors({
    required this.singleClick,
    required this.doubleClick,
    required this.tripleClick,
  });
}

/// Reusable event data for a selection gesture operation.
///
/// The event kind is fixed at construction time. Set options before applying
/// the event with [SelectionGesture.apply].
final class SelectionGestureEvent {
  static final _finalizer = Finalizer<int>(bindings.selectionGestureEventFree);

  final int _handle;

  /// Creates an autoscroll tick event.
  SelectionGestureEvent.autoscrollTick() : this._(.autoscrollTick);

  /// Creates a deep-press event.
  SelectionGestureEvent.deepPress() : this._(.deepPress);

  /// Creates a drag event.
  SelectionGestureEvent.drag() : this._(.drag);

  /// Creates a press event.
  SelectionGestureEvent.press() : this._(.press);

  /// Creates a release event.
  SelectionGestureEvent.release() : this._(.release);

  SelectionGestureEvent._(SelectionGestureEventType type)
    : _handle = check(bindings.selectionGestureEventNew(type)) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Clears [option].
  void clear(SelectionGestureEventOption option) {
    checkCode(bindings.selectionGestureEventClear(_handle, option));
  }

  /// Releases the event handle.
  void dispose() {
    _finalizer.detach(this);
    bindings.selectionGestureEventFree(_handle);
  }

  /// Sets the behavior table for press events.
  void setBehaviors(SelectionGestureBehaviors behaviors) {
    checkCode(
      bindings.selectionGestureEventSetBehaviors(
        _handle,
        behaviors.singleClick,
        behaviors.doubleClick,
        behaviors.tripleClick,
      ),
    );
  }

  /// Sets drag display geometry.
  void setGeometry(SelectionGestureGeometry geometry) {
    checkCode(
      bindings.selectionGestureEventSetGeometry(
        _handle,
        columns: geometry.columns,
        cellWidth: geometry.cellWidth,
        paddingLeft: geometry.paddingLeft,
        screenHeight: geometry.screenHeight,
      ),
    );
  }

  /// Sets the surface-space pointer position.
  void setPosition(double x, double y) {
    checkCode(bindings.selectionGestureEventSetPosition(_handle, x, y));
  }

  /// Sets whether drag/autoscroll events produce a rectangular selection.
  void setRectangle({required bool value}) {
    checkCode(
      bindings.selectionGestureEventSetRectangle(_handle, value: value),
    );
  }

  /// Sets or clears the grid reference under the pointer.
  void setRef(GridRef? ref) {
    if (ref == null) return clear(.ref);
    checkCode(bindings.selectionGestureEventSetRef(_handle, ref._value));
  }

  /// Sets the maximum repeat-click distance in pixels.
  void setRepeatDistance(double value) {
    checkCode(bindings.selectionGestureEventSetRepeatDistance(_handle, value));
  }

  /// Sets the maximum interval between repeat clicks in nanoseconds.
  void setRepeatIntervalNs(int value) {
    checkCode(
      bindings.selectionGestureEventSetRepeatIntervalNs(_handle, value),
    );
  }

  /// Sets the monotonic event time in nanoseconds.
  void setTimeNs(int value) {
    checkCode(bindings.selectionGestureEventSetTimeNs(_handle, value));
  }

  /// Sets the viewport coordinate for an autoscroll tick.
  void setViewport(Position position) {
    checkCode(
      bindings.selectionGestureEventSetViewport(_handle, position: position),
    );
  }

  /// Sets word-boundary codepoints.
  ///
  /// Passing an empty list means an explicit empty boundary set. Use
  /// `clear(SelectionGestureEventOption.wordBoundaryCodepoints)` to restore
  /// libghostty defaults.
  void setWordBoundaryCodepoints(List<int> codepoints) {
    checkCode(
      bindings.selectionGestureEventSetWordBoundaryCodepoints(
        _handle,
        codepoints,
      ),
    );
  }
}

/// Display geometry used to interpret drag and autoscroll gesture events.
@immutable
final class SelectionGestureGeometry {
  /// Number of rendered terminal columns. Must be non-zero.
  final int columns;

  /// Width of one terminal cell in surface pixels. Must be non-zero.
  final int cellWidth;

  /// Left padding before the terminal grid begins in surface pixels.
  final int paddingLeft;

  /// Height of the rendered terminal surface in surface pixels. Must be
  /// non-zero.
  final int screenHeight;

  /// Creates display geometry for drag and autoscroll events.
  const SelectionGestureGeometry({
    required this.columns,
    required this.cellWidth,
    required this.paddingLeft,
    required this.screenHeight,
  });
}

/// Current readable state for a selection gesture.
@immutable
final class SelectionGestureState {
  /// Current click count. Zero means inactive.
  final int clickCount;

  /// Whether the current or last left-click gesture dragged.
  final bool dragged;

  /// Current autoscroll request.
  final SelectionGestureAutoscroll autoscroll;

  /// Current gesture behavior.
  final SelectionGestureBehavior behavior;

  /// Current left-click anchor, or null when there is no active anchor.
  final GridRef? anchor;

  /// Creates a selection gesture state snapshot.
  const SelectionGestureState({
    required this.clickCount,
    required this.dragged,
    required this.autoscroll,
    required this.behavior,
    required this.anchor,
  });
}
