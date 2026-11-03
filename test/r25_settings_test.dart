import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/app.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';

// R25 设置页整理：改了就存（没有「保存外观设置」），按 外观 / 终端 / 文件 / 连接 / 安全 / 数据 分组。

/// 存盘可以指定失败一次的仓库，只实现设置用到的两个方法。
class _FlakyRepository implements VaultRepository {
  AppSettings stored = const AppSettings();
  var failNextSave = false;

  @override
  Future<AppSettings> loadSettings() async => stored;

  @override
  Future<void> saveSettings(AppSettings settings) async {
    // 让两次存盘真的交错：不排队的话，后一条会在前一条写完之前读到旧文件。
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (failNextSave) {
      failNextSave = false;
      throw StateError('磁盘满了');
    }
    stored = settings;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('SettingsController.edit', () {
    test('两条几乎同时的修改都留下，后一条不盖掉前一条', () async {
      final repository = _FlakyRepository();
      final controller = SettingsController(repository);
      addTearDown(controller.dispose);

      await Future.wait([
        controller.edit((s) => s.copyWith(themeMode: 'light')),
        controller.edit((s) => s.copyWith(terminalFontSize: 20)),
      ]);

      expect(repository.stored.themeMode, 'light');
      expect(repository.stored.terminalFontSize, 20);
      expect(controller.state.themeMode, 'light');
      expect(controller.state.terminalFontSize, 20);
    });

    test('存失败：抛给调用的人、内存退回原样，后面的修改照常存', () async {
      final repository = _FlakyRepository()..failNextSave = true;
      final controller = SettingsController(repository);
      addTearDown(controller.dispose);

      await expectLater(
        controller.edit((s) => s.copyWith(themeMode: 'light')),
        throwsStateError,
      );
      expect(controller.state.themeMode, 'dark');
      expect(repository.stored.themeMode, 'dark');

      await controller.edit((s) => s.copyWith(language: 'en'));
      expect(repository.stored.language, 'en');
      expect(repository.stored.themeMode, 'dark');
    });
  });

  group('设置页', () {
    const secureStorage =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

    setUp(() {
      SharedPreferences.setMockInitialValues({});
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
      ShunLocalizations.use('zh-CN');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorage, null);
    });

    Future<VaultRepository> openSettings(WidgetTester tester) async {
      final repository = await VaultRepository.open();
      // 设置页是懒加载 ListView：拉高窗口让整页一次建出来，分组顺序才比得了。
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: const ShunApp(),
      ));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump(const Duration(seconds: 1));
      return repository;
    }

    testWidgets('没有「保存外观设置」：主题、字号、SFTP 高亮、语言一改就存、马上生效', (tester) async {
      final repository = await openSettings(tester);
      expect(find.text('保存外观设置'), findsNothing);
      final probe = find.text('界面主题');
      expect(Theme.of(tester.element(probe)).brightness, Brightness.dark);

      await tester.tap(find.text('浅色'));
      // 先让存盘这几步异步走完、画出新主题的第一帧，再等主题渐变动画走完。
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect((await repository.loadSettings()).themeMode, 'light');
      expect(Theme.of(tester.element(probe)).brightness, Brightness.light,
          reason: '整个 App 马上换成浅色，不用再点别的');

      final slider = find.byKey(const ValueKey('settings-terminal-font-size'));
      await tester.drag(slider, const Offset(200, 0));
      await tester.pump(const Duration(milliseconds: 300));
      final fontSize = (await repository.loadSettings()).terminalFontSize;
      expect(fontSize, greaterThan(14), reason: '松手就存');
      final preview = tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('settings-terminal-font-preview')),
        matching: find.byType(Text),
      ));
      expect(preview.style?.fontSize, fontSize, reason: '示意行和存下的字号一致');

      await tester.tap(find.byKey(const ValueKey('settings-sftp-highlight')));
      await tester.pump(const Duration(milliseconds: 300));
      expect((await repository.loadSettings()).sftpSyntaxHighlight, isFalse);

      await tester.tap(find.text('英文'));
      await tester.pump(const Duration(seconds: 1));
      expect((await repository.loadSettings()).language, 'en');
      expect(find.text('Interface language'), findsOneWidget,
          reason: '界面马上换成英文');
      // 前面改的都还在：每次只改一项，不拿页面上的旧值覆盖。
      final saved = await repository.loadSettings();
      expect(saved.themeMode, 'light');
      expect(saved.terminalFontSize, fontSize);
      expect(saved.sftpSyntaxHighlight, isFalse);
    });

    testWidgets('分组顺序：通用 → 终端 → 连接 → 安全 → 数据，连接记录在「连接」里', (tester) async {
      await openSettings(tester);
      final settings = find.byType(ListView).last;
      double top(String header) => tester
          .getTopLeft(
              find.descendant(of: settings, matching: find.text(header)))
          .dy;

      final order = ['通用', '终端', '连接', '安全', '数据'].map(top).toList();
      expect(order, orderedEquals([...order]..sort()));

      double keyTop(String key) =>
          tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      // UXR08：改之前散在「外观」「文件」「关于与更新」的，都归到通用；这些旧标题不留。
      for (final key in ['settings-language', 'settings-sftp-highlight']) {
        expect(keyTop(key), inExclusiveRange(top('通用'), top('终端')),
            reason: key);
      }
      for (final old in ['外观', '文件', '关于与更新', '远程桌面', '插件']) {
        expect(find.descendant(of: settings, matching: find.text(old)),
            findsNothing,
            reason: old);
      }
      for (final key in [
        'settings-credentials',
        'settings-app-log',
        'settings-tailscale-catalog',
      ]) {
        expect(keyTop(key), inExclusiveRange(top('连接'), top('安全')),
            reason: key);
      }
      expect(keyTop('settings-hidden-hosts'),
          inExclusiveRange(top('安全'), top('数据')));
      expect(
        keyTop('settings-allow-sensitive-screenshots'),
        inExclusiveRange(top('安全'), top('数据')),
      );
    });
  });
}
