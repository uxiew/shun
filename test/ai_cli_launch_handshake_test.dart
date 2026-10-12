import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli_launch.dart';
import 'package:shun/infrastructure/ssh/ai_cli_launch_handshake.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  const marker = AiCliLaunchSpec.readyMarker;
  test('every packet split preserves binary/UTF-8 output and confirms once',
      () async {
    final prefix = bytes('登录中文\r\n');
    final suffix = Uint8List.fromList([0xff, 0, ...bytes('工具🙂$marker')]);
    final wire = Uint8List.fromList([...prefix, ...bytes(marker), ...suffix]);
    for (var split = 0; split <= wire.length; split++) {
      var confirmations = 0;
      final output = <int>[];
      final handshake = AiCliLaunchHandshake(
          onConfirmed: () => confirmations++,
          onOutput: (chunk) {
            expect(confirmations, 1, reason: 'enable input before TUI replies');
            output.addAll(chunk);
          });
      handshake.add(Uint8List.sublistView(wire, 0, split));
      handshake.add(Uint8List.sublistView(wire, split));
      await handshake.ready;
      handshake.finish(126);
      expect(confirmations, 1);
      expect(output, [...prefix, ...suffix]);
    }
  });
  test('single-byte chunks remove only the first confirmation marker',
      () async {
    final output = <int>[];
    final handshake =
        AiCliLaunchHandshake(onConfirmed: () {}, onOutput: output.addAll);
    for (final byte in bytes('banner${marker}ok')) {
      handshake.add(Uint8List.fromList([byte]));
    }
    await handshake.ready;
    expect(output, bytes('bannerok'));
  });
  for (final code in [125, 126, 0, null]) {
    test('exit $code before confirmation rejects late success', () async {
      var confirmations = 0;
      final output = <int>[];
      final handshake = AiCliLaunchHandshake(
          onConfirmed: () => confirmations++, onOutput: output.addAll);
      final failed = expectLater(
          handshake.ready,
          throwsA(code == 125 || code == 126
              ? isA<AiCliLaunchRejectedException>()
                  .having((e) => e.exitCode, 'exitCode', code)
              : isA<AiCliLaunchUnknownException>()));
      handshake.add(bytes('partial'));
      handshake.finish(code);
      handshake.add(bytes('${marker}late output'));
      handshake.fail();
      await failed;
      expect(confirmations, 0);
      expect(output, isEmpty);
    });
  }
  for (final tail in ['', marker]) {
    test('oversized prelude rejects marker tail=${tail.isNotEmpty}', () async {
      var confirmed = false;
      final output = <int>[];
      final handshake = AiCliLaunchHandshake(
          onConfirmed: () => confirmed = true, onOutput: output.addAll);
      final failed = expectLater(
          handshake.ready, throwsA(isA<AiCliLaunchUnknownException>()));
      handshake.add(bytes('${'x' * 8193}$tail'));
      handshake.add(bytes('${marker}late'));
      await failed;
      expect(confirmed, isFalse);
      expect(output, isEmpty);
    });
  }
  test('bounded prelude permits large CLI output in the same packet', () async {
    final output = <int>[];
    final handshake =
        AiCliLaunchHandshake(onConfirmed: () {}, onOutput: output.addAll);
    final prefix = 'x' * (AiCliLaunchHandshake.maxPreludeBytes - marker.length);
    final suffix = 'y' * 65536;
    handshake.add(bytes('$prefix$marker$suffix'));
    await handshake.ready;
    expect(output, bytes('$prefix$suffix'));
  });
  test('transport failure or cancellation drops buffered and late bytes',
      () async {
    final output = <int>[];
    final handshake = AiCliLaunchHandshake(
        onConfirmed: () => fail('must not confirm'), onOutput: output.addAll);
    final failed = expectLater(
        handshake.ready, throwsA(isA<AiCliLaunchUnknownException>()));
    handshake.add(bytes(marker.substring(0, 7)));
    handshake.fail();
    handshake.add(bytes('${marker.substring(7)}late'));
    handshake.finish(125);
    await failed;
    expect(output, isEmpty);
  });
}
