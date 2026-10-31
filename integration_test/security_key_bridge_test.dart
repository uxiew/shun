import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/domain/security_key.dart';
import 'package:shun/infrastructure/ssh/security_key_channel.dart';
import 'package:shun/main.dart' as app;

/// 模拟器上没有钥匙，这里只验通道：请求能传到 Kotlin、开始等钥匙不崩、取消能收尾、收尾后还能再来一次。
/// 真钥匙是 SKY02–SKY04，这里过了不算那几条过。
///
/// flutter test integration_test/security_key_bridge_test.dart -d emulator-5580
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<SecurityKeyException> failureOf(Future<Object?> run) async {
    try {
      await run;
    } on SecurityKeyException catch (error) {
      return error;
    }
    fail('没有钥匙不该成功');
  }

  testWidgets('等钥匙、取消、再来一次；一次只做一件事', (tester) async {
    app.main();
    await tester.pump(const Duration(seconds: 3));
    final channel = SecurityKeyChannel();

    final available = await channel.availability();
    debugPrint(
      'SKB availability nfc=${available.nfc} '
      'nfcEnabled=${available.nfcEnabled} usb=${available.usb}',
    );

    Future<SecurityKeyAssertion> sign() => channel.sign(
          application: 'ssh:',
          clientDataHash: Uint8List(32),
          keyHandle: Uint8List(16),
          userPresence: true,
        );

    for (var round = 0; round < 3; round++) {
      final pending = failureOf(sign());
      await tester.pump(const Duration(milliseconds: 800));
      final started = Stopwatch()..start();
      await channel.cancel();
      final error = await pending;
      expect(error.failure, SecurityKeyFailure.cancelled, reason: '第 $round 轮');
      debugPrint('SKB round=$round cancelMs=${started.elapsedMilliseconds}');
      expect(started.elapsed, lessThan(const Duration(seconds: 5)));
    }

    final first = failureOf(sign());
    await tester.pump(const Duration(milliseconds: 500));
    final busy = await failureOf(
      channel.create(application: 'ssh:', resident: false, requirePin: false),
    );
    expect(busy.failure, SecurityKeyFailure.transport, reason: '同时两个请求要拒绝后一个');
    await channel.cancel();
    expect((await first).failure, SecurityKeyFailure.cancelled);

    final badArguments = await () async {
      try {
        await const MethodChannel('top.xdwa.shun/security_key')
            .invokeMethod<void>('sign', {'rpId': 'ssh:'});
      } on PlatformException catch (error) {
        return error.code;
      }
      return null;
    }();
    expect(badArguments, 'transport', reason: '参数缺了报错，不崩');

    // 没人处理的一轮也要能收尾：对应弹框超时后调的 cancel。
    final listing = failureOf(channel.listResident(pin: '1234'));
    await tester.pump(const Duration(milliseconds: 500));
    await channel.cancel();
    expect((await listing).failure, SecurityKeyFailure.cancelled);
  });
}
