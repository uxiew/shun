import '../bindings/bindings.dart';
import '../ffi/libghostty_enums.g.dart';

/// Adds [encode] to [FocusEvent] for encoding focus gained/lost events into
/// terminal escape sequences (CSI I / CSI O) for focus reporting mode
/// (mode 1004).
extension FocusEventEncode on FocusEvent {
  /// Encodes this focus event into a terminal escape sequence.
  ///
  /// Returns `CSI I` for [FocusEvent.gained] or `CSI O` for
  /// [FocusEvent.lost].
  ///
  /// Throws [OutOfMemoryException] if the internal buffer allocation fails.
  ///
  /// ```dart
  /// final seq = FocusEvent.gained.encode();
  /// ```
  String encode() => check(bindings.focusEncode(this));
}

/// Adds [encode] to [ColorScheme] for encoding color-scheme reports.
extension ColorSchemeReportEncode on ColorScheme {
  /// Encodes this color scheme as the terminal escape sequence used by
  /// color-scheme reporting mode.
  ///
  /// [ColorScheme.dark] emits `ESC [ ? 997 ; 1 n`; [ColorScheme.light] emits
  /// `ESC [ ? 997 ; 2 n`. Hosts should only send unsolicited reports when
  /// color-scheme reporting mode 2031 is enabled.
  String encode() => check(bindings.colorSchemeReportEncode(this));
}

/// Adds [encode] to [SizeReportStyle] for encoding terminal size reports
/// into escape sequences, supporting in-band size reports (mode 2048) and
/// XTWINOPS responses (CSI 14 t, CSI 16 t, CSI 18 t).
extension SizeReportStyleEncode on SizeReportStyle {
  /// Encodes a size report in this style with the given terminal dimensions.
  ///
  /// The output format depends on this [SizeReportStyle]:
  /// - [SizeReportStyle.mode2048]: `ESC [ 48 ; rows ; cols ; height ; width t`
  /// - [SizeReportStyle.csi14T]: `ESC [ 4 ; height ; width t`
  /// - [SizeReportStyle.csi16T]: `ESC [ 6 ; height ; width t`
  /// - [SizeReportStyle.csi18T]: `ESC [ 8 ; rows ; cols t`
  ///
  /// Throws [OutOfMemoryException] if the internal buffer allocation fails.
  ///
  /// ```dart
  /// final seq = SizeReportStyle.csi18T.encode(
  ///   rows: 24, columns: 80, cellWidth: 8, cellHeight: 16,
  /// );
  /// ```
  String encode({
    required int rows,
    required int columns,
    required int cellWidth,
    required int cellHeight,
  }) => check(
    bindings.sizeReportEncode(this, rows, columns, cellWidth, cellHeight),
  );
}
