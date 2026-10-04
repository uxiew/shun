import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceAttributesSecondary', () {
    DeviceAttributesSecondary create({int firmwareVersion = 42}) =>
        DeviceAttributesSecondary(firmwareVersion: firmwareVersion);

    group('equality', () {
      test('compares equal values structurally', () {
        final first = create();
        final second = create();

        expect(first, second);
      });

      test('produces equal hashes for equal values', () {
        final first = create();
        final second = create();

        expect(first.hashCode, second.hashCode);
      });

      test('distinguishes changed values', () {
        final first = create();
        final second = create(firmwareVersion: 43);

        expect(first, isNot(second));
      });
    });
  });

  group('DeviceAttributesTertiary', () {
    DeviceAttributesTertiary create({int unitId = 42}) =>
        DeviceAttributesTertiary(unitId: unitId);

    group('equality', () {
      test('compares equal values structurally', () {
        final first = create();
        final second = create();

        expect(first, second);
      });

      test('produces equal hashes for equal values', () {
        final first = create();
        final second = create();

        expect(first.hashCode, second.hashCode);
      });

      test('distinguishes changed values', () {
        final first = create();
        final second = create(unitId: 43);

        expect(first, isNot(second));
      });
    });
  });
}
