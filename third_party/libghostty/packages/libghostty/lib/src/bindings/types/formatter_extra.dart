/// Extra terminal and screen state to include in formatted output.
///
/// Controls which additional state beyond cell content is emitted when
/// formatting with [FormatterFormat.vt]. All options default to false.
/// Has no effect on plain text or HTML output.
///
/// ```dart
/// final formatter = terminal.createFormatter(
///   format: FormatterFormat.vt,
///   extra: const FormatterExtra(cursor: true, modes: true),
/// );
/// ```
class FormatterExtra {
  /// Emit the 256-color palette using OSC 4 sequences.
  final bool palette;

  /// Emit terminal modes that differ from their defaults using CSI h/l.
  final bool modes;

  /// Emit scrolling region state using DECSTBM and DECSLRM sequences.
  final bool scrollingRegion;

  /// Emit tabstop positions by clearing all tabs and setting each one.
  final bool tabstops;

  /// Emit the present working directory using OSC 7.
  final bool pwd;

  /// Emit keyboard modes such as ModifyOtherKeys.
  final bool keyboard;

  /// Emit cursor position using CUP (CSI H).
  final bool cursor;

  /// Emit current SGR style state based on the cursor's active style.
  final bool style;

  /// Emit current hyperlink state using OSC 8 sequences.
  final bool hyperlink;

  /// Emit character protection mode using DECSCA.
  final bool protection;

  /// Emit Kitty keyboard protocol state using CSI > u and CSI = sequences.
  final bool kittyKeyboard;

  /// Emit character set designations and invocations.
  final bool charsets;

  const FormatterExtra({
    this.palette = false,
    this.modes = false,
    this.scrollingRegion = false,
    this.tabstops = false,
    this.pwd = false,
    this.keyboard = false,
    this.cursor = false,
    this.style = false,
    this.hyperlink = false,
    this.protection = false,
    this.kittyKeyboard = false,
    this.charsets = false,
  });

  /// All extras enabled.
  const FormatterExtra.all()
    : palette = true,
      modes = true,
      scrollingRegion = true,
      tabstops = true,
      pwd = true,
      keyboard = true,
      cursor = true,
      style = true,
      hyperlink = true,
      protection = true,
      kittyKeyboard = true,
      charsets = true;
}
