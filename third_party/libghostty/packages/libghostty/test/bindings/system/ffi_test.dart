@Tags(['ffi'])
library;

import 'dart:typed_data';

import 'package:libghostty/libghostty.dart' show DecodedImage;
import 'package:libghostty/src/bindings/system/ffi.dart';
import 'package:test/test.dart';

void main() {
  group('FfiSystemBindings', () {
    test('preserves process-global logger and PNG decoder ownership', () {
      final system = FfiSystemBindings();
      addTearDown(() {
        system.sysClearLogCallback();
        system.sysClearPngDecoder();
      });

      system.sysSetLogCallback((_, _, _) {});
      expect(system.sysSetLogToStderr, returnsNormally);

      system.sysSetPngDecoder(
        (_) => DecodedImage(
          width: 1,
          height: 1,
          rgba: Uint8List.fromList([0, 0, 0, 255]),
        ),
      );
      system.sysSetLogCallback((_, _, _) {});

      expect(system.sysClearLogCallback, returnsNormally);
      expect(system.sysClearPngDecoder, returnsNormally);
    });
  });
}
