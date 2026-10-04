import '../bindings/bindings.dart';

/// Callback invoked by libghostty to emit an internal log message.
///
/// Messages originate from the native library's Zig side and cover events
/// like unknown control sequences, kitty graphics decoding errors, and
/// other diagnostics. The debug level is only emitted by debug builds of
/// the native library; release builds compile those calls out entirely.
///
/// Byte slices received from the C ABI are already decoded into Dart
/// strings before this callback runs. The callback may be invoked from
/// any thread.
typedef LogCallback = SysLogCallback;

/// Process-global configuration hooks for the native libghostty library.
///
/// These settings are installed once at startup and affect every
/// [Terminal] instance in the process. Install them before creating any
/// terminal that relies on them.
///
/// ```dart
/// void main() {
///   LibGhostty.setLogger((level, scope, message) {
///     debugPrint('[$level]$scope: $message');
///   });
///   runApp(const MyApp());
/// }
/// ```
abstract final class LibGhostty {
  /// Clears the installed logger and releases resources held by the
  /// Dart-side callback trampoline.
  ///
  /// Safe to call multiple times. After this, log output is silently
  /// discarded until another logger is installed.
  static void clearLogger() => bindings.sysClearLogCallback();

  /// Installs [decoder] as the PNG decoder invoked by libghostty when a
  /// Kitty graphics payload arrives in PNG form.
  ///
  /// Replaces any previously installed decoder. Use [clearPngDecoder]
  /// to stop accepting PNG payloads; with no decoder installed, PNG
  /// data is rejected by the native library and no image is stored.
  /// The callback returns null to signal a decode failure, which is
  /// treated the same as having no decoder installed for that payload.
  ///
  /// The [DecodedImage.rgba] buffer is copied into a library-owned
  /// allocation before the callback returns, so the caller's buffer
  /// lifetime is not a concern. The callback may be invoked from any
  /// thread.
  ///
  /// ```dart
  /// LibGhostty.setPngDecoder((pngBytes) {
  ///   final decoded = decodePngToRgba(pngBytes);
  ///   if (decoded == null) return null;
  ///   return (width: decoded.w, height: decoded.h, rgba: decoded.pixels);
  /// });
  /// ```
  static void setPngDecoder(PngDecoder decoder) =>
      bindings.sysSetPngDecoder(decoder);

  /// Clears the installed PNG decoder and releases resources held by
  /// the Dart-side callback trampoline.
  ///
  /// Safe to call multiple times. After this, PNG payloads are
  /// rejected until another decoder is installed.
  static void clearPngDecoder() => bindings.sysClearPngDecoder();

  /// Installs [logger] as the sink for internal libghostty log messages.
  ///
  /// Replaces any previously installed logger (including the one set by
  /// [useStderrLogger]). Use [clearLogger] to stop receiving log messages;
  /// with no logger installed, log output is silently discarded.
  static void setLogger(LogCallback logger) {
    bindings.sysSetLogCallback(logger);
  }

  /// Installs the native library's built-in stderr log sink.
  ///
  /// Each message is formatted as `[level](scope): message` and written
  /// to stderr. Equivalent to registering a logger that delegates to
  /// `ghostty_sys_log_stderr`. Replaces any previously installed logger.
  static void useStderrLogger() => bindings.sysSetLogToStderr();
}
