import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/infrastructure/http_client_provider.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/settings_screen.dart';
import 'package:shun/presentation/screens/tailscale_settings_screen.dart';
import 'package:shun/presentation/theme.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/proxy_profile_editor.dart';

/// 把几个表单页画成 PNG，改界面后用眼睛看，不用等编包上模拟器。平时跳过。
///
/// `SHUN_UI_GALLERY=<绝对路径目录> flutter test --no-pub test/ui_gallery_test.dart`
///
/// 测试环境默认字体每个字都是方块，所以从 macOS 系统目录借字体；别的系统上找不到字体就跳过。
const _fontPath = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
const _shot = ValueKey('ui-gallery-shot');

void main() {
  final dir = Platform.environment['SHUN_UI_GALLERY'];
  final skip = dir == null
      ? '设了 SHUN_UI_GALLERY 才跑'
      : (File(_fontPath).existsSync() ? null : '没有 $_fontPath');

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'shun',
      packageName: 'top.xdwa.shun',
      version: '1.4.7',
      buildNumber: '30',
      buildSignature: '',
    );
  });

  Future<void> loadFonts(WidgetTester tester) => tester.runAsync(() async {
        final text = FontLoader('Gallery')
          ..addFont(File(_fontPath)
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)));
        await text.load();
        final root = Platform.environment['FLUTTER_ROOT'] ??
            '/opt/homebrew/share/flutter';
        final icons = FontLoader('MaterialIcons')
          ..addFont(File(
                  '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)));
        await icons.load();
      });

  ThemeData theme(Brightness brightness, String id) {
    final base = ShunTheme.build(brightness, id);
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'Gallery'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Gallery'),
    );
  }

  Future<void> pumpPage(
    WidgetTester tester,
    Widget home, {
    double height = 1100,
    Brightness brightness = Brightness.dark,
    String id = 'midnight',
  }) async {
    await loadFonts(tester);
    tester.view.physicalSize = Size(412 * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final repository = await VaultRepository.open();
    await tester.pumpWidget(RepaintBoundary(
      key: _shot,
      child: ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repository),
          httpClientProvider.overrideWithValue(MockClient(
              (_) async => http.Response('{"tag_name":"v1.4.7"}', 200))),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(brightness, id),
          home: home,
        ),
      ),
    ));
    await settle(tester);
  }

  Future<void> save(WidgetTester tester, String name) async {
    await settle(tester);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_shot),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('$dir/$name.png').writeAsBytes(data!.buffer.asUint8List());
    });
  }

  testWidgets('代理编辑页', skip: skip != null, (tester) async {
    await pumpPage(tester, const ProxyProfileEditor());
    await save(tester, 'proxy-editor');
  });

  testWidgets('新建连接', skip: skip != null, (tester) async {
    await pumpPage(tester, const HostEditor(), height: 1500);
    await save(tester, 'host-editor');
  });

  testWidgets('Tailscale 设置', skip: skip != null, (tester) async {
    await pumpPage(tester, const TailscaleSettingsScreen(), height: 1500);
    await tester.tap(find.byKey(const ValueKey('ts-settings-advanced')));
    await save(tester, 'tailscale-settings');
  });

  testWidgets('设置页', skip: skip != null, (tester) async {
    await pumpPage(tester, const SettingsScreen(), height: 4200);
    await save(tester, 'settings');
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
