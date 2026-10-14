import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/plugin_discovery.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/rustdesk.dart';
import 'package:shun/application/uuremote.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/plugins/plugin_host.dart';
import 'package:shun/infrastructure/plugins/plugin_approval_store.dart';
import 'package:shun/infrastructure/plugins/rustdesk_external.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/screens/connection_type_screen.dart';
import 'package:shun/presentation/screens/rustdesk_screen.dart';
import 'package:shun/presentation/screens/uuremote_screen.dart';
import 'package:shun/presentation/screens/vault_screen.dart';
import 'package:shun/presentation/widgets/host_editor.dart';

import 'fixtures/fake_plugin_bridge.dart';
import 'rustdesk_fakes.dart';
import 'uuremote_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VaultRepository vault;
  late FakePluginBridge bridge;
  late FakeRustDeskPlatform rd;
  late FakePlatform uu;
  late MemoryBackend rdBackend;
  late MemoryBackend uuBackend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
    vault = await VaultRepository.open();
    await vault.saveVault(VaultData.fromJson(
        {'hosts': [], 'keys': [], 'snippets': [], 'customGroups': []}));
    bridge = FakePluginBridge();
    rd = FakeRustDeskPlatform();
    uu = FakePlatform();
    rdBackend = MemoryBackend();
    uuBackend = MemoryBackend();
  });

  Future<ProviderContainer> open(WidgetTester tester, Widget home,
      {double width = 411}) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(vault),
          androidPluginBridgeProvider.overrideWithValue(bridge),
          rustDeskPlatformProvider.overrideWithValue(rd),
          rustDeskStoreProvider.overrideWithValue(RustDeskStore(rdBackend)),
          uuRemotePlatformProvider.overrideWithValue(uu),
          uuRemoteStoreProvider.overrideWithValue(UuRemoteStore(uuBackend)),
        ],
        child:
            MaterialApp(home: UuRemoteListener(child: Scaffold(body: home)))));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
        tester.element(find.byType(home.runtimeType).first));
  }

  Future<void> select(WidgetTester tester, String type) async {
    await tester.tap(find.byTooltip('添加连接'));
    await tester.pumpAndSettle();
    final tile = find.byKey(ValueKey('connection-type-$type'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  for (final type in ['SSH', 'Mosh', 'Telnet']) {
    testWidgets(
        '$type entry opens only its applicable form; no implicit launch',
        (tester) async {
      await open(tester, const VaultScreen());
      await select(tester, type);
      expect(find.byType(HostEditor), findsOneWidget);
      final editor = tester.widget<HostEditor>(find.byType(HostEditor));
      expect(editor.initialProtocol.name, type.toLowerCase());
      expect(find.widgetWithText(TextFormField, '用户名'),
          type == 'Telnet' ? findsNothing : findsOneWidget);
      expect(find.byKey(const ValueKey('mosh-note')),
          type == 'Mosh' ? findsOneWidget : findsNothing);
      expect(rd.launched, isEmpty);
      expect(uu.launched, isEmpty);
      expect(bridge.opened, isEmpty);
      await tester.enterText(
          find.widgetWithText(TextFormField, '名称'), '$type example');
      await tester.enterText(
          find.widgetWithText(TextFormField, '主机名 / IP'), 'host.example');
      if (type != 'Telnet') {
        await tester.enterText(
            find.widgetWithText(TextFormField, '用户名'), 'tester');
      }
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final host = (await vault.loadVault()).hosts.single;
      expect(host.protocol.name, type.toLowerCase());
      expect(host.hostname, 'host.example');
      expect(host.username, type == 'Telnet' ? '' : 'tester');
      await tester.tap(find.text('$type example'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(
          tester.widget<HostEditor>(find.byType(HostEditor)).host!.id, host.id);
      expect(tester.takeException(), isNull);
    });
  }

  for (final type in ['RustDesk', 'UU 远程']) {
    testWidgets(
        '$type creates a local entry without any SSH host; rename survives reopening',
        (tester) async {
      final container = await open(tester, const VaultScreen());
      await select(tester, type);
      await tester.enterText(
          find.byKey(const ValueKey('remote-entry-name')), 'remote only');
      await tester.tap(find.byKey(const ValueKey('remote-entry-save')));
      await tester.pumpAndSettle();
      expect(
          find.byType(
              type == 'RustDesk' ? RustDeskHostScreen : UuRemoteHostScreen),
          findsOneWidget);
      expect(find.widgetWithText(TextFormField, '主机名 / IP'), findsNothing);
      expect(find.widgetWithText(TextFormField, '用户名'), findsNothing);
      expect((await vault.loadVault()).hosts, isEmpty);
      expect(rd.launched, isEmpty);
      expect(uu.launched, isEmpty);
      await tester.tap(find.byKey(const ValueKey('remote-entry-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('remote-entry-name')), 'renamed');
      await tester.tap(find.byKey(const ValueKey('remote-entry-save')));
      await tester.pumpAndSettle();
      final entries = type == 'RustDesk'
          ? container.read(rustDeskProvider).entries
          : container.read(uuRemoteProvider).entries;
      expect(entries.single.label, 'renamed');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('renamed'), findsOneWidget);
      await tester.tap(find.text('renamed'));
      await tester.pumpAndSettle();
      if (type == 'RustDesk') {
        await tester.enterText(
            find.byKey(const ValueKey('rd-id-field')), '123 456 789');
        await tester.tap(find.byKey(const ValueKey('rd-save')));
        await tester.pumpAndSettle();
        expect(rd.launched, isEmpty);
        await tester.tap(find.byKey(const ValueKey('rd-launch')));
        await tester.pumpAndSettle();
        expect(rd.launched.single.$1, 'rustdesk://connect/123456789');
      } else {
        await tester.tap(find.byKey(const ValueKey('uu-approve')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('uu-bind')));
        await tester.pumpAndSettle();
        final request = Uri.parse(uu.launched.single).queryParameters;
        uu.deliver(
            '${request['callback']}&nonce=${request['nonce']}&anonymous_device_id=opaque-new-entry');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('uu-offer-confirm')));
        await tester.pumpAndSettle();
        expect(uu.launched, hasLength(1),
            reason: 'Confirming never launches control automatically');
        await tester.tap(find.byKey(const ValueKey('uu-launch-fullscreen')));
        await tester.pumpAndSettle();
        expect(uu.launched, hasLength(2));
      }
      expect((await vault.loadVault()).hosts, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'missing app is explained; type selection never trusts or launches clients',
      (tester) async {
    rd.probeResult = const RustDeskProbe(platformSupported: true, handlers: []);
    await open(tester, const ConnectionTypeScreen());
    expect(find.text('未安装，可先保存条目'), findsOneWidget);
    expect(find.text('签名证书待批准'), findsOneWidget);
    expect(rdBackend.values.containsKey('rustdesk.trust.v1'), isFalse);
    expect(uuBackend.values.containsKey('uuremote.approvedSigner.v1'), isFalse);
    expect(rd.launched, isEmpty);
    expect(uu.launched, isEmpty);
  });

  testWidgets(
      'approved terminal plugin is selectable; revoke and uninstall update its reason without opening it',
      (tester) async {
    bridge.installed = [
      terminalPlugin(
          package: 'com.example.terminal',
          pluginId: 'example.terminal',
          displayName: 'Terminal')
    ];
    final prefs = await SharedPreferences.getInstance();
    await PluginApprovalStore(prefs).save(const ApprovedBinding(
        pluginId: 'example.terminal',
        packageName: 'com.example.terminal',
        signingDigest: 'author-cert',
        capabilities: {Capability.terminalSession}));
    final container = await open(tester, const ConnectionTypeScreen());
    final tile = find.byKey(const ValueKey('connection-type-Terminal'));
    await tester.ensureVisible(tile);
    expect(tester.widget<ListTile>(tile).enabled, isTrue);
    container.read(pluginRegistryProvider.notifier).revoke('example.terminal');
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(tile).enabled, isFalse);
    expect(find.textContaining('还没批准'), findsOneWidget);
    bridge.installed = [];
    await (await container.read(pluginDiscoveryProvider.future)).refresh();
    await tester.pumpAndSettle();
    expect(bridge.opened, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('approved plugin selection saves and reopens without SSH fields',
      (tester) async {
    bridge.installed = [
      terminalPlugin(
          package: 'com.example.terminal',
          pluginId: 'example.terminal',
          displayName: 'Terminal')
    ];
    final prefs = await SharedPreferences.getInstance();
    await PluginApprovalStore(prefs).save(const ApprovedBinding(
        pluginId: 'example.terminal',
        packageName: 'com.example.terminal',
        signingDigest: 'author-cert',
        capabilities: {Capability.terminalSession}));
    await open(tester, const VaultScreen());
    await select(tester, 'Terminal');
    expect(find.widgetWithText(TextFormField, '主机名 / IP'), findsNothing);
    expect(find.widgetWithText(TextFormField, '用户名'), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextFormField, '名称'), 'plugin entry');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final host = (await vault.loadVault()).hosts.single;
    expect(pluginIdOf(host), 'example.terminal');
    expect(host.protocol.name, 'plugin');
    await tester.tap(find.text('plugin entry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<HostEditor>(find.byType(HostEditor)).host!.id, host.id);
    expect(bridge.opened, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('type selection also has English labels at narrow width',
      (tester) async {
    ShunLocalizations.use('en');
    addTearDown(() => ShunLocalizations.use('zh'));
    await open(tester, const ConnectionTypeScreen(), width: 320);
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('\n');
    expect(RegExp(r'[一-鿿]').hasMatch(text), isFalse, reason: text);
    expect(tester.takeException(), isNull);
  });
}
