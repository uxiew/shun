import '../bindings/bindings.dart';
import '../ffi/libghostty_enums.g.dart';

/// Compile-time build configuration of the native libghostty library.
///
/// These values reflect the options the library was built with and are
/// constant for the lifetime of the process. Access via the [instance]
/// singleton.
///
/// ```dart
/// final info = LibGhosttyBuildInfo.instance;
/// print('${info.versionString} (${info.optimizeMode})');
/// print('SIMD: ${info.simd}, Kitty graphics: ${info.kittyGraphics}');
/// ```
class LibGhosttyBuildInfo {
  /// Singleton instance. All values are populated once on first access.
  static final instance = LibGhosttyBuildInfo._();

  /// Whether SIMD-accelerated code paths are enabled in the native library.
  final bool simd;

  /// Whether Kitty graphics protocol support is available in the native
  /// library.
  final bool kittyGraphics;

  /// Whether tmux control mode support is available in the native library.
  final bool tmuxControlMode;

  /// Optimization mode the library was built with (debug, release-safe,
  /// release-small, or release-fast).
  final OptimizeMode optimizeMode;

  /// Full version string (e.g. "1.2.3" or "1.2.3-dev+abcdef").
  final String versionString;

  /// Major version number.
  final int versionMajor;

  /// Minor version number.
  final int versionMinor;

  /// Patch version number.
  final int versionPatch;

  /// Build metadata string (e.g. commit hash). Empty if no build metadata
  /// is present.
  final String versionBuild;

  LibGhosttyBuildInfo._()
    : simd = _getBool(.simd),
      kittyGraphics = _getBool(.kittyGraphics),
      tmuxControlMode = _getBool(.tmuxControlMode),
      optimizeMode = .fromValue(_getInt(.optimize)),
      versionString = _getString(.versionString),
      versionMajor = _getInt(.versionMajor),
      versionMinor = _getInt(.versionMinor),
      versionPatch = _getInt(.versionPatch),
      versionBuild = _getString(.versionBuild);

  static bool _getBool(BuildInfo data) => check(bindings.buildInfoBool(data));

  static int _getInt(BuildInfo data) => check(bindings.buildInfo(data));

  static String _getString(BuildInfo data) {
    return check(bindings.buildInfoString(data));
  }
}
