import 'package:meta/meta.dart';

import '../../bindings/bindings.dart';
import '../../ffi/libghostty_enums.g.dart';

/// A packed 16-bit terminal mode identifier (DEC private or ANSI).
///
/// Encodes a mode value (bits 0-14) and an ANSI flag (bit 15) into a single
/// 16-bit integer. DEC private modes (e.g. `?1`) have bit 15 clear; ANSI
/// modes (e.g. mode 4) have it set.
///
/// The packed layout (least-significant bit first) is:
/// - Bits 0-14: mode value (0-32767)
/// - Bit 15: ANSI flag (0 = DEC private mode, 1 = ANSI mode)
///
/// Use the named constructors for well-known modes. Pass to
/// [Terminal.modeGet] and [Terminal.modeSet] to query or change terminal
/// mode state.
///
/// ```dart
/// terminal.modeSet(const TerminalMode.bracketedPaste(), value: true);
/// final enabled = terminal.modeGet(const TerminalMode.cursorVisible());
/// ```
extension type const TerminalMode._(int value) {
  @internal
  const TerminalMode.raw(this.value);

  /// DEC private mode 1: cursor keys send application sequences.
  const TerminalMode.cursorKeys() : value = 1;

  /// DEC private mode 3: 132/80 column mode.
  const TerminalMode.column132() : value = 3;

  /// DEC private mode 4: slow scroll.
  const TerminalMode.slowScroll() : value = 4;

  /// DEC private mode 5: reverse video.
  const TerminalMode.reverseColors() : value = 5;

  /// DEC private mode 6: origin mode.
  const TerminalMode.origin() : value = 6;

  /// DEC private mode 7: auto-wrap mode.
  const TerminalMode.autoWrap() : value = 7;

  /// DEC private mode 8: auto-repeat keys.
  const TerminalMode.autoRepeat() : value = 8;

  /// DEC private mode 9: X10 mouse reporting.
  const TerminalMode.x10Mouse() : value = 9;

  /// DEC private mode 12: cursor blink.
  const TerminalMode.cursorBlinking() : value = 12;

  /// DEC private mode 25: cursor visible (DECTCEM).
  const TerminalMode.cursorVisible() : value = 25;

  /// DEC private mode 40: allow 132 column mode.
  const TerminalMode.enableMode3() : value = 40;

  /// DEC private mode 45: reverse wrap.
  const TerminalMode.reverseWrap() : value = 45;

  /// DEC private mode 47: alternate screen (legacy).
  const TerminalMode.altScreenLegacy() : value = 47;

  /// DEC private mode 66: application keypad.
  const TerminalMode.keypadKeys() : value = 66;

  /// DEC private mode 67: back-arrow key mode.
  ///
  /// When enabled, Backspace emits BS (`0x08`) in legacy key encoding.
  /// When disabled, Backspace emits DEL (`0x7f`).
  const TerminalMode.backArrowKeyMode() : value = 67;

  /// DEC private mode 69: left/right margin mode.
  const TerminalMode.leftRightMargin() : value = 69;

  /// DEC private mode 1000: normal mouse tracking.
  const TerminalMode.normalMouse() : value = 1000;

  /// DEC private mode 1002: button-event mouse tracking.
  const TerminalMode.buttonMouse() : value = 1002;

  /// DEC private mode 1003: any-event mouse tracking.
  const TerminalMode.anyMouse() : value = 1003;

  /// DEC private mode 1004: focus in/out events.
  const TerminalMode.focusEvent() : value = 1004;

  /// DEC private mode 1005: UTF-8 mouse format.
  const TerminalMode.utf8Mouse() : value = 1005;

  /// DEC private mode 1006: SGR mouse format.
  const TerminalMode.sgrMouse() : value = 1006;

  /// DEC private mode 1007: alternate scroll mode.
  const TerminalMode.alternateScroll() : value = 1007;

  /// DEC private mode 1015: URxvt mouse format.
  const TerminalMode.urxvtMouse() : value = 1015;

  /// DEC private mode 1016: SGR-Pixels mouse format.
  const TerminalMode.sgrPixelsMouse() : value = 1016;

  /// DEC private mode 1035: ignore keypad with NumLock.
  const TerminalMode.numlockKeypad() : value = 1035;

  /// DEC private mode 1036: Alt key sends ESC prefix.
  const TerminalMode.altEscPrefix() : value = 1036;

  /// DEC private mode 1039: Alt sends escape.
  const TerminalMode.altSendsEsc() : value = 1039;

  /// DEC private mode 1045: extended reverse wrap.
  const TerminalMode.reverseWrapExtended() : value = 1045;

  /// DEC private mode 1047: alternate screen.
  const TerminalMode.alternateScreen() : value = 1047;

  /// DEC private mode 1048: save cursor (DECSC).
  const TerminalMode.saveCursor() : value = 1048;

  /// DEC private mode 1049: alternate screen + save cursor + clear.
  const TerminalMode.alternateScreenSave() : value = 1049;

  /// DEC private mode 2004: bracketed paste mode.
  const TerminalMode.bracketedPaste() : value = 2004;

  /// DEC private mode 2026: synchronized output.
  const TerminalMode.syncOutput() : value = 2026;

  /// DEC private mode 2027: grapheme cluster mode.
  const TerminalMode.graphemeCluster() : value = 2027;

  /// DEC private mode 2031: report color scheme.
  const TerminalMode.colorSchemeReport() : value = 2031;

  /// DEC private mode 2048: in-band size reports.
  const TerminalMode.inBandResize() : value = 2048;

  /// ANSI mode 2: keyboard action (disable keyboard).
  const TerminalMode.kam() : value = 2 | (1 << 15);

  /// ANSI mode 4: insert mode.
  const TerminalMode.insert() : value = 4 | (1 << 15);

  /// ANSI mode 12: send/receive mode.
  const TerminalMode.srm() : value = 12 | (1 << 15);

  /// ANSI mode 20: linefeed/new line mode.
  const TerminalMode.linefeed() : value = 20 | (1 << 15);

  /// The numeric mode value (0-32767), with the ANSI flag stripped.
  int get modeValue => value & 0x7FFF;

  /// Whether this is an ANSI mode (true) or a DEC private mode (false).
  bool get isAnsi => (value >> 15) != 0;

  /// Encodes a DECRPM (DEC Private Mode Report) response sequence for this
  /// mode with the given [state].
  ///
  /// Returns the escape sequence as a string. The generated sequence has the
  /// form:
  /// - DEC private mode: `CSI ? Ps1 ; Ps2 $ y`
  /// - ANSI mode: `CSI Ps1 ; Ps2 $ y`
  ///
  /// where `Ps1` is the mode value and `Ps2` is the [ModeReportState] value.
  ///
  /// Throws [OutOfMemoryException] if the internal buffer allocation fails.
  ///
  /// ```dart
  /// final report = const TerminalMode.bracketedPaste().encodeReport(
  ///   ModeReportState.reset,
  /// );
  /// print('DECRPM response: ${report.codeUnits}');
  /// ```
  String encodeReport(ModeReportState state) {
    return check(bindings.modeReportEncode(value, state));
  }
}
