import 'package:meta/meta.dart';

import '../bindings/bindings.dart';

/// Parses SGR (Select Graphic Rendition) escape sequence parameters into
/// typed [SgrAttribute] values.
///
/// SGR sequences set styling attributes such as bold, italic, underline, and
/// colors for text in terminal emulators (e.g. `ESC[1;31m` where `1;31` is
/// the SGR parameter list). The parser supports both semicolon (`;`) and colon
/// (`:`) separators, possibly mixed, and handles 8-color, 16-color, 256-color,
/// and RGB color formats.
///
/// Throws [OutOfMemoryException] if the native allocation fails during
/// construction.
///
/// ```dart
/// final parser = SgrParser();
/// final attrs = parser.parse([1, 38, 2, 255, 0, 0]);
/// // attrs: [SgrAttribute(tag: .bold), SgrAttribute(tag: .directColorFg, ...)]
/// parser.dispose();
/// ```
@immutable
final class SgrParser {
  static final _finalizer = Finalizer<int>(bindings.sgrFree);

  final int _handle;

  /// Creates a new SGR parser.
  ///
  /// Throws [OutOfMemoryException] if the native allocation fails.
  SgrParser() : _handle = check(bindings.sgrNew()) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Releases the native parser handle.
  ///
  /// Must be called to free resources; the parser must not be used
  /// afterward. Any [SgrAttribute] values previously returned by [parse]
  /// become invalid as well.
  void dispose() {
    _finalizer.detach(this);
    bindings.sgrFree(_handle);
  }

  /// Parses SGR [params] into a list of typed attributes.
  ///
  /// [params] are the numeric values from a CSI SGR sequence (e.g. for
  /// `ESC[1;31m`, params would be `[1, 31]`).
  ///
  /// [separators] optionally specifies the separator character for each
  /// parameter position: `";"` for semicolon or `":"` for colon. This is
  /// needed for color formats that use colon separators (e.g. `ESC[4:3m`
  /// for curly underline). Must have the same length as [params] if
  /// provided. If null, all parameters are assumed to be
  /// semicolon-separated.
  ///
  /// The parser makes an internal copy of the data, so [params] and
  /// [separators] can be modified after this call.
  ///
  /// Throws [OutOfMemoryException] if the internal copy allocation fails.
  ///
  /// ```dart
  /// // Curly underline with colon separator
  /// final attrs = parser.parse([4, 3], separators: [':', ':']);
  /// ```
  List<SgrAttribute> parse(List<int> params, {List<String>? separators}) {
    checkCode(bindings.sgrSetParams(_handle, params, separators));
    final results = <SgrAttribute>[];
    for (
      var attr = bindings.sgrNext(_handle);
      attr != null;
      attr = bindings.sgrNext(_handle)
    ) {
      results.add(attr);
    }
    return results;
  }

  /// Resets the parser's iteration state to the beginning of the parameter
  /// list without clearing the parameters.
  ///
  /// After calling this, the next [parse] or internal iteration will start
  /// from the beginning.
  void reset() => bindings.sgrReset(_handle);
}
