import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

JSObject newJsObject() {
  return (globalContext['Object']! as JSFunction).callAsConstructor<JSObject>();
}

/// Wraps a JS function as a typed WASM function reference for use in
/// WebAssembly.Table.
///
/// WASM tables only accept typed function references, not plain JS functions.
/// This compiles a tiny adapter module that imports the JS function and
/// re-exports it with the correct WASM type signature. This is the standard
/// approach used by Emscripten's addFunction() and Dart's wasm_ffi package.
/// Compiled modules are cached per signature.
final _adapterModuleCache = <(int, int), web.Module>{};

JSAny wrapJsAsWasmFunction(
  JSFunction jsFunction,
  List<String> params, [
  List<String> results = const [],
]) {
  final module = _adapterModuleCache.putIfAbsent((
    params.length,
    results.length,
  ), () => _compileAdapterModule(params.length, results.isNotEmpty));
  final env = newJsObject();
  env['fn'] = jsFunction;
  final imports = newJsObject();
  imports['env'] = env;
  return web.Instance(module, imports).exports['f']!;
}

/// Compiles an adapter module: imports env.fn, re-exports as typed "f".
///
/// The module has one function type (all i32 params, optional i32 return),
/// imports env.fn with that type, declares a wrapper that forwards all
/// arguments to the import, and exports the wrapper as "f".
web.Module _compileAdapterModule(int paramCount, bool returnsI32) {
  final bytes = <int>[
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // Type section: func(i32 * paramCount) -> (i32?)
    0x01, 4 + paramCount + (returnsI32 ? 1 : 0), 0x01, 0x60,
    paramCount, ...List.filled(paramCount, 0x7f),
    if (returnsI32) ...[0x01, 0x7f] else 0x00,
    // Import section: env.fn as func type 0
    0x02, 0x0a, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x02, 0x66, 0x6e, 0x00, 0x00,
    // Function section: one func of type 0
    0x03, 0x02, 0x01, 0x00,
    // Export section: "f" as func index 1
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01,
    // Code section: forward all params to import, return result
    0x0a, 6 + paramCount * 2, 0x01, 4 + paramCount * 2, 0x00,
    for (var i = 0; i < paramCount; i++) ...[0x20, i],
    0x10, 0x00, 0x0b,
  ];
  return web.Module(Uint8List.fromList(bytes).buffer.toJS);
}
