@Tags(['ffi'])
library;

import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('LibGhosttyBuildInfo', () {
    group('instance', () {
      test('returns consistent singleton', () {
        final a = LibGhosttyBuildInfo.instance;
        final b = LibGhosttyBuildInfo.instance;
        expect(identical(a, b), isTrue);
      });
    });

    group('fields', () {
      test('return typed values', () {
        final info = LibGhosttyBuildInfo.instance;
        expect(info.simd, isA<bool>());
        expect(info.kittyGraphics, isA<bool>());
        expect(info.tmuxControlMode, isA<bool>());
        expect(info.optimizeMode, isA<OptimizeMode>());
        expect(info.versionString, isNotEmpty);
        expect(info.versionMajor, greaterThanOrEqualTo(0));
        expect(info.versionMinor, greaterThanOrEqualTo(0));
        expect(info.versionPatch, greaterThanOrEqualTo(0));
        expect(info.versionBuild, isA<String>());
      });
    });
  });
}
