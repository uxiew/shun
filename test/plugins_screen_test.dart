import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/plugin_discovery.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/infrastructure/plugins/android_plugin_bridge.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:netcatty_mobile/presentation/screens/plugin_detail_screen.dart';
import 'package:netcatty_mobile/presentation/screens/plugins_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

// X04 插件管理界面：详情页按状态给出操作（批准 / 连接测试 / 停用 / 启用 / 撤销 / 设置页），
// 显示来源、证书、两种版本、能力、路线、权限；页面开着时插件包变了，按重新核验的结果变化（PLG11）。
// 桥是假的——真实的包事件和设置页在模拟器上验证，见 evidence/X04.md。

const pkg = 'example.xwshun.fixture.echo';
const author =
    'ffb53d5ae3ef071d73b680c14c219c0662df7545a87e6042991ab11c862c52fe';
const impostor =
    'e257e747678f3ce38aa6fa1878c87a8f26dd7d9503ac8da3289d598fb472397f';

DiscoveredPackage echo({String cert = author, String version = '0.1.0'}) =>
    DiscoveredPackage(
      packageName: pkg,
      serviceClass: 'example.xwshun.fixture.echo.EchoProviderService',
      versionName: version,
      versionCode: 7,
      settingsActivity: 'example.xwshun.fixture.echo.SettingsActivity',
      signers: [(sha256: cert, androidDebug: false)],
      descriptorJson: jsonEncode({
        'schemaVersion': 1,
        'pluginId': 'example.fixture_echo',
        'displayName': 'Echo fixture (test only)',
        'version': version,
        'apiMajor': 1,
        'apiMinor': 0,
        'deployment': 'android-service',
        'capabilities': ['terminal-session'],
        'supportedRoutes': ['system-default'],
        'platforms': ['android'],
        'permissions': ['own-session-input-output'],
        'packageName': pkg,
        'serviceClass': 'example.xwshun.fixture.echo.EchoProviderService',
        'license': 'GPL-3.0-or-later',
      }),
    );

class FakeBridge extends AndroidPluginBridge {
  var installed = <DiscoveredPackage>[];
  final settingsOpened = <String>[];
  final disconnects = <String>[];
  final changes = StreamController<PackageChange>.broadcast(sync: true);

  @override
  bool get supported => true;
  @override
  Stream<PackageChange> get packageChanges => changes.stream;
  @override
  Future<List<DiscoveredPackage>> discover() async => installed;
  @override
  Future<String> connect({
    required String packageName,
    required String serviceClass,
    required String pluginId,
    required String sha256,
  }) async {
    connected.add(packageName);
    return '';
  }

  /// 和 Kotlin 桥一样：没连着的插件 ping 报 NOT_CONNECTED。
  final connected = <String>{};
  @override
  Future<int> ping(String packageName, int nonce) async {
    if (!connected.contains(packageName)) {
      throw const PluginBridgeException('NOT_CONNECTED', '没有连着这个插件');
    }
    return nonce;
  }

  @override
  Future<void> disconnect(String packageName) async {
    disconnects.add(packageName);
    connected.remove(packageName);
  }

  @override
  Future<void> openSettings(String packageName, String activity) async =>
      settingsOpened.add(activity);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBridge bridge;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bridge = FakeBridge()..installed = [echo()];
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [androidPluginBridgeProvider.overrideWithValue(bridge)],
      child: const MaterialApp(home: PluginsScreen()),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openDetail(WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-entry-$pkg')));
    await tester.pumpAndSettle();
  }

  String status(WidgetTester tester) => tester
      .widget<LText>(find.descendant(
          of: find.byKey(const ValueKey('plugin-status')),
          matching: find.byType(LText)))
      .data;

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('待批准：只有「批准」，没有连接测试、停用和设置页入口；信息齐全', (tester) async {
    await openDetail(tester);
    expect(status(tester), '待批准');
    expect(find.byKey(const ValueKey('plugin-approve')), findsOneWidget);
    for (final key in [
      'plugin-check',
      'plugin-disable',
      'plugin-open-settings'
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    expect(find.text('批准并启用后才能打开：批准之前不会启动插件的任何代码。'), findsOneWidget);
    expect(find.text('来源：独立安装的 App'), findsOneWidget);
    expect(find.text('插件自称的版本：0.1.0'), findsOneWidget);
    expect(find.text('安装包版本：0.1.0（7）'), findsOneWidget);
    expect(find.text('能力：终端会话（terminal-session）'), findsOneWidget);
    expect(find.text('支持的连接路线：直连（系统网络）（system-default）'), findsOneWidget);
    expect(
        find.text('申请的权限：本会话的输入输出（own-session-input-output）'), findsOneWidget);
    expect(find.text(author), findsOneWidget);
  });

  testWidgets('批准后：可用，出现连接测试、设置页、停用、撤销；设置页只打开系统查出的那个组件', (tester) async {
    await openDetail(tester);
    await tapKey(tester, 'plugin-approve');
    await tapKey(tester, 'plugin-approve-confirm');
    expect(status(tester), '可用');
    for (final key in [
      'plugin-check',
      'plugin-disable',
      'plugin-revoke',
      'plugin-open-settings',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    await tapKey(tester, 'plugin-open-settings');
    expect(bridge.settingsOpened,
        ['example.xwshun.fixture.echo.SettingsActivity']);
  });

  testWidgets('停用：会话断开、设置页入口消失；启用后直接可用', (tester) async {
    await openDetail(tester);
    await tapKey(tester, 'plugin-approve');
    await tapKey(tester, 'plugin-approve-confirm');
    await tapKey(tester, 'plugin-disable');
    expect(status(tester), '已停用');
    expect(bridge.disconnects, contains(pkg));
    expect(find.byKey(const ValueKey('plugin-open-settings')), findsNothing);
    expect(find.byKey(const ValueKey('plugin-enable')), findsOneWidget);
    await tapKey(tester, 'plugin-enable');
    expect(status(tester), '可用');
  });

  testWidgets('PLG11 页面开着时插件被换签：变成已拒绝，之前的测试结果作废，不自动重新批准', (tester) async {
    await openDetail(tester);
    await tapKey(tester, 'plugin-approve');
    await tapKey(tester, 'plugin-approve-confirm');
    await tapKey(tester, 'plugin-check');
    expect(find.byKey(const ValueKey('plugin-check-result')), findsOneWidget);

    bridge.installed = [echo(cert: impostor)];
    bridge.changes.add(const PackageChange(pkg, 'added'));
    await tester.pumpAndSettle();

    expect(status(tester), '已拒绝');
    expect(find.byKey(const ValueKey('plugin-check-result')), findsNothing);
    expect(find.textContaining('之前的连接测试结果已作废'), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-check')), findsNothing);
    expect(find.byKey(const ValueKey('plugin-open-settings')), findsNothing);
    // 换签后仍能撤销旧批准，好让用户重新核对。
    expect(find.byKey(const ValueKey('plugin-revoke')), findsOneWidget);
    expect(find.text(impostor), findsOneWidget);
  });

  testWidgets('确认框开着时包被更新：点批准后马上说明没批准，不排在「检测到更新」提示后面', (tester) async {
    await openDetail(tester);
    await tapKey(tester, 'plugin-approve');
    bridge.installed = [echo(version: '0.2.0')];
    bridge.changes.add(const PackageChange(pkg, 'replaced', replacing: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('检测到插件包更新'), findsWidgets);
    await tapKey(tester, 'plugin-approve-confirm');
    expect(find.textContaining('确认期间插件有变化'), findsOneWidget);
    expect(status(tester), '待批准');
  });

  testWidgets('包变了之后不再显示「断开」：那条连接已经被断开了', (tester) async {
    await openDetail(tester);
    await tapKey(tester, 'plugin-approve');
    await tapKey(tester, 'plugin-approve-confirm');
    await tapKey(tester, 'plugin-check');
    expect(find.text('断开'), findsOneWidget);
    bridge.installed = [echo(version: '0.2.0')];
    bridge.changes.add(const PackageChange(pkg, 'replaced', replacing: true));
    await tester.pumpAndSettle();
    expect(status(tester), '可用');
    expect(find.text('断开'), findsNothing);
    expect(bridge.disconnects, contains(pkg));
  });

  testWidgets('列表页：包更新后自动重新核对，事件里写明，不用手动重新扫描', (tester) async {
    await open(tester);
    bridge.installed = [echo(version: '0.2.0')];
    bridge.changes.add(const PackageChange(pkg, 'replaced', replacing: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('检测到插件包更新'), findsWidgets);
    expect(find.textContaining('0.2.0'), findsOneWidget);
  });

  testWidgets('英文界面：详情页没有汉字', (tester) async {
    NetcattyLocalizations.use('en');
    addTearDown(() => NetcattyLocalizations.use('zh'));
    await openDetail(tester);
    await tapKey(tester, 'plugin-approve');
    await tapKey(tester, 'plugin-approve-confirm');
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .followedBy(tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((t) => t.data ?? ''))
        .join('\n');
    expect(RegExp(r'[一-鿿]').hasMatch(text), isFalse, reason: text);
    expect(text, contains('Capabilities: Terminal session (terminal-session)'));
    expect(text, contains('Installed package version: 0.1.0 (7)'));
  });

  test('详情页用的状态名和注册表的状态一一对应', () {
    expect(PluginStatus.values.map(pluginStatusLabel).toSet(), hasLength(6));
  });
}
