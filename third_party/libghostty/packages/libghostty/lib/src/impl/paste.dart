import 'dart:typed_data';

import '../bindings/bindings.dart';

/// Encodes paste data for writing to the terminal PTY.
///
/// Prepares paste data for terminal input by:
/// - Stripping unsafe control bytes (NUL, ESC, DEL, etc.) by replacing them
///   with spaces
/// - Wrapping the result in bracketed paste sequences (`\x1b[200~` ...
///   `\x1b[201~`) when [bracketed] is true
/// - Replacing newlines with carriage returns when [bracketed] is false
///
/// Use [pasteIsSafe] first to check whether the data should be pasted at all
/// (e.g. to prompt the user for confirmation on multi-line pastes).
///
/// Throws [LibGhosttyException] if encoding fails.
///
/// ```dart
/// final encoded = pasteEncode('hello\nworld', bracketed: true);
/// terminal.write(encoded);
/// ```
Uint8List pasteEncode(String data, {required bool bracketed}) {
  return check(bindings.pasteEncode(data, bracketed: bracketed));
}

/// Checks whether [data] is safe to paste into a terminal without user
/// confirmation.
///
/// Data is considered unsafe if it contains:
/// - Newlines (`\n`), which can inject commands
/// - The bracketed paste end sequence (`\x1b[201~`), which can exit
///   bracketed paste mode and inject commands
///
/// This check is conservative and considers data unsafe regardless of the
/// current terminal state.
///
/// ```dart
/// pasteIsSafe('hello world');        // true
/// pasteIsSafe('rm -rf /\n');         // false
/// pasteIsSafe('\x1b[201~injected');  // false
/// ```
bool pasteIsSafe(String data) => bindings.pasteIsSafe(data);
