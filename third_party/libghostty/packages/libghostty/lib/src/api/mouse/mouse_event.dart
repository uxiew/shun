part of '../terminal/terminal.dart';

/// A normalized mouse input event containing action, button, modifiers, and
/// surface-space position for terminal mouse encoding.
///
/// Set the event properties and pass it to [MouseEncoder.encode] to produce a
/// terminal escape sequence. Events can be reused across multiple
/// [MouseEncoder.encode] calls by changing their properties between calls.
///
/// Throws [OutOfMemoryException] if the native allocation fails during
/// construction.
///
/// ```dart
/// final event = MouseEvent()
///   ..action = MouseAction.press
///   ..button = MouseButton.left
///   ..mods = Mods.none()
///   ..setPosition(x: 10.0, y: 20.0);
///
/// final seq = encoder.encode(event);
/// if (seq.isNotEmpty) pty.write(utf8.encode(seq));
///
/// event.dispose();
/// ```
final class MouseEvent {
  static final _finalizer = Finalizer(bindings.mouse.mouseEventFree);

  final LibGhosttyHandle _handle;
  var _disposed = false;

  /// Creates a new mouse event with default values.
  ///
  /// Set the event properties ([action], [button], [mods], position via
  /// [setPosition]) before passing to [MouseEncoder.encode].
  ///
  /// Throws [OutOfMemoryException] if the native allocation fails.
  MouseEvent() : _handle = bindings.mouse.mouseEventNew() {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// The mouse action: [MouseAction.press], [MouseAction.release], or
  /// [MouseAction.motion].
  MouseAction get action {
    final handle = _requireHandle();
    return bindings.mouse.mouseEventGetAction(handle);
  }

  /// Sets the mouse action.
  set action(MouseAction value) {
    final handle = _requireHandle();
    bindings.mouse.mouseEventSetAction(handle, value);
  }

  /// The mouse button, or null if no button is set.
  ///
  /// Returns null for motion events with no button pressed. Use
  /// [clearButton] to represent "no button".
  MouseButton? get button {
    final handle = _requireHandle();
    return bindings.mouse.mouseEventGetButton(handle);
  }

  /// Sets a concrete button identity for the event.
  ///
  /// To represent "no button" (for motion events without a button held), use
  /// [clearButton] instead.
  set button(MouseButton value) {
    final handle = _requireHandle();
    bindings.mouse.mouseEventSetButton(handle, value);
  }

  /// Keyboard modifiers held during the mouse event.
  Mods get mods {
    final handle = _requireHandle();
    return Mods.fromValue(bindings.mouse.mouseEventGetMods(handle));
  }

  /// Sets the keyboard modifiers held during the event.
  set mods(Mods value) {
    final handle = _requireHandle();
    bindings.mouse.mouseEventSetMods(handle, value.value);
  }

  /// Surface-space pixel coordinates of the mouse event.
  (double x, double y) get position {
    final handle = _requireHandle();
    return bindings.mouse.mouseEventGetPosition(handle);
  }

  /// Clears the button to "none".
  ///
  /// Use this for motion events where no button is pressed. The [button]
  /// getter will return null after this call.
  void clearButton() {
    final handle = _requireHandle();
    bindings.mouse.mouseEventClearButton(handle);
  }

  /// Releases the native mouse event handle.
  ///
  /// Calling [dispose] more than once is safe. Every other member throws a
  /// [StateError] after disposal.
  void dispose() {
    if (_disposed) return;
    bindings.mouse.mouseEventFree(_handle);
    _finalizer.detach(this);
    _disposed = true;
  }

  /// Sets the event position in surface-space pixels.
  void setPosition({required double x, required double y}) {
    final handle = _requireHandle();
    bindings.mouse.mouseEventSetPosition(handle, x, y);
  }

  LibGhosttyHandle _requireHandle() {
    if (_disposed) throw StateError('MouseEvent has been disposed');
    return _handle;
  }
}
