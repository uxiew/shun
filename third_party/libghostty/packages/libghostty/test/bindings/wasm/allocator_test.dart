@Tags(['wasm'])
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:libghostty/src/bindings/wasm/adapter.dart';
import 'package:libghostty/src/bindings/wasm/allocator.dart';
import 'package:libghostty/src/generated/libghostty_wasm.g.dart';
import 'package:test/test.dart';

void main() {
  group('WasmAllocation', () {
    test('forwards generic allocation and exact free length', () {
      final allocations = <int>[];
      final frees = <({int pointer, int length})>[];
      final exportsObject = newJsObject()
        ..['ghostty_wasm_alloc'] = ((JSNumber length) {
          allocations.add(length.toDartInt);
          return 32.toJS;
        }).toJS
        ..['ghostty_wasm_free'] = ((JSNumber pointer, JSNumber length) {
          frees.add((pointer: pointer.toDartInt, length: length.toDartInt));
        }).toJS;
      final exports = GhosttyExports(exportsObject);

      final pointer = exports.allocateBytes(17);
      exports.freeBytes(pointer, 17);

      expect(allocations, [17]);
      expect(frees, [(pointer: 32, length: 17)]);
    });

    test('returns null for a zero-length allocation', () {
      final allocations = <int>[];
      final exportsObject = newJsObject()
        ..['ghostty_wasm_alloc'] = ((JSNumber length) {
          allocations.add(length.toDartInt);
          return 0.toJS;
        }).toJS;
      final exports = GhosttyExports(exportsObject);

      final pointer = exports.allocateBytes(0);

      expect(pointer, 0);
      expect(allocations, [0]);
    });
  });
}
