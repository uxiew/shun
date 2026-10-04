import 'setup_vm.dart'
    if (dart.library.js_interop) 'setup_wasm.dart'
    as platform;

export 'setup_vm.dart' if (dart.library.js_interop) 'setup_wasm.dart';

final Future<void> testEnvironment = platform.setUpTestEnvironment();
