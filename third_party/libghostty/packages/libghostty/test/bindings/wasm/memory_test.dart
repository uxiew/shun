@Tags(['wasm'])
library;

import 'dart:js_interop_unsafe';

import 'package:libghostty/src/bindings/wasm/adapter.dart';
import 'package:libghostty/src/bindings/wasm/memory.dart';
import 'package:libghostty/src/generated/libghostty_wasm.g.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  group('Memory', () {
    late web.Memory wasmMemory;
    late Memory memory;

    setUp(() {
      wasmMemory = web.Memory(web.MemoryDescriptor(initial: 1, maximum: 2));
      final exports = newJsObject()..['memory'] = wasmMemory;
      memory = Memory(GhosttyExports(exports));
    });

    test('reuses typed views while the buffer is stable', () {
      final first = memory.view;

      final second = memory.view;

      expect(identical(second, first), isTrue);
      expect(memory.refreshCount, 1);
    });

    test('refreshes typed views after memory growth', () {
      final before = memory.view;
      wasmMemory.grow(1);

      final after = memory.view;

      expect(identical(after, before), isFalse);
      expect(memory.refreshCount, 2);
    });

    test('reads and writes through the refreshed buffer', () {
      memory.writeU32(0, 0x10203040);
      wasmMemory.grow(1);

      memory.writeU32(65536, 0x50607080);

      expect(memory.readU32(0), 0x10203040);
      expect(memory.readU32(65536), 0x50607080);
      expect(memory.refreshCount, 2);
    });

    test('reads a terminated C string', () {
      memory.writeBytes(16, const [0x6c, 0xc3, 0xb9, 0x00]);

      expect(memory.readCString(16), 'lù');
    });

    test('rejects an unterminated C string', () {
      memory.writeBytes(65535, const [0x6c]);

      expect(
        () => memory.readCString(65535),
        throwsA(
          predicate<Object>(
            (error) =>
                error is StateError &&
                error.toString().contains('Unterminated') &&
                error.toString().contains('65535'),
          ),
        ),
      );
    });

    test('rejects a C string address outside memory', () {
      expect(
        () => memory.readCString(65536),
        throwsA(
          predicate<Object>(
            (error) =>
                error is StateError &&
                error.toString().contains('Invalid') &&
                error.toString().contains('65536'),
          ),
        ),
      );
    });

    test('rejects an out-of-bounds byte read', () {
      expect(
        () => memory.readBytes(65535, 2),
        throwsA(
          predicate<Object>(
            (error) =>
                error is StateError &&
                error.toString().contains('address=65535') &&
                error.toString().contains('length=2'),
          ),
        ),
      );
    });

    test('rejects an out-of-bounds byte write', () {
      expect(
        () => memory.writeBytes(65535, const [1, 2]),
        throwsA(
          predicate<Object>(
            (error) =>
                error is StateError &&
                error.toString().contains('address=65535') &&
                error.toString().contains('length=2'),
          ),
        ),
      );
    });
  });
}
