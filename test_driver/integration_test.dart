// flutter drive 的驱动端。只给要装「改过的 APK」的设备测试用（tool/r20-engine-failure.sh，--use-application-binary）；
// 平时的设备测试用 flutter test integration_test/… 就行，不经过这里。
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
