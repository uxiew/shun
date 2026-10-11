// R11 设备验证入口（TSC09 / SEC05 的目录凭据部分）：用 App 自己的目录代码，
// 经 adb reverse 连本机 tool/tailscale-fixture 的假 API，走一遍三条路径：
//   1. 粘贴短期 token 读一次（不应保存任何东西）；
//   2. OAuth client 读一次并要求持续刷新（只应把 client 存进独立的加密存储）；
//   3. tailnet=redirect-me，服务器回 302 指向另一端口（不应跟随）。
// 之后在设备上翻 App 私有目录和 logcat 搜特征串。用法见 tool/tailscale-fixture/README.md，结果见 plan/v3/evidence/R11.md。
//
// 特征串在运行时拼出来：整串直接写在源码里会被编进 kernel_blob.bin，扫描会误报（R09 撞过）。
// 它和正式 App 同一个包名，会覆盖设备上这个 App 的数据，只在测试设备/模拟器上跑。
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shun/application/tailscale_catalog_access.dart';
import 'package:shun/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:shun/infrastructure/tailscale/tailscale_api.dart';

String canary(String kind) => ['R11', kind, 'CANARY', '7d3e'].join('-');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fixture = Uri.parse('http://127.0.0.1:18480');
  final client = http.Client();
  const store = TailscaleCatalogSecretStore(FlutterSecureCatalogBackend());
  final access = TailscaleCatalogAccess(
    store,
    // 设备验证入口就是 fixture 的用途所在；它只接受本机回环地址，不会被当成可配置服务器。
    // ignore: invalid_use_of_visible_for_testing_member
    (credential) => TailscaleCatalogClient.fixture(client, fixture, credential),
  );
  final results = <String, String>{};

  try {
    final pasted = await access.readOnceWithToken(canary('PASTED'));
    results['pasted'] =
        'devices=${pasted.snapshot.devices.length} scope=${pasted.scopeStatus.name}';
  } on Object catch (e) {
    results['pasted'] = 'error ${e.runtimeType}';
  }

  try {
    final oauth = await access.readWithOAuthClient(
      catalogId: 'r11-seed',
      credential: OAuthClientCredential(
        clientId: canary('CLIENTID'),
        clientSecret: canary('CLIENTSECRET'),
      ),
      persist: true,
    );
    final back = await store.readOAuthClient('r11-seed');
    results['oauth'] = 'devices=${oauth.listing.snapshot.devices.length} '
        'scope=${oauth.listing.scopeStatus.name} persisted=${oauth.persisted} '
        'roundTrip=${back?.clientSecret == canary('CLIENTSECRET')}';
  } on Object catch (e) {
    results['oauth'] = 'error ${e.runtimeType}';
  }

  try {
    await access.readOnceWithToken(canary('PASTED'), tailnet: 'redirect-me');
    results['redirect'] = 'FOLLOWED?';
  } on TailscaleRedirectRefused {
    results['redirect'] = 'refused';
  } on Object catch (e) {
    results['redirect'] = 'error ${e.runtimeType}';
  }

  // 只打印结果摘要，不打印任何凭据。
  debugPrint('R11 seed: $results');
  runApp(MaterialApp(
    home: Scaffold(
      body: Center(child: Text('R11 seed\n$results')),
    ),
  ));
}
