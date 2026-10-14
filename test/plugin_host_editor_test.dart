import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/plugin_discovery.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/plugins/plugin_host.dart';
import 'package:shun/infrastructure/plugins/plugin_approval_store.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/host_address_line.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:plugin_api/plugin_api.dart' show ApprovedBinding, Capability;
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/fake_plugin_bridge.dart';

// X12：主机编辑器里的「插件」协议、主机列表上插件主机那一行。
// 只列能用来开标签的插件：可用、声明了终端会话、不要临时凭据（Mosh 不在这里）；
// 插件主机没有地址、端口、用户名，残留的代理和跳板设置要用户明确改成直连才能保存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const hello = 'example.shun.hello';
  const helloId = 'example.hello_terminal';
  late FakePluginBridge bridge;
  HostProfile? result;

  Future<void> approve(String pluginId, String package) async {
    final prefs = await SharedPreferences.getInstance();
    await PluginApprovalStore(prefs).save(ApprovedBinding(
      pluginId: pluginId,
      packageName: package,
      signingDigest: 'author-cert',
      capabilities: const {Capability.terminalSession},
    ));
  }

  Future<void> open(WidgetTester tester,
      {HostProfile? host, double width = 900}) async {
    tester.view.physicalSize = Size(width, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    final repository = await VaultRepository.open();
    await repository.saveVault(VaultData.fromJson({
      'hosts': [if (host != null) host.toJson()],
      'keys': [],
      'snippets': [],
      'customGroups': [],
    }));
    result = null;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        androidPluginBridgeProvider.overrideWithValue(bridge),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () async {
                    result = await Navigator.push<HostProfile>(
                      context,
                      MaterialPageRoute(
                          builder: (_) => HostEditor(
                              host: host,
                              initialProtocol: HostProtocol.plugin)),
                    );
                  },
                  child: const Text('open'),
                ),
                if (host != null) HostAddressLine(host),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bridge = FakePluginBridge()
      ..installed = [
        terminalPlugin(
            package: hello,
            pluginId: helloId,
            settingsActivity: '$hello.SettingsActivity'),
        terminalPlugin(
            package: 'com.x.secret',
            pluginId: 'com.x.secret',
            displayName: 'Secret',
            permissions: [
              'own-session-input-output',
              'own-session-ephemeral-secret',
            ]),
        terminalPlugin(
            package: 'com.x.pending',
            pluginId: 'com.x.pending',
            displayName: 'Pending'),
      ];
  });

  testWidgets('新建插件主机：不填地址；只列能开标签的插件；保存 pluginId，不留代理和跳板', (tester) async {
    await approve(helloId, hello);
    await approve('com.x.secret', 'com.x.secret');
    await open(tester);
    await openEditor(tester);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '主机名 / IP'), findsNothing);
    expect(find.widgetWithText(TextFormField, '用户名'), findsNothing);
    expect(find.byKey(const ValueKey('route-mode')), findsNothing);
    expect(find.byKey(const ValueKey('test-connection')), findsNothing);
    expect(find.byKey(const ValueKey('plugin-network-note')), findsOneWidget);

    // 没选插件不让保存。
    await tester.enterText(find.widgetWithText(TextFormField, '名称'), 'notes');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.textContaining('选一个插件'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('plugin-picker')));
    await tester.pumpAndSettle();
    // 菜单里只有能开标签的：要临时凭据的（Secret）、没批准的（Pending）都不列。
    expect(find.textContaining('Hello 终端（样例）'), findsWidgets);
    expect(find.textContaining('Secret'), findsNothing);
    expect(find.textContaining('Pending'), findsNothing);
    await tester.tap(find.textContaining('Hello 终端（样例）').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plugin-open-settings-from-editor')),
        findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('plugin-open-settings-from-editor')));
    await tester.pumpAndSettle();
    expect(bridge.settingsOpened, ['$hello.SettingsActivity']);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.protocol, HostProtocol.plugin);
    expect(pluginIdOf(result!), helloId);
    expect(result!.data.containsKey('proxyConfig'), isFalse);
    expect(result!.data.containsKey('hostChain'), isFalse);
  });

  testWidgets('从桌面端同步来、带代理的插件主机：不让保存，要用户点「改成直连」', (tester) async {
    await approve(helloId, hello);
    final host = HostProfile({
      'id': 'p1',
      'label': 'notes',
      'hostname': '',
      'username': '',
      'port': 22,
      'protocol': 'plugin',
      pluginIdKey: helloId,
      'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
    });
    await open(tester, host: host);
    await openEditor(tester);
    expect(find.byKey(const ValueKey('plugin-route-problem')), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, isNull, reason: '不悄悄去掉代理');
    await tester.tap(find.byKey(const ValueKey('plugin-route-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plugin-route-problem')), findsNothing);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.data.containsKey('proxyConfig'), isFalse);
  });

  testWidgets('主机列表：插件主机写用哪个插件；插件停用了标「不可用」，编辑器里写原因', (tester) async {
    await approve(helloId, hello);
    final prefs = await SharedPreferences.getInstance();
    await PluginApprovalStore(prefs).setDisabled(helloId, true);
    final host = HostProfile({
      'id': 'p1',
      'label': 'notes',
      'hostname': '',
      'username': '',
      'port': 22,
      'protocol': 'plugin',
      pluginIdKey: helloId,
    });
    await open(tester, host: host);
    expect(find.text('插件 Hello 终端（样例） · 不可用'), findsOneWidget);
    await openEditor(tester);
    expect(find.byKey(const ValueKey('plugin-unavailable')), findsOneWidget);
    expect(find.textContaining('被停用了'), findsOneWidget);
  });

  testWidgets('手机竖屏宽度（411）：选中的插件名加 ID 放不下也不溢出', (tester) async {
    await approve(helloId, hello);
    final host = HostProfile({
      'id': 'p1',
      'label': 'notes',
      'hostname': '',
      'username': '',
      'port': 22,
      'protocol': 'plugin',
      pluginIdKey: helloId,
    });
    await open(tester, host: host, width: 411);
    await openEditor(tester);
    // 溢出时 flutter_test 自己就判失败（模拟器上实测溢出过 17 像素）。
    expect(find.textContaining('Hello 终端（样例）（$helloId）'), findsOneWidget);
  });

  testWidgets('没有能用的插件：说清楚去哪装、去哪批准，Mosh 不在这里', (tester) async {
    await open(tester);
    await openEditor(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plugin-none-usable')), findsOneWidget);
  });
}
