import 'dart:convert';

import '../../generated/libghostty_enums.g.dart';
import '../../generated/libghostty_wasm.g.dart';
import '../../types/types.dart';
import '../result_helpers.dart';
import '../types.dart';
import '../wasm/allocator.dart';
import '../wasm/memory.dart';
import 'key.dart';

final class WasmKeyBindings implements KeyBindings {
  final Memory _memory;
  final GhosttyExports _exports;
  final _utf8Pointers = <int, (int pointer, int capacity)>{};

  WasmKeyBindings(GhosttyExports exports)
    : _exports = exports,
      _memory = Memory(exports);

  @override
  String keyEncoderEncode(LibGhosttyHandle encoder, LibGhosttyHandle event) {
    final lengthPointer = _requirePointer(_exports.allocateBytes(4));
    var capacity = 128;
    var allocationLength = capacity;
    var buffer = 0;
    try {
      buffer = _requirePointer(_exports.allocateBytes(allocationLength));
      var result = _exports.ghostty_key_encoder_encode(
        encoder.value,
        event.value,
        buffer,
        capacity,
        lengthPointer,
      );
      if (result == Result.outOfSpace.value) {
        _exports.freeBytes(buffer, allocationLength);
        buffer = 0;
        capacity = _memory.readU32(lengthPointer);
        allocationLength = capacity == 0 ? 1 : capacity;
        buffer = _requirePointer(_exports.allocateBytes(allocationLength));
        result = _exports.ghostty_key_encoder_encode(
          encoder.value,
          event.value,
          buffer,
          capacity,
          lengthPointer,
        );
      }
      checkResultCode(result, operation: 'ghostty_key_encoder_encode');
      return utf8.decode(
        _memory.readBytes(buffer, _memory.readU32(lengthPointer)),
      );
    } finally {
      if (buffer != 0) _exports.freeBytes(buffer, allocationLength);
      _exports.freeBytes(lengthPointer, 4);
    }
  }

  @override
  void keyEncoderFree(LibGhosttyHandle encoder) {
    _exports.ghostty_key_encoder_free(encoder.value);
  }

  @override
  LibGhosttyHandle keyEncoderNew() {
    final out = _requirePointer(_exports.allocateOpaque());
    try {
      final result = _exports.ghostty_key_encoder_new(0, out);
      checkRequiredCode(result, operation: 'ghostty_key_encoder_new');
      return .fromAddress(_exports.ghostty_wasm_take_opaque(out));
    } finally {
      _exports.freeOpaque(out);
    }
  }

  @override
  void keyEncoderSetBoolOpt(
    LibGhosttyHandle encoder,
    KeyEncoderOption option, {
    required bool value,
  }) {
    final pointer = _requirePointer(_exports.allocateBytes(1));
    try {
      _memory.writeU8(pointer, value ? 1 : 0);
      _exports.ghostty_key_encoder_setopt(encoder.value, option.value, pointer);
    } finally {
      _exports.freeBytes(pointer, 1);
    }
  }

  @override
  void keyEncoderSetKittyFlags(LibGhosttyHandle encoder, int flags) {
    final pointer = _requirePointer(_exports.allocateBytes(1));
    try {
      _memory.writeU8(pointer, flags);
      _exports.ghostty_key_encoder_setopt(
        encoder.value,
        KeyEncoderOption.kittyFlags.value,
        pointer,
      );
    } finally {
      _exports.freeBytes(pointer, 1);
    }
  }

  @override
  void keyEncoderSetOptFromTerminal(
    LibGhosttyHandle encoder,
    LibGhosttyHandle terminal,
  ) {
    _exports.ghostty_key_encoder_setopt_from_terminal(
      encoder.value,
      terminal.value,
    );
  }

  @override
  void keyEncoderSetOptionAsAlt(LibGhosttyHandle encoder, OptionAsAlt value) {
    final pointer = _requirePointer(_exports.allocateBytes(4));
    try {
      _memory.writeI32(pointer, value.value);
      _exports.ghostty_key_encoder_setopt(
        encoder.value,
        KeyEncoderOption.macosOptionAsAlt.value,
        pointer,
      );
    } finally {
      _exports.freeBytes(pointer, 4);
    }
  }

  @override
  void keyEventFree(LibGhosttyHandle event) {
    final previous = _utf8Pointers.remove(event.value);
    if (previous != null) {
      _exports.freeBytes(previous.$1, previous.$2);
    }
    _exports.ghostty_key_event_free(event.value);
  }

  @override
  KeyAction keyEventGetAction(LibGhosttyHandle event) {
    return .fromValue(_exports.ghostty_key_event_get_action(event.value));
  }

  @override
  bool keyEventGetComposing(LibGhosttyHandle event) {
    return _exports.ghostty_key_event_get_composing(event.value) != 0;
  }

  @override
  int keyEventGetConsumedMods(LibGhosttyHandle event) {
    return _exports.ghostty_key_event_get_consumed_mods(event.value);
  }

  @override
  Key keyEventGetKey(LibGhosttyHandle event) {
    return .fromValue(_exports.ghostty_key_event_get_key(event.value));
  }

  @override
  int keyEventGetMods(LibGhosttyHandle event) {
    return _exports.ghostty_key_event_get_mods(event.value);
  }

  @override
  int keyEventGetUnshiftedCodepoint(LibGhosttyHandle event) {
    return _exports.ghostty_key_event_get_unshifted_codepoint(event.value);
  }

  @override
  String? keyEventGetUtf8(LibGhosttyHandle event) {
    final lengthPointer = _requirePointer(_exports.allocateBytes(4));
    try {
      final pointer = _exports.ghostty_key_event_get_utf8(
        event.value,
        lengthPointer,
      );
      if (pointer == 0) return null;
      final length = _memory.readU32(lengthPointer);
      if (length == 0) return null;
      return utf8.decode(_memory.readBytes(pointer, length));
    } finally {
      _exports.freeBytes(lengthPointer, 4);
    }
  }

  @override
  LibGhosttyHandle keyEventNew() {
    final out = _requirePointer(_exports.allocateOpaque());
    try {
      final result = _exports.ghostty_key_event_new(0, out);
      checkRequiredCode(result, operation: 'ghostty_key_event_new');
      return .fromAddress(_exports.ghostty_wasm_take_opaque(out));
    } finally {
      _exports.freeOpaque(out);
    }
  }

  @override
  void keyEventSetAction(LibGhosttyHandle event, KeyAction action) {
    _exports.ghostty_key_event_set_action(event.value, action.value);
  }

  @override
  void keyEventSetComposing(LibGhosttyHandle event, {required bool composing}) {
    _exports.ghostty_key_event_set_composing(event.value, composing ? 1 : 0);
  }

  @override
  void keyEventSetConsumedMods(LibGhosttyHandle event, int mods) {
    _exports.ghostty_key_event_set_consumed_mods(event.value, mods);
  }

  @override
  void keyEventSetKey(LibGhosttyHandle event, Key key) {
    _exports.ghostty_key_event_set_key(event.value, key.value);
  }

  @override
  void keyEventSetMods(LibGhosttyHandle event, int mods) {
    _exports.ghostty_key_event_set_mods(event.value, mods);
  }

  @override
  void keyEventSetUnshiftedCodepoint(LibGhosttyHandle event, int codepoint) {
    _exports.ghostty_key_event_set_unshifted_codepoint(event.value, codepoint);
  }

  @override
  void keyEventSetUtf8(LibGhosttyHandle event, String? text) {
    final previous = _utf8Pointers[event.value];
    if (text == null || text.isEmpty) {
      _exports.ghostty_key_event_set_utf8(event.value, 0, 0);
      return;
    }

    final encoded = utf8.encode(text);
    final length = encoded.length;
    if (previous != null && previous.$2 >= length) {
      _memory.writeBytes(previous.$1, encoded);
      _exports.ghostty_key_event_set_utf8(event.value, previous.$1, length);
      return;
    }

    final capacity = _nextCapacity(length, previous?.$2 ?? 0);
    final pointer = _requirePointer(_exports.allocateBytes(capacity));
    try {
      _memory.writeBytes(pointer, encoded);
      _exports.ghostty_key_event_set_utf8(event.value, pointer, length);
    } catch (_) {
      _exports.freeBytes(pointer, capacity);
      rethrow;
    }
    if (previous != null) _exports.freeBytes(previous.$1, previous.$2);
    _utf8Pointers[event.value] = (pointer, capacity);
  }

  int _nextCapacity(int length, int previousCapacity) {
    var capacity = previousCapacity == 0 ? 64 : previousCapacity;
    while (capacity < length) {
      if (capacity > length ~/ 2) return length;
      capacity *= 2;
    }
    return capacity;
  }

  int _requirePointer(int pointer) {
    if (pointer == 0) throw const OutOfMemoryException();
    return pointer;
  }
}
