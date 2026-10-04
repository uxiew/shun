@Tags(['ffi'])
library;

import 'package:code_assets/code_assets.dart';
import 'package:libghostty/src/hook/zig_target.dart';
import 'package:test/test.dart';

void main() {
  group('zigTarget', () {
    group('iOS', () {
      test('returns supported targets', () {
        expect(
          zigTarget(OS.iOS, Architecture.arm64, iOSSdk: IOSSdk.iPhoneOS),
          'aarch64-ios',
        );
        expect(zigTarget(OS.iOS, Architecture.arm64), 'aarch64-ios');
        expect(
          zigTarget(OS.iOS, Architecture.arm64, iOSSdk: IOSSdk.iPhoneSimulator),
          'aarch64-ios-simulator',
        );
        expect(
          zigTarget(OS.iOS, Architecture.x64, iOSSdk: IOSSdk.iPhoneSimulator),
          'x86_64-ios-simulator',
        );
      });
    });

    group('Android', () {
      test('returns supported targets', () {
        expect(
          zigTarget(OS.android, Architecture.arm64),
          'aarch64-linux-android',
        );
        expect(zigTarget(OS.android, Architecture.x64), 'x86_64-linux-android');
        expect(
          zigTarget(OS.android, Architecture.arm),
          'arm-linux-androideabi',
        );
      });

      test('throws for unsupported Android architecture', () {
        expect(
          () => zigTarget(OS.android, Architecture.ia32),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('desktop', () {
      test('returns supported targets', () {
        expect(zigTarget(OS.macOS, Architecture.arm), 'arm-macos');
        expect(zigTarget(OS.linux, Architecture.arm), 'arm-linux-gnu');
        expect(zigTarget(OS.windows, Architecture.arm), 'arm-windows');
      });
    });

    group('host target', () {
      test('returns target for current OS and architecture', () {
        final target = zigTarget(OS.current, Architecture.current);
        expect(target, isNotNull);
      });
    });

    group('unsupported', () {
      test('throws for unsupported inputs', () {
        expect(
          () => zigTarget(OS.fuchsia, Architecture.arm64),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => zigTarget(OS.linux, Architecture.riscv64),
          throwsA(isA<ArgumentError>()),
        );
      });
    });
  });
}
