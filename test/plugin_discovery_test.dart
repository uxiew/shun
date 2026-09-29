import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/plugin_discovery.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/domain/plugins/builtin_plugins.dart';
import 'package:netcatty_mobile/infrastructure/plugins/android_plugin_bridge.dart';
import 'package:netcatty_mobile/infrastructure/plugins/plugin_approval_store.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

// X02 的 Dart 侧：Android 桥报告的事实（包、服务类、证书、调试证书、平台问题）怎么变成准入状态，
// 批准记录怎么存、怎么在重启后恢复，连接测试什么时候才会真的去绑定。
// 桥是假的——真实的 PackageManager、Binder 与签名核对在模拟器上验证，见 evidence/X02.md。

const echoPackage = 'example.xwshun.fixture.echo';
const echoService = 'example.xwshun.fixture.echo.EchoProviderService';
const authorCert =
    'ffb53d5ae3ef071d73b680c14c219c0662df7545a87e6042991ab11c862c52fe';
const impostorCert =
    'e257e747678f3ce38aa6fa1878c87a8f26dd7d9503ac8da3289d598fb472397f';
const debugCert =
    '499ff3abf2d0aeb386ce3b30da1c3a0fa3566d5d89b042bf279c0773f79d500f';

String descriptor({
  String id = 'example.fixture_echo',
  String package = echoPackage,
  String service = echoService,
}) =>
    jsonEncode({
      'schemaVersion': 1,
      'pluginId': id,
      'displayName': 'Echo fixture (test only)',
      'version': '0.1.0',
      'apiMajor': 1,
      'apiMinor': 0,
      'deployment': 'android-service',
      'capabilities': ['terminal-session'],
      'supportedRoutes': ['system-default'],
      'platforms': ['android'],
      'permissions': ['own-session-input-output'],
      'packageName': package,
      'serviceClass': service,
    });

DiscoveredPackage echo({
  String cert = authorCert,
  bool debug = false,
  String? json,
  String service = echoService,
  String? problem,
  List<String>? certs,
}) =>
    DiscoveredPackage(
      packageName: echoPackage,
      serviceClass: service,
      descriptorJson: json ?? descriptor(),
      problem: problem,
      signers: [
        for (final c in certs ?? [cert]) (sha256: c, androidDebug: debug),
      ],
    );

class FakeBridge extends AndroidPluginBridge {
  var installed = <DiscoveredPackage>[];
  final connects = <String>[];
  final disconnects = <String>[];

  @override
  bool get supported => true;

  @override
  Future<List<DiscoveredPackage>> discover() async => installed;

  @override
  Future<String> connect({
    required String packageName,
    required String serviceClass,
    required String pluginId,
    required String sha256,
  }) async {
    connects.add('$packageName/$serviceClass/$pluginId/$sha256');
    return descriptor();
  }

  @override
  Future<int> ping(String packageName, int nonce) async => nonce;

  @override
  Future<void> disconnect(String packageName) async =>
      disconnects.add(packageName);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBridge bridge;
  late SharedPreferences prefs;
  late PluginRegistry registry;
  late PluginDiscovery discovery;

  PluginRegistry newRegistry({bool allowDebug = false}) => PluginRegistry(
        policy: AdmissionPolicy(
          builtinIds: BuiltinPlugins.ids,
          allowDebugSigners: allowDebug,
        ),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    bridge = FakeBridge();
    registry = newRegistry();
    discovery = PluginDiscovery(bridge, PluginApprovalStore(prefs), registry);
  });

  PluginEntry entryOf(String package, [PluginRegistry? r]) =>
      (r ?? registry).entries.singleWhere((e) => e.packageName == package);

  test('PLG15 独立作者签名：先待批准，连接测试不绑定；批准后可用，绑定用的是批准时那张证书', () async {
    bridge.installed = [echo()];
    await discovery.refresh();
    expect(entryOf(echoPackage).status, PluginStatus.needsApproval);

    final refused = await discovery.check(entryOf(echoPackage));
    expect(refused, contains('没有绑定插件'));
    expect(bridge.connects, isEmpty);

    await discovery.approve(entryOf(echoPackage));
    expect(entryOf(echoPackage).status, PluginStatus.ready);
    final ok = await discovery.check(entryOf(echoPackage));
    expect(ok, contains('握手成功'));
    expect(bridge.connects, [
      '$echoPackage/$echoService/example.fixture_echo/$authorCert',
    ]);
  });

  test('批准记录重启后恢复；存的是公开的证书摘要，不是插件自报的任何东西', () async {
    bridge.installed = [echo()];
    await discovery.refresh();
    await discovery.approve(entryOf(echoPackage));

    final restarted = newRegistry();
    await PluginDiscovery(bridge, PluginApprovalStore(prefs), restarted)
        .refresh();
    expect(entryOf(echoPackage, restarted).status, PluginStatus.ready);
    final stored = prefs.getString('xwshun.plugins.approvals.v1')!;
    expect(stored, contains(authorCert));
    expect(stored, contains('"packageName":"$echoPackage"'));
  });

  test('PLG04 批准后同包名换了签名：拒绝，连接测试不去绑定', () async {
    bridge.installed = [echo()];
    await discovery.refresh();
    await discovery.approve(entryOf(echoPackage));

    bridge.installed = [echo(cert: impostorCert)];
    await discovery.refresh();
    expect(entryOf(echoPackage).status, PluginStatus.rejected);
    await discovery.check(entryOf(echoPackage));
    expect(bridge.connects, isEmpty);
  });

  test('PLG04 冒用内置 ID 的包：拒绝，内置 SSH 不受影响', () async {
    bridge.installed = [
      DiscoveredPackage(
        packageName: 'example.xwshun.fixture.rogue',
        serviceClass: 'example.xwshun.fixture.rogue.RogueProviderService',
        descriptorJson: descriptor(
          id: 'builtin.ssh',
          package: 'example.xwshun.fixture.rogue',
          service: 'example.xwshun.fixture.rogue.RogueProviderService',
        ),
        signers: const [(sha256: impostorCert, androidDebug: false)],
      ),
    ];
    await discovery.refresh();
    expect(
      entryOf('example.xwshun.fixture.rogue').status,
      PluginStatus.rejected,
    );
    expect(registry.readyEntry(BuiltinPlugins.ssh)!.isBuiltin, isTrue);
  });

  test('PLG15 Android 调试证书：release 口径直接拒绝；开发构建才进入待批准', () async {
    bridge.installed = [echo(cert: debugCert, debug: true)];
    await discovery.refresh();
    expect(entryOf(echoPackage).status, PluginStatus.rejected);
    expect(entryOf(echoPackage).androidDebugSigned, isTrue);

    final dev = newRegistry(allowDebug: true);
    await PluginDiscovery(bridge, PluginApprovalStore(prefs), dev).refresh();
    expect(entryOf(echoPackage, dev).status, PluginStatus.needsApproval);
  });

  test('描述符自称的服务类与实际声明 action 的不同、平台报告的问题：不兼容', () async {
    bridge.installed = [echo(service: 'example.Other')];
    await discovery.refresh();
    expect(entryOf(echoPackage).status, PluginStatus.incompatible);

    bridge.installed = [echo(problem: '一个安装包声明了 2 个插件服务，只允许一个')];
    await discovery.refresh();
    expect(entryOf(echoPackage).status, PluginStatus.incompatible);
    expect(entryOf(echoPackage).reason, contains('只允许一个'));
  });

  test('多张证书共同签名：不给批准（批准记录只绑一张证书，不放宽）', () async {
    bridge.installed = [
      echo(certs: [authorCert, impostorCert])
    ];
    await discovery.refresh();
    await expectLater(
      discovery.approve(entryOf(echoPackage)),
      throwsA(isA<PluginApprovalRefused>()),
    );
    expect(prefs.getString('xwshun.plugins.approvals.v1'), isNull);
  });

  test('卸载：条目变已卸载、批准记录保留；装回同一证书的包直接恢复可用', () async {
    bridge.installed = [echo()];
    await discovery.refresh();
    await discovery.approve(entryOf(echoPackage));

    bridge.installed = [];
    await discovery.refresh();
    expect(entryOf(echoPackage).status, PluginStatus.missing);

    bridge.installed = [echo()];
    await discovery.refresh();
    expect(entryOf(echoPackage).status, PluginStatus.ready);
  });

  test('撤销：删掉批准记录、断开连接，回到待批准', () async {
    bridge.installed = [echo()];
    await discovery.refresh();
    await discovery.approve(entryOf(echoPackage));
    await discovery.revoke(entryOf(echoPackage));
    expect(entryOf(echoPackage).status, PluginStatus.needsApproval);
    expect(bridge.disconnects, [echoPackage]);
    expect(PluginApprovalStore(prefs).load(), isEmpty);
  });

  test('批准记录损坏或含不认识的能力：当作没批准过，不猜', () async {
    await prefs.setString('xwshun.plugins.approvals.v1', '{broken');
    expect(PluginApprovalStore(prefs).load(), isEmpty);
    await prefs.setString(
      'xwshun.plugins.approvals.v1',
      jsonEncode([
        {
          'pluginId': 'example.fixture_echo',
          'packageName': echoPackage,
          'signingDigest': authorCert,
          'capabilities': ['terminal-session', 'read-everything'],
        },
      ]),
    );
    expect(PluginApprovalStore(prefs).load(), isEmpty);
  });
}
