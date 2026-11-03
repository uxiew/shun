// Tailscale 设置和设备走查（F39、R75、R76、R78）：真 App 页面、中文字体、真屏幕尺寸、真键盘，看面板放不放得下。
// 不连网，没有真的 Tailscale 账号。只用工具跑：
//   SHUN_R39_AVD=shun-r39-a30 SHUN_R70_TARGET=integration_test/r75_tailscale_settings_test.dart python3 tool/r70-device.py
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/catalog_overview.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/tailscale_catalog_provider.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';
import 'package:shun/presentation/home_shell.dart';
import 'package:shun/presentation/widgets/connection_route_editor.dart';

void mark(String line) => debugPrint('R70 $line');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    await binding.delayed(const Duration(milliseconds: 400));
    await tester.pump();
    mark('SHOT $name');
    // 给脚本留出截屏时间：它读到标记才动手。
    await binding.delayed(const Duration(milliseconds: 1200));
    await tester.pump();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await settle(tester);
    await tester.tap(finder);
    await settle(tester);
  }

  /// 走用户的路：⊕ → 表单顶上的「更多」→ Tailscale。
  Future<void> openFromNew(WidgetTester tester) async {
    await tester.tap(find.byTooltip('添加连接').first);
    await settle(tester);
    await binding.delayed(const Duration(milliseconds: 500));
    await tapKey(tester, 'host-type-more');
    await tapKey(tester, 'connection-type-Tailscale');
    await binding.delayed(const Duration(milliseconds: 800));
    await settle(tester);
  }

  testWidgets('面板：默认两项、弹键盘、高级、已有来源', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)]);
    addTearDown(container.dispose);
    final controller = container.read(vaultControllerProvider.notifier);
    final vault = await controller.ready();
    // 带密码框的页面默认防截屏，adb screencap 得到 0 字节。只开在这个用完就清数据的测试 App 上。
    await container
        .read(settingsControllerProvider.notifier)
        .updateAllowSensitiveScreenshots(true);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    for (var i = 0; i < 600 && find.byType(HomeShell).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settle(tester);

    // R78：还没有主机时给两条路。
    await shot(tester, '00-empty');
    expect(find.byKey(const ValueKey('vault-empty-add-host')), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-empty-tailscale')), findsOneWidget);
    await controller.replace(VaultData.fromJson({
      ...vault.toJson(),
      'hosts': [
        {
          'id': 'edge',
          'label': '公司跳板',
          'hostname': '10.0.0.8',
          'port': 22,
          'username': 'ops',
          'protocol': 'ssh',
        },
      ],
      'proxyProfiles': [
        {
          'id': 'p',
          'label': '公司代理',
          'config': {'type': 'socks5', 'host': '192.0.2.1', 'port': 1080},
        },
      ],
    }));
    await settle(tester);

    await openFromNew(tester);
    await shot(tester, '01-new');
    expect(find.byType(BottomSheet), findsOneWidget);
    // 只数面板里的：后面连接页的搜索框也是 TextField。
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      ),
      findsNWidgets(2),
    );

    await tapKey(tester, 'ts-settings-login');
    await shot(tester, '02-credential');
    await tapKey(tester, 'ts-settings-login');

    // 真键盘弹起来后，保存按钮要在键盘上面。
    await tapKey(tester, 'ts-settings-key');
    await binding.delayed(const Duration(milliseconds: 1500));
    await settle(tester);
    await shot(tester, '03-keyboard');
    final view = tester.view;
    final keyboard = view.viewInsets.bottom / view.devicePixelRatio;
    final height = view.physicalSize.height / view.devicePixelRatio;
    final save = tester.getRect(find.byKey(const ValueKey('ts-settings-save')));
    mark('report keyboard=$keyboard screen=$height save=$save');
    expect(keyboard, greaterThan(0), reason: '要真弹出键盘才算测了');
    expect(save.bottom, lessThanOrEqualTo(height - keyboard));
    FocusManager.instance.primaryFocus?.unfocus();
    await binding.delayed(const Duration(milliseconds: 1000));
    await settle(tester);

    await tester.tap(find.text('高级'));
    await settle(tester);
    await shot(tester, '04-advanced');
    await tapKey(tester, 'ts-settings-cancel');

    // 已有来源：开的还是那一份，设过的代理收着也看得见。
    final catalog = container.read(tailscaleCatalogProvider);
    await catalog.addSource(catalogId: 'ts-r75', label: 'Tailscale');
    await catalog.saveImportDefaults('ts-r75', {
      'username': 'ubuntu',
      'port': 2222,
      'proxyProfileId': 'p',
      'group': 'lab',
    });
    await openFromNew(tester);
    await shot(tester, '05-existing');
    expect(find.text('端口 2222 · 代理 · 分组'), findsOneWidget);
    expect(find.text('移除 Tailscale'), findsOneWidget);
    await tester.tap(find.text('高级'));
    await settle(tester);
    await shot(tester, '06-existing-advanced');
    expect(find.text('连接路径'), findsOneWidget);

    // 真配一次跳板：下拉、选项都是真页面上点的，存完再打开还在。
    final addJump = find.descendant(
      of: find.byType(ConnectionRouteEditor),
      matching: find.byType(DropdownButtonFormField<String>),
    );
    await tester.ensureVisible(addJump);
    await settle(tester);
    await tester.tap(addJump);
    await settle(tester);
    await tester.tap(find.text('公司跳板').last);
    await settle(tester);
    await shot(tester, '07-route-with-jump');
    await tapKey(tester, 'ts-settings-save');
    await binding.delayed(const Duration(milliseconds: 800));
    await settle(tester);
    final saved =
        (await container.read(catalogCacheRepositoryProvider).load('ts-r75'))!
            .importDefaults;
    mark('report saved=$saved');
    expect(saved['proxyProfileId'], 'p');
    expect(saved['jumpHostIds'], ['edge']);
    await openFromNew(tester);
    await shot(tester, '08-reopened');
    expect(find.text('端口 2222 · 代理 · 跳板机 · 分组'), findsOneWidget);
    await tapKey(tester, 'ts-settings-cancel');

    // 所有者 11-02：存过 key 只有掩码和改、删。key 是假的，直接写进安全存储，走完就删，后面的步骤不会拿它去请求。
    await const TailscaleCatalogSecretStore(FlutterSecureCatalogBackend())
        .saveAccessToken('ts-r75', 'tskey-api-R75-FAKE');
    await openFromNew(tester);
    await shot(tester, '08a-key-masked');
    expect(find.byKey(const ValueKey('ts-settings-saved-key')), findsOneWidget);
    await tapKey(tester, 'ts-settings-change-key');
    await binding.delayed(const Duration(milliseconds: 1500));
    await settle(tester);
    await shot(tester, '08b-key-replacing');
    await tapKey(tester, 'ts-settings-cancel-change-key');
    FocusManager.instance.primaryFocus?.unfocus();
    await binding.delayed(const Duration(milliseconds: 1000));
    await settle(tester);
    await tapKey(tester, 'ts-settings-forget-key');
    await shot(tester, '08c-key-delete-confirm');
    await tapKey(tester, 'ts-settings-forget-key-confirm');
    await binding.delayed(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.byKey(const ValueKey('ts-settings-key')), findsOneWidget);
    await shot(tester, '08d-key-deleted');
    await tapKey(tester, 'ts-settings-cancel');

    // R76：设备不提导入，能隐藏、能找回。设备是塞进缓存的，没连真 Tailscale。
    final repo = container.read(catalogCacheRepositoryProvider);
    final cached = (await repo.load('ts-r75'))!;
    await repo.save(cached.merge(
      TailscaleDeviceSnapshot.parse(jsonEncode({
        'devices': [
          for (final (id, name) in [('1', 'nas'), ('2', 'laptop')])
            {
              'id': id,
              'hostname': name,
              'name': '$name.tail1234.ts.net',
              'addresses': ['100.64.0.$id'],
              'os': 'linux',
            },
        ],
      })),
      DateTime.now(),
    ));
    await container.read(catalogOverviewProvider.notifier).reload();
    await settle(tester);
    await shot(tester, '09-devices');
    expect(find.textContaining('导入'), findsNothing);
    await tapKey(tester, 'vault-catalog-device-menu-ts-r75-2');
    await tapKey(tester, 'vault-catalog-device-hide-ts-r75-2');
    await binding.delayed(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.byKey(const ValueKey('vault-catalog-device-ts-r75-2')),
        findsNothing);
    await shot(tester, '10-device-hidden');
    expect(find.byKey(const ValueKey('vault-show-hidden')), findsNothing);
    // 所有者 11-02：恢复只在「设置 → 安全 → 隐藏的主机」。
    await tester.tap(find.text('设置').last);
    await settle(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-hidden-hosts')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await settle(tester);
    await shot(tester, '11-settings-security');
    await tapKey(tester, 'settings-hidden-hosts');
    await shot(tester, '12-hidden-page');
    await tapKey(tester, 'hidden-restore-ts-r75-2');
    await binding.delayed(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.text('没有隐藏的主机'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await settle(tester);
    await tester.tap(find.text('连接').last);
    await settle(tester);
    expect(find.byKey(const ValueKey('vault-catalog-device-ts-r75-2')),
        findsOneWidget);
    await shot(tester, '13-device-restored');

    await tester.pumpWidget(const SizedBox());
  });
}
