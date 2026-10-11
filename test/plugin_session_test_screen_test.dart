import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/plugin_discovery.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/plugin_sessions.dart';
import 'package:shun/infrastructure/plugins/android_plugin_bridge.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/screens/plugin_session_test_screen.dart';
import 'package:shun/presentation/screens/plugins_screen.dart';
import 'package:plugin_api/plugin_api.dart' show SessionPhase;
import 'package:shared_preferences/shared_preferences.dart';

// X12 给插件作者的两样东西：插件页底部的「本 App 的签名证书」，详情页的「会话测试」。
// 桥是假的，插件那一侧的事件由测试按真实顺序发；真插件（plugins/example）在模拟器上走，见 evidence/X12.md。

const pkg = 'example.shun.hello';
const author =
    '12f7a9732bba95dc8997abf01356938d6370c3ac641114042350af1f9ce8f4ef';
const hostDebug =
    '499ff3abf2d0aeb386ce3b30da1c3a0fa3566d5d89b042bf279c0773f79d500f';

DiscoveredPackage hello(
        {List<String> capabilities = const ['terminal-session'],
        List<String> permissions = const ['own-session-input-output']}) =>
    DiscoveredPackage(
      packageName: pkg,
      serviceClass: 'example.shun.hello.HelloProviderService',
      versionName: '0.1.0',
      versionCode: 1,
      signers: [(sha256: author, androidDebug: false)],
      descriptorJson: jsonEncode({
        'schemaVersion': 1,
        'pluginId': 'example.hello_terminal',
        'displayName': 'Hello 终端（样例）',
        'version': '0.1.0',
        'apiMajor': 1,
        'apiMinor': 0,
        'deployment': 'android-service',
        'capabilities': capabilities,
        'supportedRoutes': ['system-default'],
        'platforms': ['android'],
        'permissions': permissions,
        'packageName': pkg,
        'serviceClass': 'example.shun.hello.HelloProviderService',
        'license': 'GPL-3.0-or-later',
      }),
    );

class FakeBridge extends AndroidPluginBridge {
  var installed = <DiscoveredPackage>[];
  final opened = <({String handle, int generation, int cols, int rows})>[];
  final writes = <String>[];
  final resizes = <String>[];
  final closed = <String>[];
  final disconnects = <String>[];
  PluginBridgeException? connectError;
  PluginBridgeException? openError;
  final _data = StreamController<SessionDataEvent>.broadcast(sync: true);
  final _events = StreamController<SessionBridgeEvent>.broadcast(sync: true);
  final _changes = StreamController<PackageChange>.broadcast(sync: true);

  void event(int sequence, String state) {
    final s = opened.last;
    _events.add(SessionBridgeEvent(
      type: 'sessionEvent',
      packageName: pkg,
      handle: s.handle,
      generation: s.generation,
      sequence: sequence,
      state: state,
    ));
  }

  void data(String text) {
    final s = opened.last;
    _data.add(SessionDataEvent(
        pkg, s.handle, s.generation, Uint8List.fromList(utf8.encode(text))));
  }

  @override
  bool get supported => true;
  @override
  Stream<PackageChange> get packageChanges => _changes.stream;
  @override
  Stream<SessionDataEvent> get sessionData => _data.stream;
  @override
  Stream<SessionBridgeEvent> get sessionEvents => _events.stream;
  @override
  Future<List<DiscoveredPackage>> discover() async => installed;
  @override
  Future<List<({String sha256, bool androidDebug})>> hostSigners() async =>
      [(sha256: hostDebug, androidDebug: true)];
  @override
  Future<String> connect({
    required String packageName,
    required String serviceClass,
    required String pluginId,
    required String sha256,
  }) async {
    if (connectError != null) throw connectError!;
    connects.add(packageName);
    connected.add(packageName);
    return '';
  }

  /// 和 Kotlin 桥一样：没连着的插件 ping 报 NOT_CONNECTED。
  final connected = <String>{};
  final connects = <String>[];

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
  Future<void> openSession({
    required String packageName,
    required String handle,
    required int generation,
    required int cols,
    required int rows,
    String? moshHost,
    int? moshPort,
    Uint8List? moshKey,
  }) async {
    if (openError != null) throw openError!;
    opened
        .add((handle: handle, generation: generation, cols: cols, rows: rows));
  }

  @override
  Future<void> writeSession(String packageName, String handle, int generation,
          Uint8List bytes) async =>
      writes.add(utf8.decode(bytes));
  @override
  Future<void> resizeSession(String packageName, String handle, int generation,
          int cols, int rows) async =>
      resizes.add('${cols}x$rows');
  @override
  Future<bool> closeSession(
      String packageName, String handle, int generation) async {
    closed.add(handle);
    return true;
  }

  @override
  Future<void> ackSession(
      String packageName, String handle, int generation) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBridge bridge;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bridge = FakeBridge()..installed = [hello()];
  });

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  Future<void> openList(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [androidPluginBridgeProvider.overrideWithValue(bridge)],
      child: const MaterialApp(home: PluginsScreen()),
    ));
    await tester.pumpAndSettle();
  }

  /// 列表 → 详情 → 批准 → 会话测试页 → 开始。
  Future<void> startTest(WidgetTester tester) async {
    await openList(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-entry-$pkg')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'plugin-approve');
    await tapKey(tester, 'plugin-approve-confirm');
    await tapKey(tester, 'plugin-session-test');
    await tapKey(tester, 'session-test-start');
  }

  /// 关会话时宿主最多等插件确认 2 秒（PluginTerminalSession.closeConfirmWindow），那个计时器要走完。
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  String output(WidgetTester tester) => tester
      .widget<SelectableText>(find.byKey(const ValueKey('session-test-output')))
      .data!;

  testWidgets('插件页底部给作者看本 App 的证书和插件 API 版本', (tester) async {
    await openList(tester);
    expect(find.text('给插件作者'), findsOneWidget);
    expect(find.text('本 App 的插件 API：1.0'), findsOneWidget);
    expect(find.text(hostDebug), findsOneWidget);
    expect(find.textContaining('这是 Android 调试证书：换一台电脑构建'), findsOneWidget);
  });

  testWidgets('会话测试：只对可用的、声明了终端会话的插件；待批准时没有入口', (tester) async {
    bridge.installed = [
      hello(capabilities: ['device-catalog'])
    ];
    await openList(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-entry-$pkg')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plugin-session-test')), findsNothing);
    await tapKey(tester, 'plugin-approve');
    await tapKey(tester, 'plugin-approve-confirm');
    expect(find.byKey(const ValueKey('plugin-session-test')), findsNothing);
  });

  testWidgets('会话测试走完一遍：连接、打开、看输出、发一行、改尺寸、关闭，每一步照实写', (tester) async {
    await startTest(tester);
    expect(find.textContaining('连接：${PluginDiscovery.checkPassed}'),
        findsOneWidget);
    expect(bridge.opened.single.cols, 80);
    expect(bridge.opened.single.rows, 24);
    expect(find.textContaining('打开会话：80×24，代次 '), findsOneWidget);

    bridge
      ..event(1, 'active')
      ..data('Hello\r\n\x1b[1mhi\x1b[0m\nx');
    await tester.pumpAndSettle();
    expect(find.textContaining('插件回报：运行中（active）'), findsOneWidget);
    // \r\n 是换行；只有 \n 的标出 ^J（真终端上不回行首）；ESC 写成 ^[。
    expect(output(tester), 'Hello\n^[[1mhi^[[0m^J\nx');

    await tester.enterText(
        find.byKey(const ValueKey('session-test-input')), 'help');
    await tapKey(tester, 'session-test-send');
    expect(bridge.writes, ['help\r']);
    expect(find.textContaining('内容：help^M'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-test-resize')));
    await tester.pump();
    expect(bridge.resizes, ['100x30']);
    bridge.event(2, 'resized:100x30');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.textContaining('插件确认尺寸 100x30'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-test-close')));
    await tester.pump();
    expect(bridge.closed, [bridge.opened.single.handle]);
    bridge.event(3, 'closed');
    await tester.pumpAndSettle();
    expect(find.textContaining('已关闭：插件确认已停止（closed）'), findsOneWidget);
    expect(find.byKey(const ValueKey('session-test-send')), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('session-test-send')))
            .onPressed,
        isNull);
    await drain(tester);
  });

  testWidgets('插件自己结束会话、插件不回报 resized、插件不确认关闭：分别如实写', (tester) async {
    await startTest(tester);
    bridge.event(1, 'active');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('session-test-resize')));
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('2 秒内没收到插件的 resized 回报'), findsOneWidget);

    bridge.event(2, 'closed');
    await tester.pumpAndSettle();
    expect(find.textContaining('已关闭：插件自己结束了会话（closed）'), findsOneWidget);

    // 重新开始一个，这次插件不理关闭。
    await tapKey(tester, 'session-test-start');
    expect(bridge.opened, hasLength(2));
    bridge.event(1, 'active');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-test-close')));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('已关闭：2 秒内没等到插件确认（停止未确认）'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('插件拒绝宿主版本、拒绝开会话：停在那一步，原话照写', (tester) async {
    bridge.connectError = const PluginBridgeException(
        'HANDSHAKE_FAILED', '插件不接受宿主的 API 版本：本插件要求宿主 API 1.1 及以上，宿主是 1.0');
    await startTest(tester);
    expect(
        find.textContaining(
            '连接：连接失败：插件不接受宿主的 API 版本：本插件要求宿主 API 1.1 及以上，宿主是 1.0'),
        findsOneWidget);
    expect(bridge.opened, isEmpty);

    bridge
      ..connectError = null
      ..openError = const PluginBridgeException('REFUSED',
          '插件出错：UnsupportedOperationException Mosh 会话要用 openMoshSession 带上 bootstrap 材料');
    await tapKey(tester, 'session-test-start');
    expect(find.textContaining('打开会话失败：插件出错：UnsupportedOperationException'),
        findsOneWidget);
  });

  testWidgets('离开会话测试页：先关测试会话，等插件确认了再断开连接', (tester) async {
    await startTest(tester);
    bridge.event(1, 'active');
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(bridge.closed, [bridge.opened.single.handle]);
    // 先断开的话，插件随后的 closed 会被当成「连接已关闭」丢掉（模拟器上看到过）。
    expect(bridge.disconnects, isEmpty);
    bridge.event(2, 'closed');
    await tester.pumpAndSettle();
    expect(bridge.disconnects, [pkg]);
    await drain(tester);
  });

  testWidgets('英文界面：会话测试页和插件页底部没有汉字', (tester) async {
    ShunLocalizations.use('en');
    addTearDown(() => ShunLocalizations.use('zh'));
    await startTest(tester);
    bridge
      ..event(1, 'active')
      ..data('ok');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-test-close')));
    await tester.pump();
    bridge.event(2, 'closed');
    await tester.pumpAndSettle();
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .followedBy(tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((t) => t.data ?? ''))
        // 标题里有插件自己起的名字（中文），不算本 App 的文案。
        .where((t) => !t.contains('Hello 终端'))
        .join('\n');
    expect(RegExp(r'[一-鿿]').hasMatch(text), isFalse, reason: text);
    expect(text, contains('Closed: the plugin confirmed it stopped (closed)'));
    await drain(tester);
  });

  testWidgets('申请了临时会话凭据的插件（Mosh 那种）：不给会话测试，写明为什么，一个会话都不开', (tester) async {
    bridge.installed = [
      hello(permissions: [
        'own-session-input-output',
        'own-session-ephemeral-secret',
      ])
    ];
    await openList(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-entry-$pkg')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'plugin-approve');
    await tapKey(tester, 'plugin-approve-confirm');
    expect(find.byKey(const ValueKey('plugin-session-test')), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('plugin-session-test-unavailable')),
            matching: find.textContaining('会话测试拿不出这些材料')),
        findsOneWidget);

    // 直接进测试页也开不了。
    unawaited(Navigator.of(
            tester.element(find.byKey(const ValueKey('plugin-status'))))
        .push(MaterialPageRoute<void>(
            builder: (_) => const PluginSessionTestScreen(packageName: pkg))));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('session-test-unavailable')), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('session-test-start')))
            .onPressed,
        isNull);
    expect(bridge.opened, isEmpty);
    expect(bridge.connects, isEmpty);
  });

  testWidgets('已经连着（比如 Mosh 标签在用）：会话测试沿用那条连接、不重新握手，离开时也不断开', (tester) async {
    bridge.connected.add(pkg);
    await startTest(tester);
    expect(find.textContaining('连接：${PluginDiscovery.checkReused}'),
        findsOneWidget);
    expect(bridge.connects, isEmpty);
    bridge.event(1, 'active');
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(bridge.closed, [bridge.opened.single.handle]);
    bridge.event(2, 'closed');
    await drain(tester);
    expect(bridge.disconnects, isEmpty);
  });

  testWidgets('X09 的坑：有会话在跑时点「连接测试」沿用连接，不给「断开」，离开详情页也不断开', (tester) async {
    await openList(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-entry-$pkg')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'plugin-approve');
    await tapKey(tester, 'plugin-approve-confirm');

    // 像 Mosh 标签那样，别处已经连上插件、开了一个会话。
    final container = ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('plugin-status'))));
    final entry = container
        .read(pluginRegistryProvider)
        .singleWhere((e) => e.packageName == pkg);
    bridge.connected.add(pkg);
    final running =
        await container.read(pluginSessionManagerProvider).open(entry);
    bridge.event(1, 'active');

    await tapKey(tester, 'plugin-check');
    expect(find.text(PluginDiscovery.checkReused), findsOneWidget);
    expect(bridge.connects, isEmpty);
    expect(find.text('断开'), findsNothing);
    expect(find.byKey(const ValueKey('plugin-live-sessions')), findsOneWidget);
    expect(running.phase, SessionPhase.active);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(bridge.disconnects, isEmpty);
    expect(running.phase, SessionPhase.active);
    unawaited(running.close());
    await tester.pump();
    bridge.event(2, 'closed');
    await drain(tester);
  });

  testWidgets('没连着时连接测试新开连接：给「断开」，离开详情页断开它', (tester) async {
    await openList(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-entry-$pkg')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'plugin-approve');
    await tapKey(tester, 'plugin-approve-confirm');
    await tapKey(tester, 'plugin-check');
    expect(find.text(PluginDiscovery.checkPassed), findsOneWidget);
    expect(bridge.connects, [pkg]);
    expect(find.text('断开'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(bridge.disconnects, [pkg]);
  });

  test('输出显示：\\r\\n 换行，单独的 \\n、\\r 和别的控制字符写成 ^X', () {
    expect(PluginSessionTestScreen.render(utf8.encode('a\r\nb\nc\rd\x07\x7f中')),
        'a\nb^J\nc^Md^G^?中');
  });
}
