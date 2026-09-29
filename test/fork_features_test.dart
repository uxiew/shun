import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/app.dart';
import 'package:netcatty_mobile/application/fork_features.dart';
import 'package:netcatty_mobile/infrastructure/http_client_provider.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// BAS02：未经用户开启的 AI / 同步 / 更新检查，冷启动、切到设置页、后台恢复时网络请求必须为零。
void main() {
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    SharedPreferences.setMockInitialValues({
      // 模拟从上游数据带过来的"自动同步已开"残留：关掉 cloudSync 后它也不能生效。
      'netcatty_mobile_settings_v1': '{"autoSyncEnabled":true}',
    });
    // 必须 mock，否则设置页 await PackageInfo 时抛 MissingPluginException，
    // 更新检查根本走不到发请求那一步，测试会"假通过"。
    PackageInfo.setMockInitialValues(
      appName: 'xwshun',
      packageName: 'top.xdwa.xwshun',
      version: '1.4.7',
      buildNumber: '26',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  Future<List<http.Request>> launchAndVisitSettings(
    WidgetTester tester, {
    ForkFeatures? features,
  }) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      // 返回合法 release：失败响应会让上游那个没人监听的更新检查 Future
      // 变成未处理异常（结果卡片在 ListView 底部懒加载，未滚到时没有 FutureBuilder 订阅）。
      return http.Response('{"tag_name":"v1.4.7"}', 200);
    });
    final repository = await VaultRepository.open();
    // 设置页是懒加载 ListView：默认 800x600 的测试窗口里，云同步/AI 那几项根本不会被构建，
    // "找不到"就不能说明被隐藏了。拉高窗口让整页一次构建出来，UI 断言才有意义。
    tester.view.physicalSize = const Size(800, 20000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        httpClientProvider.overrideWithValue(client),
        if (features != null) forkFeaturesProvider.overrideWithValue(features),
      ],
      child: const NetcattyApp(),
    ));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump(const Duration(seconds: 1));
    // Flutter 断言生命周期只能相邻切换，跳步会直接抛 "Invalid state transition"。
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(seconds: 1));
    return requests;
  }

  testWidgets('默认开关下冷启动、打开设置、后台恢复都不发网络请求', (tester) async {
    final requests = await launchAndVisitSettings(tester);
    expect(requests.map((r) => r.url.toString()), isEmpty);
    expect(find.byKey(const ValueKey('cloud-auto-sync')), findsNothing);
    expect(find.text('管理多个 AI 服务商'), findsNothing);
  });

  testWidgets('对照：开关全开时能录到请求、能找到入口，证明上一条不是夹具失灵才通过', (tester) async {
    final requests = await launchAndVisitSettings(
      tester,
      features:
          const ForkFeatures(ai: true, cloudSync: true, updateCheck: true),
    );
    expect(
      requests.map((r) => r.url.host),
      contains('api.github.com'),
    );
    expect(find.byKey(const ValueKey('cloud-auto-sync')), findsOneWidget);
    expect(find.text('管理多个 AI 服务商'), findsOneWidget);
  });
}
