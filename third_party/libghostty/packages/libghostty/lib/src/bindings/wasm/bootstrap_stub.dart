/// Native bindings are installed eagerly by their focused modules.
///
/// This no-op keeps the cross-platform package bootstrap API symmetric; native
/// callers never need to load an external artifact.
///
/// ```dart
/// await initializeForWeb(Uri());
/// ```
Future<void> initializeForWeb(Uri wasmUri) async {}
