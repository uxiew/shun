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
@immutable
final class MouseEvent {
  static final _finalizer = Finalizer<int>(bindings.mouseEventFree);

  final int _handle;

  /// Creates a new mouse event with default values.
  ///
  /// Set the event properties ([action], [button], [mods], position via
  /// [setPosition]) before passing to [MouseEncoder.encode].
  ///
  /// Throws [OutOfMemoryException] if the native allocation fails.
  MouseEvent() : _handle = check(bindings.mouseEventNew()) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// The mouse action: [MouseAction.press], [MouseAction.release], or
  /// [MouseAction.motion].
  MouseAction get action => bindings.mouseEventGetAction(_handle);

  /// Sets the mouse action.
  set action(MouseAction value) => bindings.mouseEventSetAction(_handle, value);

  /// The mouse button, or null if no button is set.
  ///
  /// Returns null for motion events with no button pressed. Use
  /// [clearButton] to represent "no button".
  MouseButton? get button {
    final (code, button) = bindings.mouseEventGetButton(_handle);
    return code == .noValue ? null : button;
  }

  /// Sets a concrete button identity for the event.
  ///
  /// To represent "no button" (for motion events without a button held),
  /// use [clearButton] instead.
  set button(MouseButton value) => bindings.mouseEventSetButton(_handle, value);

  /// Keyboard modifiers held during the mouse event.
  Mods get mods => Mods.fromValue(bindings.mouseEventGetMods(_handle));

  /// Sets the keyboard modifiers held during the event.
  set mods(Mods value) => bindings.mouseEventSetMods(_handle, value.value);

  /// Surface-space pixel coordinates of the mouse event.
  (double x, double y) get position => bindings.mouseEventGetPosition(_handle);

  /// Clears the button to "none".
  ///
  /// Use this for motion events where no button is pressed. The [button]
  /// getter will return null after this call.
  void clearButton() => bindings.mouseEventClearButton(_handle);

  /// Releases the native mouse event handle.
  ///
  /// Must be called to free resources; the event must not be used
  /// afterward.
  void dispose() {
    _finalizer.detach(this);
    bindings.mouseEventFree(_handle);
  }

  /// Sets the event position in surface-space pixels.
  void setPosition({required double x, required double y}) {
    bindings.mouseEventSetPosition(_handle, x, y);
  }
}
