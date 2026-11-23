import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shun/app.dart';
import 'package:shun/application/fork_features.dart';
import 'package:shun/infrastructure/http_client_provider.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/home_navigation.dart';

// BAS02：未经用户开启的 AI / 同步 / 更新检查，冷启动、切到设置页、后台恢复时网络请求必须为零。
void main() {
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    SharedPreferences.setMockInitialValues({
      // 模拟从上游数据带过来的"自动同步已开"残留：关掉 cloudSync 后它也不能生效。
      'shun_settings_v1': '{"autoSyncEnabled":true}',
    });
    // 必须 mock，否则设置页 await PackageInfo 时抛 MissingPluginException，
    // 更新检查根本走不到发请求那一步，测试会"假通过"。
    PackageInfo.setMockInitialValues(
      appName: 'shun',
      packageName: 'top.xdwa.shun',
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
    // 设置页是懒加载 ListView：默认 800x600 的测试窗口里，云端备份/AI 那几项根本不会被构建，
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
      child: const ShunApp(),
    ));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(homeNavigationEntry(4));
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

  Future<void> openCloudBackup(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('settings-cloud-backup')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('默认开关下冷启动、打开设置、后台恢复都不发网络请求', (tester) async {
    final requests = await launchAndVisitSettings(tester);
    expect(requests.map((r) => r.url.toString()), isEmpty);
    expect(find.text('管理多个 AI 服务商'), findsNothing);
    // 云端备份入口在，但没填配置：就算残留着「自动备份已开」，打开这页也没有请求（SYN03）。GitHub 那一项不出现。
    await openCloudBackup(tester);
    expect(find.byKey(const ValueKey('cloud-auto-sync')), findsOneWidget);
    expect(find.text('GitHub'), findsNothing);
    expect(requests.map((r) => r.url.toString()), isEmpty);
  });

  testWidgets('数据区：加密备份入口弹口令框，取消后什么都不写', (tester) async {
    final requests = await launchAndVisitSettings(tester);
    await tester.tap(find.byKey(const ValueKey('export-encrypted-backup')));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('backup-passphrase')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('backup-passphrase-again')), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('backup-passphrase')), findsNothing);
    expect(requests, isEmpty);
  });

  testWidgets('数据区：明文 JSON 的入口没了；云端备份那一行跟着配置变', (tester) async {
    await launchAndVisitSettings(tester);
    expect(find.text('备份到文件'), findsOneWidget);
    expect(find.text('从文件恢复'), findsOneWidget);
    expect(find.textContaining('JSON'), findsNothing);
    expect(find.text('未设置'), findsOneWidget);

    await openCloudBackup(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'WebDAV 地址'),
      'https://dav.example.com/x',
    );
    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('未设置'), findsNothing);
    expect(find.text('WebDAV · 自动'), findsOneWidget);
  });

  testWidgets('从文件恢复：明文 JSON 不收，不弹确认框，本机不动', (tester) async {
    await launchAndVisitSettings(tester);
    final repository = await VaultRepository.open();
    final previous = _swapPicker(_FakePicker(FilePickerResult([
      PlatformFile(
        name: 'shun-export.json',
        size: 60,
        bytes: utf8.encode(
          '{"hosts":[{"id":"h","label":"h"}],"keys":[],"snippets":[]}',
        ),
      ),
    ])));
    addTearDown(() => _swapPicker(previous));
    ScaffoldMessenger.of(tester.element(find.text('从文件恢复'))).clearSnackBars();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('restore-from-file')));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('恢复失败：不是 shun 的加密备份，或者文件已损坏'), findsOneWidget);
    expect(find.text('恢复备份'), findsNothing);
    expect(find.byKey(const ValueKey('backup-passphrase')), findsNothing);
    expect((await repository.loadVault()).hosts, isEmpty);
  });

  Future<List<http.Request>> tapSyncWithPassword(
    WidgetTester tester,
    String password,
  ) async {
    final requests = await launchAndVisitSettings(tester);
    await openCloudBackup(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '主密码'),
      password,
    );
    // 夹具的安全存储是假的，启动时会弹一条「远控存储未就绪」。它不走，后面的提示只能排队，测试看不到。
    ScaffoldMessenger.of(tester.element(find.text('立即备份'))).clearSnackBars();
    await tester.pump();
    await tester.tap(find.text('立即备份'));
    await tester.pump(const Duration(seconds: 1));
    return requests;
  }

  testWidgets('主密码 11 位：拦住，没有请求', (tester) async {
    final requests = await tapSyncWithPassword(tester, 'a' * 11);
    expect(find.text('主密码至少 12 位'), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('主密码 12 位：放行，但没填配置仍然没有请求', (tester) async {
    final requests = await tapSyncWithPassword(tester, 'a' * 12);
    expect(find.text('主密码至少 12 位'), findsNothing);
    // 有别的提示才说明点击真的走下去了，不然按钮没反应这条也会过。
    expect(find.byType(SnackBar), findsOneWidget);
    expect(requests, isEmpty);
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
    expect(find.text('管理多个 AI 服务商'), findsOneWidget);
    await openCloudBackup(tester);
    expect(find.byKey(const ValueKey('cloud-auto-sync')), findsOneWidget);
  });
}

FilePicker? _swapPicker(FilePicker? next) {
  FilePicker? previous;
  try {
    previous = FilePicker.platform;
  } catch (_) {
    // 桌面测试里没注册过平台实现，取不到旧的。
  }
  if (next != null) FilePicker.platform = next;
  return previous;
}

class _FakePicker extends FilePicker {
  _FakePicker(this.result);

  final FilePickerResult result;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      result;
}
