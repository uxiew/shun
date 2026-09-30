import 'package:netcatty_mobile/application/external_remote.dart';
import 'package:netcatty_mobile/infrastructure/plugins/rustdesk_external.dart';

// X07 测试共用：假平台（记下每次发出的链接、包名、证书）和内存存储。

const githubCert =
    'e92d44ba9b65003c7340683b0a9234f617c1b23a1dd90e89f7d04170b72bfc86';
const fdroidCert =
    '85366b10ecadff33e10c53250444a125203908285363c27fc62a561f9660fa48';

RustDeskClient official({
  String version = '1.4.9',
  Set<String> signers = const {githubCert},
}) =>
    RustDeskClient(
      package: RustDeskProtocol.officialPackage,
      versionName: version,
      versionCode: 2067,
      signers: signers,
    );

RustDeskClient custom({
  String package = 'com.example.myrustdesk',
  String version = '1.4.9',
  Set<String> signers = const {'cert-mine'},
}) =>
    RustDeskClient(package: package, versionName: version, signers: signers);

class FakeRustDeskPlatform implements RustDeskPlatform {
  RustDeskProbe probeResult = RustDeskProbe(
    platformSupported: true,
    handlers: [official()],
    officialInstalled: official(),
  );

  /// 每次发出的（链接、包名、证书）。
  final launched = <(String, String, String)>[];
  String? failLaunch;
  var probes = 0;

  @override
  Future<RustDeskProbe> probe() async {
    probes++;
    return probeResult;
  }

  @override
  Future<void> launch(
    String uri, {
    required String package,
    required String signer,
  }) async {
    if (failLaunch != null) throw RustDeskLaunchFailed(failLaunch!);
    launched.add((uri, package, signer));
  }
}

class MemoryRustDeskBackend implements ProviderSecretBackend {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
