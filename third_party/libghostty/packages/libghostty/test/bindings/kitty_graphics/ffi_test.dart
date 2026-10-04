@Tags(['ffi'])
library;

import 'package:libghostty/src/bindings/kitty_graphics/ffi.dart';
import 'package:libghostty/src/types/exceptions.dart';
import 'package:test/test.dart';

void main() {
  group('FfiKittyGraphicsBindings', () {
    late FfiKittyGraphicsBindings bindings;

    setUp(() {
      bindings = FfiKittyGraphicsBindings();
    });

    test('returns a null image handle for an invalid graphics handle', () {
      final image = bindings.kittyGraphicsImage(const .fromAddress(0), 1);

      expect(image.value, 0);
    });

    test('rejects an invalid graphics handle before native access', () {
      expect(
        () => bindings.kittyGraphicsGetGeneration(const .fromAddress(0)),
        throwsA(isA<InvalidValueException>()),
      );
    });
  });
}
