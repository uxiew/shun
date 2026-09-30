// R13 设备验证入口：跑正式 App 的全部界面和代码，只把 Tailscale 目录 API 换成本机假服务器
// （http://127.0.0.1:18480，经 adb reverse 进设备）。其余——保险库、SSH、编辑器、导入——都和正式版一样。
//
// 和正式 App 同一个包名，装上会覆盖设备上这个 App 的数据，只在模拟器/测试设备上用。
// 用法见同目录 README.md 的「R13 目录页」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:netcatty_mobile/app.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_access.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/tailscale_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repository = await VaultRepository.open();
  final client = http.Client();
  runApp(ProviderScope(
    overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      tailscaleCatalogAccessProvider.overrideWithValue(TailscaleCatalogAccess(
        const TailscaleCatalogSecretStore(FlutterSecureCatalogBackend()),
        // fixture 入口只接受本机回环地址，不会被当成可配置的服务器。
        // ignore: invalid_use_of_visible_for_testing_member
        (credential) => TailscaleCatalogClient.fixture(
          client,
          Uri.parse('http://127.0.0.1:18480'),
          credential,
        ),
      )),
    ],
    child: const NetcattyApp(),
  ));
}
