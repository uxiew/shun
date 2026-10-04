import 'package:meta/meta.dart';

/// Keyboard modifier keys bitmask tracking which modifiers are pressed and,
/// where supported by the platform, which side (left or right) is active.
///
/// Modifier side bits ([shiftSide], [ctrlSide], [altSide], [superSide]) are
/// only meaningful when the corresponding modifier bit is set. Not all
/// platforms distinguish between left and right modifier keys.
///
/// Combine modifiers using the `|` operator. Test individual modifiers with
/// the `has*` getters, and test side with the `is*Right` getters.
///
/// ```dart
/// final mods = Mods.ctrl() | Mods.shift();
/// print(mods.hasCtrl);    // true
/// print(mods.hasShift);   // true
/// print(mods.isCtrlRight); // false (left by default)
/// ```
extension type const Mods._(int value) {
  /// Alt/Option key is pressed.
  const Mods.alt() : value = 1 << 2;

  /// Right Alt is pressed (0 = left, 1 = right). Only meaningful when
  /// [alt] is also set.
  const Mods.altSide() : value = 1 << 8;

  /// Caps Lock is active.
  const Mods.capsLock() : value = 1 << 4;

  /// Control key is pressed.
  const Mods.ctrl() : value = 1 << 1;

  /// Right Ctrl is pressed (0 = left, 1 = right). Only meaningful when
  /// [ctrl] is also set.
  const Mods.ctrlSide() : value = 1 << 7;

  @internal
  const Mods.fromValue(this.value);

  /// No modifiers pressed.
  const Mods.none() : value = 0;

  /// Num Lock is active.
  const Mods.numLock() : value = 1 << 5;

  /// Shift key is pressed.
  const Mods.shift() : value = 1 << 0;

  /// Right Shift is pressed (0 = left, 1 = right). Only meaningful when
  /// [shift] is also set.
  const Mods.shiftSide() : value = 1 << 6;

  /// Super/Command/Windows key is pressed.
  const Mods.superKey() : value = 1 << 3;

  /// Right Super is pressed (0 = left, 1 = right). Only meaningful when
  /// [superKey] is also set.
  const Mods.superSide() : value = 1 << 9;

  /// Whether Alt/Option is pressed.
  bool get hasAlt => value & (1 << 2) != 0;

  /// Whether Caps Lock is active.
  bool get hasCapsLock => value & (1 << 4) != 0;

  /// Whether Control is pressed.
  bool get hasCtrl => value & (1 << 1) != 0;

  /// Whether Num Lock is active.
  bool get hasNumLock => value & (1 << 5) != 0;

  /// Whether Shift is pressed.
  bool get hasShift => value & (1 << 0) != 0;

  /// Whether Super/Command/Windows is pressed.
  bool get hasSuper => value & (1 << 3) != 0;

  /// Whether the right Alt key is the active side. Only meaningful when
  /// [hasAlt] is true.
  bool get isAltRight => value & (1 << 8) != 0;

  /// Whether the right Ctrl key is the active side. Only meaningful when
  /// [hasCtrl] is true.
  bool get isCtrlRight => value & (1 << 7) != 0;

  /// Whether no modifiers are pressed.
  bool get isEmpty => value == 0;

  /// Whether the right Shift key is the active side. Only meaningful when
  /// [hasShift] is true.
  bool get isShiftRight => value & (1 << 6) != 0;

  /// Whether the right Super key is the active side. Only meaningful when
  /// [hasSuper] is true.
  bool get isSuperRight => value & (1 << 9) != 0;

  Mods operator &(Mods other) => Mods.fromValue(value & other.value);

  Mods operator ^(Mods other) => Mods.fromValue(value ^ other.value);

  Mods operator |(Mods other) => Mods.fromValue(value | other.value);
}
