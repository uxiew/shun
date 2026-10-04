import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../../ffi/libghostty_wasm.g.dart';

class Mem {
  final GhosttyExports _exports;

  Mem(this._exports);

  ByteData get view => _buffer.asByteData();

  ByteBuffer get _buffer {
    return (_exports.memory['buffer']! as JSArrayBuffer).toDart;
  }

  Uint8List readBytes(int addr, int len) => _buffer.asUint8List(addr, len);

  String readCString(int addr) {
    if (addr == 0) return '';
    final bytes = <int>[];
    var offset = addr;
    while (true) {
      final byte = readU8(offset);
      if (byte == 0) break;
      bytes.add(byte);
      offset++;
    }
    return utf8.decode(bytes);
  }

  double readF32(int addr) => view.getFloat32(addr, .little);

  int readI32(int addr) => view.getInt32(addr, .little);

  int readPtr(int addr) => readU32(addr);

  int readU16(int addr) => view.getUint16(addr, .little);

  int readU32(int addr) => view.getUint32(addr, .little);

  int readU64(int addr) {
    final lo = view.getUint32(addr, .little);
    final hi = view.getUint32(addr + 4, .little);
    // Uses multiplication by 2^32 instead of << 32 because JS
    // bitwise operators truncate to 32 bits.
    return lo + hi * 0x100000000;
  }

  int readU8(int addr) => view.getUint8(addr);

  void writeBytes(int addr, List<int> bytes) {
    _buffer.asUint8List(addr, bytes.length).setAll(0, bytes);
  }

  void writeF32(int addr, double val) => view.setFloat32(addr, val, .little);

  void writeF64(int addr, double val) => view.setFloat64(addr, val, .little);

  void writeI32(int addr, int val) => view.setInt32(addr, val, .little);

  void writeU16(int addr, int val) => view.setUint16(addr, val, .little);

  void writeU32(int addr, int val) => view.setUint32(addr, val, .little);

  void writeU64(int addr, int val) {
    view.setUint32(addr, val & 0xffffffff, .little);
    view.setUint32(addr + 4, val ~/ 0x100000000, .little);
  }

  void writeU8(int addr, int val) => view.setUint8(addr, val);
}
