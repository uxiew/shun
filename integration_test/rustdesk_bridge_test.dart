// X07 设备验证：在模拟器/真机上直接调真实的 RustDesk 平台桥（RustDeskBridge.kt），绕过 Dart 这一层的校验，
// 看平台层自己挡不挡得住：带密码的、改配置的链接，证书对不上的包，没装的包。
//
// 这不是 CI 测试。先装两个测试 App（见 plugins/README.md 的「X07 假 RustDesk」）：
//   adb install -r plugins/out/fakerd.apk plugins/out/fakerd-custom.apk
//   flutter test integration_test/rustdesk_bridge_test.dart -d <设备>
// 跑完看 `adb logcat -d -s ShunFakeRd`：应当只有最后那一次合规的请求，而且只有指定的那个包收到。
// 会重装 App、清空数据。输出以 "X07 " 开头的行作为证据。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/infrastructure/plugins/rustdesk_external.dart';

const custom = 'example.shun.fixture.fakerustdesk';

void report(String key, Object? value) => debugPrint('X07 $key=$value');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('平台桥：探测、拒发不合规的链接和对不上的包，合规的只发给指定的包', (tester) async {
    final platform = AndroidRustDeskPlatform();

    final probe = await platform.probe();
    final byPackage = {for (final c in probe.handlers) c.package: c};
    report('handlers', [
      for (final c in probe.handlers)
        '${c.package} ${c.versionName} ${c.signers.map((s) => s.substring(0, 16)).join('+')}',
    ]);
    report('officialInstalled', probe.officialInstalled?.versionName);
    expect(byPackage.keys,
        containsAll([RustDeskProtocol.officialPackage, custom]));
    final official = byPackage[RustDeskProtocol.officialPackage]!;
    final other = byPackage[custom]!;
    expect(official.signers, hasLength(1));
    expect(other.signers, hasLength(1));
    // 本 App 自己不算 rustdesk:// 的处理者。
    expect(byPackage.keys, isNot(contains('top.xdwa.shun')));

    Future<String?> refused(String uri,
        {String? package, String? signer}) async {
      try {
        await platform.launch(
          uri,
          package: package ?? official.package,
          signer: signer ?? official.signers.single,
        );
        return null;
      } on RustDeskLaunchFailed catch (e) {
        return e.message;
      }
    }

    // 1. 链接白名单：Dart 层即使被绕过，这些也出不了进程。
    for (final uri in [
      'rustdesk://connect/123456789?password=hunter2',
      'rustdesk://connect/123456789?key=abc',
      'rustdesk://connect/123456789?relay',
      'rustdesk://connect/123456789/r',
      'rustdesk://connect/123456789@evil.example',
      'rustdesk://password/hunter2',
      'rustdesk://config/eyJob3N0IjoiZXZpbCJ9',
      'rustdesk://file-transfer/123456789',
      'rustdesk://terminal-admin/123456789',
      'rustdesk://port-forward/123456789',
      'rustdesk://123456789',
      'rustdesk://connection/new/123456789',
      'rustdesk://connect/',
      'rustdesk://connect/123456789\n',
      'RUSTDESK://connect/123456789',
      'https://evil.example/',
      'intent://connect/1#Intent;scheme=rustdesk;end',
      'uuremote://external/device/control?anonymous_device_id=x',
      '',
    ]) {
      final reason = await refused(uri);
      report('refused', '${uri.replaceAll('\n', r'\n')} -> $reason');
      expect(reason, '只发 RustDesk 的连接链接', reason: uri);
    }

    // 2. 发给谁：证书对不上、包没装、没给包名、给的是本 App 自己，都不发。
    const good = 'rustdesk://connect/987654321';
    final wrongSigner = await refused(good, signer: other.signers.single);
    report('wrongSigner', wrongSigner);
    expect(wrongSigner, contains('签名证书和核对过的不一致'));
    final emptySigner = await refused(good, signer: '');
    report('emptySigner', emptySigner);
    expect(emptySigner, contains('签名证书和核对过的不一致'));
    final missing = await refused(good, package: 'com.example.notinstalled');
    report('missingPackage', missing);
    expect(missing, contains('已经不在手机上了'));
    final noPackage = await refused(good, package: '');
    report('noPackage', noPackage);
    expect(noPackage, contains('没有指定'));
    final self = await refused(good, package: 'top.xdwa.shun');
    report('selfPackage', self);
    expect(self, contains('没有指定'));

    // 3. 合规的请求：只发给指定的那个包。两个包都声明了 rustdesk://，指定的是「别的包名」那个，
    //    官方包名的那个不应收到。放在最后：发出后本 App 到了后台，系统不再允许它启动别的界面。
    final sent = await refused(
      good,
      package: other.package,
      signer: other.signers.single,
    );
    report('sent', sent ?? 'ok -> ${other.package}');
    expect(sent, isNull);
  });
}
