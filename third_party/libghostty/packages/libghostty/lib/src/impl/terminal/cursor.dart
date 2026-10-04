part of 'terminal.dart';

/// An immutable snapshot of the terminal cursor state.
@immutable
final class Cursor {
  /// Position within the viewport.
  final Position position;

  /// Whether the cursor is visible.
  final bool visible;

  /// Whether the cursor is on the tail of a wide character.
  final bool wideTail;

  /// The visual shape of the cursor (block, underline, or bar).
  final CursorShape shape;

  /// Whether the cursor blinks.
  final bool blinking;

  /// Whether the terminal is in password input mode.
  final bool passwordInput;

  const Cursor({
    this.position = const Position(row: 0, col: 0),
    this.visible = true,
    this.shape = .block,
    this.wideTail = false,
    this.blinking = false,
    this.passwordInput = false,
  });

  @override
  int get hashCode =>
      Object.hash(position, visible, shape, blinking, passwordInput, wideTail);

  @override
  bool operator ==(Object other) =>
      other is Cursor &&
      other.position == position &&
      other.visible == visible &&
      other.shape == shape &&
      other.blinking == blinking &&
      other.passwordInput == passwordInput &&
      other.wideTail == wideTail;

  /// Returns a copy with the given fields replaced.
  Cursor copyWith({
    Position? position,
    bool? visible,
    CursorShape? shape,
    bool? blinking,
    bool? passwordInput,
    bool? wideTail,
  }) {
    return Cursor(
      position: position ?? this.position,
      visible: visible ?? this.visible,
      shape: shape ?? this.shape,
      blinking: blinking ?? this.blinking,
      passwordInput: passwordInput ?? this.passwordInput,
      wideTail: wideTail ?? this.wideTail,
    );
  }

  @override
  String toString() =>
      'Cursor(position: $position, visible: $visible, shape: $shape)';
}
