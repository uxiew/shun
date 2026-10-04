import '../../generated/libghostty_wasm.g.dart';

extension WasmAllocation on GhosttyExports {
  int allocateOpaque() => ghostty_wasm_alloc_opaque();

  void freeOpaque(int pointer) => ghostty_wasm_free_opaque(pointer);

  int allocateBytes(int length) => ghostty_wasm_alloc(length);

  void freeBytes(int pointer, int length) => ghostty_wasm_free(pointer, length);
}
