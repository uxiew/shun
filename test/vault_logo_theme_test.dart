import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/vault_screen.dart';

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
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final theme = ValueNotifier(ThemeMode.light);
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: theme,
          builder: (context, mode, child) => MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home: const Scaffold(body: VaultScreen()),
          ),
        ),
      ),
    );

    for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.light]) {
      theme.value = mode;
      await tester.pumpAndSettle();
      final image = tester.widget<Image>(find.byType(Image));
      final asset = image.image as AssetImage;
      expect(
          asset.assetName,
          mode == ThemeMode.dark
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
