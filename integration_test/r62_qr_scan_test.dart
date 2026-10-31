// 真扫码页（zxing-android-embedded）的两条退出路。模拟器相机读不到二维码，真扫码是 SYN04，要手机。
//
// 测试打 `R62 ACTION=<动作>`，脚本（或人）照做：
//   deny：在系统权限框点拒绝；
//   back：先 `pm grant` 相机，扫码页开着时按返回。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/infrastructure/qr_scanner.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('拒绝权限报 QrScanDenied，按返回得到 null', (tester) async {
    const scanner = PlatformQrScanner();
    debugPrint('R62 ACTION=deny');
    Object? denied;
    await scanner
        .scan(prompt: '扫对方手机上的二维码')
        .then<void>((_) {}, onError: (Object error) => denied = error)
        .timeout(const Duration(seconds: 60));
    debugPrint('R62 denied=${denied.runtimeType}');
    expect(denied, isA<QrScanDenied>());

    debugPrint('R62 ACTION=back');
    final text = await scanner
        .scan(prompt: '扫对方手机上的二维码')
        .timeout(const Duration(seconds: 60));
    debugPrint('R62 back=$text');
    expect(text, isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
