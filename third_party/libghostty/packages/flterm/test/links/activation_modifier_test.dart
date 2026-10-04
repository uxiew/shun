import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ActivationModifier', () {
    test('exposes concise activation policies', () {
      expect(ActivationModifier.values, [
        ActivationModifier.primary,
        ActivationModifier.none,
        ActivationModifier.alt,
        ActivationModifier.control,
        ActivationModifier.meta,
        ActivationModifier.shift,
      ]);
    });
  });
}
