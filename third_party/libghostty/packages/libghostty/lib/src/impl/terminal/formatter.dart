part of 'terminal.dart';

/// Formats terminal content as plain text, VT sequences, or HTML.
///
/// Captures a reference to a [Terminal] and reads its current state on each
/// [format] call. The [Terminal] must outlive this formatter.
///
/// ```dart
/// final formatter = Formatter(
///   terminal: terminal,
///   format: FormatterFormat.plain,
/// );
/// final text = formatter.format();
/// formatter.dispose();
/// ```
@immutable
final class Formatter {
  static final _finalizer = Finalizer<int>(bindings.formatterFree);

  final int _handle;

  /// Creates a formatter for [terminal].
  ///
  /// [format] selects the output syntax (plain, vt, or html). [extra]
  /// controls which additional terminal state is included in
  /// [FormatterFormat.vt] output (cursor position, modes, palette, etc.);
  /// it has no effect on plain text or HTML output. [selection] restricts
  /// the output to the given range; when null, the entire active screen
  /// is formatted.
  ///
  /// Throws [OutOfMemoryException] when the allocation fails.
  Formatter({
    required Terminal terminal,
    required FormatterFormat format,
    bool unwrap = false,
    bool trim = false,
    FormatterExtra extra = const FormatterExtra(),
    Selection? selection,
  }) : _handle = _create(terminal, format, unwrap, trim, extra, selection) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Releases the native formatter handle.
  ///
  /// Must be called to free resources; the formatter must not be used
  /// afterward.
  void dispose() {
    _finalizer.detach(this);
    bindings.formatterFree(_handle);
  }

  /// Formats the terminal's current active screen content and returns the
  /// result as a string.
  ///
  /// Each call reads the terminal's current state, so calling [format]
  /// after a [Terminal.write] reflects the updated content.
  ///
  /// Throws [OutOfMemoryException] if the output buffer allocation fails.
  String format() => check(bindings.formatterFormat(_handle));

  static int _create(
    Terminal terminal,
    FormatterFormat format,
    bool unwrap,
    bool trim,
    FormatterExtra extra,
    Selection? selection,
  ) {
    if (selection == null) {
      return check(
        bindings.formatterTerminalNew(
          terminal._handle,
          format,
          unwrap: unwrap,
          trim: trim,
          extra: extra,
        ),
      );
    }

    if (!identical(selection.start._terminal, terminal)) {
      throw ArgumentError.value(
        selection,
        'selection',
        'must belong to formatter terminal',
      );
    }

    return check(
      bindings.formatterTerminalNew(
        terminal._handle,
        format,
        unwrap: unwrap,
        trim: trim,
        extra: extra,
        selection: selection._raw,
      ),
    );
  }
}
