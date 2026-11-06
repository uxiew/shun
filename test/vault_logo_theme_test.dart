import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/app_lock.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/infrastructure/device_auth.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/vault_screen.dart';
import 'package:shun/presentation/ui/material_compat.dart';
import 'package:shun/presentation/ui/prism_theme.dart';
import 'package:shun/presentation/ui/shun_ui_host.dart';

// 首页的乌鸦 logo 按当前主题的亮暗换图。R83 起在生产宿主里用真实预设切浅/深/系统，
// 同时看 Material 与 Prism 两种表示亮暗一致、页面状态不重建。
void main() {
  testWidgets('vault logo loads and follows live theme changes',
      (tester) async {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final mode = ValueNotifier(ThemeMode.light);
    addTearDown(mode.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    final light = ShunUiTheme.resolve(Brightness.light, 'tokyo-night');
    final dark = ShunUiTheme.resolve(Brightness.dark, 'tokyo-night');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repository),
          appLockControllerProvider.overrideWith((ref) => AppLockController(
                auth: _NoDeviceAuth(),
                settings: const AppSettings(),
                hasConnectedTerminal: () => false,
              )),
        ],
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: mode,
          builder: (context, value, child) => ShunUiHost(
            navigatorKey: navigatorKey,
            theme: light,
            darkTheme: dark,
            themeMode: value,
            locale: const Locale('zh', 'CN'),
            home: const Scaffold(body: VaultScreen()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final screen = tester.state(find.byType(VaultScreen));

    final steps = <(ThemeMode, Brightness, bool)>[
      (ThemeMode.light, Brightness.dark, false),
      (ThemeMode.dark, Brightness.light, true),
      (ThemeMode.system, Brightness.dark, true),
      (ThemeMode.system, Brightness.light, false),
      (ThemeMode.light, Brightness.dark, false),
    ];
    for (final (themeMode, platform, darkExpected) in steps) {
      tester.platformDispatcher.platformBrightnessTestValue = platform;
      mode.value = themeMode;
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(VaultScreen));
      final expected = darkExpected ? dark : light;
      expect(Theme.of(context).colorScheme,
          materialThemeFor(expected).colorScheme);
      expect(p.Theme.of(context), same(expected.prismTheme));
      expect(tester.state(find.byType(VaultScreen)), same(screen),
          reason: '切主题只换颜色，不重建页面');
      final image = tester.widget<Image>(find.byType(Image));
      final asset = image.image as AssetImage;
      expect(
          asset.assetName,
          darkExpected
              ? 'assets/brand/header_icon.png'
              : 'assets/brand/header_icon_light.png');
      // Resolve the real bundled PNG, so an absent/corrupt light asset fails too.
      final stream = image.image.resolve(ImageConfiguration.empty);
      ImageInfo? info;
      final listener = ImageStreamListener((frame, _) => info = frame);
      stream.addListener(listener);
      await tester.runAsync(() async {
        for (var i = 0; info == null && i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      stream.removeListener(listener);
      expect(info, isNotNull);
      expect(info!.image.width, 112);
      expect(info!.image.height, 112);
      info!.dispose();
      expect(tester.takeException(), isNull);
    }
  });
}

class _NoDeviceAuth implements DeviceAuth {
  @override
  set onActivityPaused(void Function(bool ownActivity)? callback) {}

  @override
  Future<bool> isDeviceSecure() async => false;

  @override
  Future<DeviceAuthOutcome> authenticate({
    required String title,
    String? description,
    required bool pinOnly,
    required bool allowWeak,
  }) async =>
      const DeviceAuthOutcome(DeviceAuthResult.unavailable);

  @override
  Future<void> setProtectRecents(bool enabled) async {}
}
