// flutter drive 驱动端：R20 改包测试、R40 两阶段复用 APK（--use-application-binary）。
// 平时的设备测试用 flutter test integration_test/… 就行，不经过这里。
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
