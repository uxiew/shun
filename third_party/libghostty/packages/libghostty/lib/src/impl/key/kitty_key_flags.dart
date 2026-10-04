import 'package:meta/meta.dart';

/// Kitty keyboard protocol mode flags.
///
/// Bitflags representing the various modes of the Kitty keyboard protocol.
/// Programs running in the terminal set these via Kitty protocol escape
/// sequences; the terminal exposes the current value through
/// [Terminal.kittyKeyboardFlags].
///
/// Combine flags using the `|` operator. Use [disabled] for legacy encoding
/// (all flags off), or [all] to enable every mode.
///
/// ```dart
/// final flags = KittyKeyFlags.disambiguate() | KittyKeyFlags.reportEvents();
/// encoder.setKittyFlags(flags);
/// ```
extension type const KittyKeyFlags._(int value) {
  /// All Kitty keyboard protocol flags enabled.
  const KittyKeyFlags.all() : value = 0x1F;

  /// Kitty keyboard protocol disabled (all flags off). The encoder uses
  /// legacy encoding in this state.
  const KittyKeyFlags.disabled() : value = 0;

  /// Disambiguate escape codes so that keys like Escape, Enter, Tab, and
  /// Backspace are reported unambiguously.
  const KittyKeyFlags.disambiguate() : value = 1 << 0;

  @internal
  const KittyKeyFlags.fromValue(this.value);

  /// Report all key events, including those normally handled by the terminal
  /// itself (e.g. Ctrl+C).
  const KittyKeyFlags.reportAll() : value = 1 << 3;

  /// Report alternate key codes in the escape sequence.
  const KittyKeyFlags.reportAlternates() : value = 1 << 2;

  /// Report associated text with key events.
  const KittyKeyFlags.reportAssociated() : value = 1 << 4;

  /// Report key press and release events (not just press).
  const KittyKeyFlags.reportEvents() : value = 1 << 1;

  /// Whether all flags are off (legacy encoding).
  bool get isDisabled => value == 0;

  KittyKeyFlags operator &(KittyKeyFlags other) =>
      .fromValue(value & other.value);

  KittyKeyFlags operator |(KittyKeyFlags other) =>
      .fromValue(value | other.value);
}
