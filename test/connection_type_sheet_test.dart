import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/plugin_discovery.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/rustdesk.dart';
import 'package:shun/application/uuremote.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/plugins/plugin_host.dart';
import 'package:shun/infrastructure/plugins/plugin_approval_store.dart';
import 'package:shun/infrastructure/plugins/rustdesk_external.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/screens/rustdesk_screen.dart';
import 'package:shun/presentation/screens/uuremote_screen.dart';
import 'package:shun/presentation/screens/tailscale_settings_screen.dart';
import 'package:shun/presentation/screens/vault_screen.dart';
import 'package:shun/presentation/widgets/connection_type_sheet.dart';
import 'package:shun/presentation/widgets/hint.dart';
import 'package:shun/presentation/widgets/host_editor.dart';

import 'fixtures/fake_plugin_bridge.dart';
import 'rustdesk_fakes.dart';
import 'uuremote_fakes.dart';
import 'support/prism_test_host.dart';

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
          catalogCacheRepositoryProvider.overrideWithValue(_NoCatalogs()),
        ],
        child: MaterialApp(
            localizationsDelegates: prismTestDelegates,
            builder: prismTestBuilder,
            home: UuRemoteListener(child: Scaffold(body: home)))));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
        tester.element(find.byType(home.runtimeType).first));
  }

  /// SSH、Mosh、Telnet 点一下就换，其余在「更多」里。
  Future<void> pickType(WidgetTester tester, String type) async {
    if (const {'SSH', 'Mosh', 'Telnet'}.contains(type)) {
      await tester.tap(find.byKey(ValueKey('host-type-$type')));
      await tester.pumpAndSettle();
      return;
    }
    await tester.tap(find.byKey(const ValueKey('host-type-more')));
    await tester.pumpAndSettle();
    final tile = find.byKey(ValueKey('connection-type-$type'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String type) async {
    await tester.tap(find.byTooltip('添加连接'));
    await tester.pumpAndSettle();
    await pickType(tester, type);
  }

  /// 面板本身：terminalsOnly 为假时列全部类型。
  Widget sheet({bool terminalsOnly = false}) => ConnectionTypeSheet(
      current: HostProtocol.ssh, terminalsOnly: terminalsOnly);

  testWidgets('点添加连接直接进表单，不再先过一页选类型', (tester) async {
    await open(tester, const VaultScreen());
    await tester.tap(find.byTooltip('添加连接'));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsOneWidget);
    expect(find.byType(ConnectionTypeSheet), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('host-protocol')),
            matching: find.text('SSH')),
        findsOneWidget);
  });

  testWidgets('表单里换类型：填过的地址留着，端口跟着 22 和 23 变，改过的端口不动', (tester) async {
    await open(tester, const VaultScreen());
    await select(tester, 'Telnet');
    await tester.enterText(
        find.widgetWithText(TextFormField, '主机名 / IP'), 'host.example');
    final telnetPort = find.widgetWithText(TextFormField, 'Telnet 端口');
    expect(tester.widget<TextFormField>(telnetPort).controller!.text, '23');
    await pickType(tester, 'SSH');
    expect(find.text('host.example'), findsOneWidget);
    final sshPort = find.widgetWithText(TextFormField, 'SSH 端口');
    expect(tester.widget<TextFormField>(sshPort).controller!.text, '22');
    await tester.enterText(sshPort, '2200');
    await pickType(tester, 'Mosh');
    expect(tester.widget<TextFormField>(sshPort).controller!.text, '2200');
  });

  testWidgets('换到 Tailscale：没填东西直接去；填过的先问，选继续编辑留在表单', (tester) async {
    await open(tester, const VaultScreen());
    await tester.tap(find.byTooltip('添加连接'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, '主机名 / IP'), 'host.example');
    await tester.pump();
    await pickType(tester, 'Tailscale');
    expect(find.text('放弃没保存的改动？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('host-editor-keep-editing')));
    await tester.pumpAndSettle();
    expect(find.text('host.example'), findsOneWidget);
    expect(find.byType(TailscaleSettingsScreen), findsNothing);

    await tester.enterText(find.widgetWithText(TextFormField, '主机名 / IP'), '');
    await tester.pump();
    await pickType(tester, 'Tailscale');
    expect(find.byType(HostEditor), findsNothing);
    // 设置页打开就在读，转圈不停，pumpAndSettle 等不到头。
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TailscaleSettingsScreen), findsOneWidget);
  });

  testWidgets('UXR07：连接页没有主机时给两条路：加主机进表单，连接 Tailscale 进设置', (tester) async {
    await open(tester, const VaultScreen());
    expect(find.text('还没有终端连接'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vault-empty-add-host')));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsNothing);

    await tester.tap(find.byKey(const ValueKey('vault-empty-tailscale')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TailscaleSettingsScreen), findsOneWidget);
  });

  testWidgets('换到 RustDesk：不离开表单，只留名称；切回 SSH 填过的都在；保存才进它的页面，不启动客户端',
      (tester) async {
    await open(tester, const VaultScreen());
    await tester.tap(find.byTooltip('添加连接'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, '主机名 / IP'), 'host.example');
    await pickType(tester, 'RustDesk');
    expect(find.byType(HostEditor), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '主机名 / IP'), findsNothing);
    expect(find.byKey(const ValueKey('test-connection')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('host-editor-save')));
    await tester.pumpAndSettle();
    expect(find.text('必填'), findsOneWidget, reason: '没名称不让存');

    await pickType(tester, 'SSH');
    expect(find.text('host.example'), findsOneWidget);

    await pickType(tester, 'RustDesk');
    await tester.enterText(
        find.byKey(const ValueKey('remote-entry-name')), 'desk');
    await tester.tap(find.byKey(const ValueKey('host-editor-save')));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsNothing);
    expect(find.byType(RustDeskHostScreen), findsOneWidget);
    expect(rd.launched, isEmpty);
    expect((await vault.loadVault()).hosts, isEmpty);
  });

  testWidgets('编辑已有主机只能换终端类型：RustDesk、UU、Tailscale 不是同一种记录', (tester) async {
    await open(tester, sheet(terminalsOnly: true));
    for (final type in ['Tailscale', 'RustDesk', 'UU 远程']) {
      expect(find.byKey(ValueKey('connection-type-$type')), findsNothing);
    }
  });

  for (final type in ['SSH', 'Mosh', 'Telnet']) {
    testWidgets(
        '$type entry opens only its applicable form; no implicit launch',
        (tester) async {
      await open(tester, const VaultScreen());
      await select(tester, type);
      expect(find.byType(HostEditor), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '用户名'),
          type == 'Telnet' ? findsNothing : findsOneWidget);
      // Mosh 的用法在「连接类型」旁的 ⓘ 里，只有 Mosh 表单写它。
      final advice = find.byKey(const ValueKey('protocol-advice'));
      expect(
          advice.evaluate().isEmpty
              ? ''
              : tester.widget<HintButton>(advice).message,
          type == 'Mosh'
              ? contains('启动 mosh-server')
              : isNot(contains('启动 mosh-server')));
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
      await tester.tap(find.byKey(const ValueKey('host-editor-save')));
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
    await open(tester, sheet());
    expect(find.text('未安装'), findsOneWidget);
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
        capabilities: {Capability.terminalSession},
        permissions: {Permission.ownSessionInputOutput}));
    final semantics = tester.ensureSemantics();
    final container = await open(tester, sheet());
    final tile = find.byKey(const ValueKey('connection-type-Terminal'));
    await tester.ensureVisible(tile);
    // 按读屏看能不能点，不按控件类型（R88 从 ListTile 换成了 ShunListRow）。
    SemanticsNode row() => tester.getSemantics(find.descendant(
        of: tile, matching: find.text('Terminal'), matchRoot: true));
    expect(row(), isSemantics(isEnabled: true, hasTapAction: true));
    container.read(pluginRegistryProvider.notifier).revoke('example.terminal');
    await tester.pumpAndSettle();
    expect(row(), isSemantics(isEnabled: false, hasTapAction: false));
    expect(find.textContaining('还没批准'), findsOneWidget);
    bridge.installed = [];
    await (await container.read(pluginDiscoveryProvider.future)).refresh();
    await tester.pumpAndSettle();
    expect(bridge.opened, isEmpty);
    semantics.dispose();
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
        capabilities: {Capability.terminalSession},
        permissions: {Permission.ownSessionInputOutput}));
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
    await open(tester, sheet(), width: 320);
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('\n');
    expect(RegExp(r'[一-鿿]').hasMatch(text), isFalse, reason: text);
    expect(tester.takeException(), isNull);
  });
}

/// 本机没有 Tailscale 来源。真的仓库要读文件，假时钟的 pump 等不到。
class _NoCatalogs extends CatalogCacheRepository {
  _NoCatalogs() : super(() async => Directory.systemTemp);
  @override
  Future<List<CatalogCache>> loadAll() async => const [];
}
