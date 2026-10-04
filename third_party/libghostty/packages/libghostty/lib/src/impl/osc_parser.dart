import 'package:meta/meta.dart';

import '../bindings/bindings.dart';
import '../ffi/libghostty_enums.g.dart';

/// The result of parsing an OSC sequence.
///
/// Query [type] to determine what command was parsed, then read the
/// corresponding data field (e.g. [windowTitle] for
/// [OscCommandType.changeWindowTitle]).
class OscCommand {
  /// The parsed command type, or [OscCommandType.invalid] if the sequence
  /// was malformed.
  final OscCommandType type;

  /// The window title from a [OscCommandType.changeWindowTitle] command,
  /// or null for other command types.
  ///
  /// Valid until the next call to any method on the same [OscParser]
  /// instance (except [OscParser.dispose]). Memory is owned by the parser.
  final String? windowTitle;

  OscCommand({required this.type, this.windowTitle});
}

/// Streaming parser for OSC (Operating System Command) sequences.
///
/// Processes input byte-by-byte to handle OSC sequences that may arrive in
/// fragments across multiple reads. This avoids over-allocating buffers and
/// integrates easily into most environments.
///
/// Throws [OutOfMemoryException] if the native allocation fails during
/// construction.
///
/// ```dart
/// final parser = OscParser();
///
/// // Feed bytes of "0;My Title" (OSC set window title)
/// for (final byte in utf8.encode('0;My Title')) {
///   parser.feedByte(byte);
/// }
///
/// final command = parser.end(0x07); // BEL terminator
/// print(command.type);              // OscCommandType.changeWindowTitle
/// print(command.windowTitle);       // "My Title"
///
/// parser.dispose();
/// ```
@immutable
final class OscParser {
  static final _finalizer = Finalizer<int>(bindings.oscFree);

  final int _handle;

  /// Creates a new OSC parser.
  ///
  /// Throws [OutOfMemoryException] if the native allocation fails.
  OscParser() : _handle = check(bindings.oscNew()) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Releases the native parser handle.
  ///
  /// Must be called to free resources; the parser must not be used
  /// afterward.
  void dispose() {
    _finalizer.detach(this);
    bindings.oscFree(_handle);
  }

  /// Finalizes parsing and returns the parsed command.
  ///
  /// Call this after feeding all bytes of the OSC sequence body via
  /// [feedByte] or [feedBytes]. Do not include the opening ESC ] or the
  /// terminating character (BEL or ST) in the fed bytes.
  ///
  /// [terminator] is the byte that terminated the OSC sequence (typically
  /// 0x07 for BEL or 0x5C for ST after ESC). This is preserved in the
  /// parsed command so that responses can use the same terminator format
  /// for compatibility. For commands that do not require a response, this
  /// parameter is ignored.
  ///
  /// Always returns a result. Invalid or unrecognized sequences produce a
  /// command with type [OscCommandType.invalid]. The returned command data
  /// is valid until the next call to any method on this parser (except
  /// [dispose]).
  OscCommand end(int terminator) {
    final command = bindings.oscEnd(_handle, terminator);
    final type = bindings.oscCommandType(command);
    final windowTitle = switch (type) {
      .changeWindowTitle => bindings.oscCommandWindowTitle(command),
      _ => null,
    };
    return OscCommand(type: type, windowTitle: windowTitle);
  }

  /// Feeds a single byte to the parser.
  ///
  /// Call for each byte in the OSC sequence body (after the opening ESC ]
  /// and before the terminator).
  void feedByte(int byte) => bindings.oscFeedByte(_handle, byte);

  /// Feeds multiple bytes to the parser.
  ///
  /// Convenience method that calls [feedByte] for each byte in [bytes].
  void feedBytes(List<int> bytes) {
    for (final byte in bytes) {
      bindings.oscFeedByte(_handle, byte);
    }
  }

  /// Resets the parser to its initial state.
  ///
  /// Clears any partially parsed sequence. Useful for reusing the parser
  /// or recovering from parse errors.
  void reset() => bindings.oscReset(_handle);
}
