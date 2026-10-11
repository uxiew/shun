import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/plugin_discovery.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/domain/plugins/builtin_plugins.dart';
import 'package:shun/infrastructure/plugins/android_plugin_bridge.dart';
import 'package:shun/infrastructure/plugins/plugin_approval_store.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

// X02 的 Dart 侧：Android 桥报告的事实（包、服务类、证书、调试证书、平台问题）怎么变成准入状态，
// 批准记录怎么存、怎么在重启后恢复，连接测试什么时候才会真的去绑定。
// 桥是假的——真实的 PackageManager、Binder 与签名核对在模拟器上验证，见 evidence/X02.md。

const echoPackage = 'example.shun.fixture.echo';
const echoService = 'example.shun.fixture.echo.EchoProviderService';
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
  String version = '0.1.0',
  int apiMajor = 1,
  List<String> capabilities = const ['terminal-session'],
}) =>
    jsonEncode({
      'schemaVersion': 1,
      'pluginId': id,
      'displayName': 'Echo fixture (test only)',
      'version': version,
      'apiMajor': apiMajor,
      'apiMinor': 0,
      'deployment': 'android-service',
      'capabilities': capabilities,
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
  String? settings = 'example.shun.fixture.echo.SettingsActivity',
  int versionCode = 1,
}) =>
    DiscoveredPackage(
      packageName: echoPackage,
      serviceClass: service,
      descriptorJson: json ?? descriptor(),
      problem: problem,
      settingsActivity: settings,
      versionCode: versionCode,
      signers: [
        for (final c in certs ?? [cert]) (sha256: c, androidDebug: debug),
      ],
    );

class FakeBridge extends AndroidPluginBridge {
  var installed = <DiscoveredPackage>[];
  final connects = <String>[];
  final disconnects = <String>[];
  final settingsOpened = <String>[];
  final changes = StreamController<PackageChange>.broadcast(sync: true);
  var discovers = 0;

  @override
  Stream<PackageChange> get packageChanges => changes.stream;

  @override
  Future<void> openSettings(String packageName, String activity) async =>
      settingsOpened.add('$packageName/$activity');

  @override
  bool get supported => true;

  @override
  Future<List<DiscoveredPackage>> discover() async {
    discovers++;
    await Future<void>.delayed(Duration.zero);
    return installed;
  }

  @override
  Future<String> connect({
    required String packageName,
    required String serviceClass,
    required String pluginId,
    required String sha256,
  }) async {
    connects.add('$packageName/$serviceClass/$pluginId/$sha256');
    connected.add(packageName);
    return descriptor();
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
    expect(refused.ok, isFalse);
    expect(refused.message, contains('没有绑定插件'));
    expect(bridge.connects, isEmpty);

    await discovery.approve(entryOf(echoPackage));
    expect(entryOf(echoPackage).status, PluginStatus.ready);
    final ok = await discovery.check(entryOf(echoPackage));
    expect(ok.message, contains('握手成功'));
    expect(ok.reused, isFalse);
    expect(bridge.connects, [
      '$echoPackage/$echoService/example.fixture_echo/$authorCert',
    ]);
  });

  test('X09 的坑：已经连着（比如 Mosh 标签在用）就沿用，不重新 connect——重新 connect 会断掉它的会话',
      () async {
    bridge.installed = [echo()];
    await discovery.refresh();
    await discovery.approve(entryOf(echoPackage));
    bridge.connected.add(echoPackage); // 别处（Mosh 连接、会话测试）已经连上了

    final result = await discovery.check(entryOf(echoPackage));
    expect(result.ok, isTrue);
    expect(result.reused, isTrue);
    expect(result.message, PluginDiscovery.checkReused);
    expect(bridge.connects, isEmpty);
    expect(bridge.disconnects, isEmpty);

    // 那条连接没了（插件进程死了、被断开）：照常重新握手。
    bridge.connected.clear();
    final again = await discovery.check(entryOf(echoPackage));
    expect(again.reused, isFalse);
    expect(again.message, PluginDiscovery.checkPassed);
    expect(bridge.connects, hasLength(1));
  });

  test('批准记录重启后恢复；存的是公开的证书摘要，不是插件自报的任何东西', () async {
    bridge.installed = [echo()];
    await discovery.refresh();
    await discovery.approve(entryOf(echoPackage));

    final restarted = newRegistry();
    await PluginDiscovery(bridge, PluginApprovalStore(prefs), restarted)
        .refresh();
    expect(entryOf(echoPackage, restarted).status, PluginStatus.ready);
    final stored = prefs.getString('shun.plugins.approvals.v1')!;
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

    // 作者真换了密钥：用户撤销旧批准后回到待批准，可以按新证书重新核对。
    expect(entryOf(echoPackage).hasApproval, isTrue);
    await discovery.revoke(entryOf(echoPackage));
    expect(entryOf(echoPackage).status, PluginStatus.needsApproval);
    expect(entryOf(echoPackage).hasApproval, isFalse);
  });

  test('PLG04 冒用内置 ID 的包：拒绝，内置 SSH 不受影响', () async {
    bridge.installed = [
      DiscoveredPackage(
        packageName: 'example.shun.fixture.rogue',
        serviceClass: 'example.shun.fixture.rogue.RogueProviderService',
        descriptorJson: descriptor(
          id: 'builtin.ssh',
          package: 'example.shun.fixture.rogue',
          service: 'example.shun.fixture.rogue.RogueProviderService',
        ),
        signers: const [(sha256: impostorCert, androidDebug: false)],
      ),
    ];
    await discovery.refresh();
    expect(
      entryOf('example.shun.fixture.rogue').status,
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
    expect(prefs.getString('shun.plugins.approvals.v1'), isNull);
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
    await prefs.setString('shun.plugins.approvals.v1', '{broken');
    expect(PluginApprovalStore(prefs).load(), isEmpty);
    await prefs.setString(
      'shun.plugins.approvals.v1',
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

  group('X04 包变化后重新核验，不沿用旧判定、不自动重新批准（PLG11）', () {
    Future<List<String>> approvedAndTrack() async {
      bridge.installed = [echo()];
      await discovery.start();
      await discovery.approve(entryOf(echoPackage));
      final notices = <String>[];
      discovery.notices.listen(notices.add);
      return notices;
    }

    Future<void> change(String action, {bool replacing = false}) async {
      bridge.changes
          .add(PackageChange(echoPackage, action, replacing: replacing));
      await pumpEventQueue();
    }

    test('同证书同能力的普通更新：仍可用；旧连接断开；给出提示', () async {
      final notices = await approvedAndTrack();
      bridge.installed = [
        echo(json: descriptor(version: '0.2.0'), versionCode: 2),
      ];
      await change('removed', replacing: true);
      expect(entryOf(echoPackage).installedVersionCode, 1); // 更新中途的「移除」不当卸载
      await change('added', replacing: true);
      await change('replaced', replacing: true);
      final entry = entryOf(echoPackage);
      expect(entry.status, PluginStatus.ready);
      expect(entry.descriptor!.version, '0.2.0');
      expect(entry.installedVersionCode, 2);
      expect(bridge.disconnects, contains(echoPackage));
      expect(notices.last, contains('检测到插件包更新'));
    });

    test('更新后多申请了能力：回到待批准，不自动扩大批准', () async {
      await approvedAndTrack();
      bridge.installed = [
        echo(
          json: descriptor(
            version: '0.3.0',
            capabilities: ['terminal-session', 'remote-desktop-external'],
          ),
          versionCode: 3,
        ),
      ];
      await change('replaced', replacing: true);
      expect(entryOf(echoPackage).status, PluginStatus.needsApproval);
      expect(
        PluginApprovalStore(prefs).load().single.capabilities,
        {Capability.terminalSession},
      );
    });

    test('更新后 API major 变了：不兼容，不能用', () async {
      await approvedAndTrack();
      bridge.installed = [echo(json: descriptor(apiMajor: 2), versionCode: 4)];
      await change('replaced', replacing: true);
      expect(entryOf(echoPackage).status, PluginStatus.incompatible);
    });

    test('卸载后换了签名的同名包装回来：拒绝；原批准不转移给它', () async {
      final notices = await approvedAndTrack();
      bridge.installed = [];
      await change('removed');
      expect(entryOf(echoPackage).status, PluginStatus.missing);
      expect(notices.last, contains('检测到插件包卸载'));
      bridge.installed = [echo(cert: impostorCert)];
      await change('added');
      expect(entryOf(echoPackage).status, PluginStatus.rejected);
      expect(
          PluginApprovalStore(prefs).load().single.signingDigest, authorCert);
    });

    test('卸载后装回同一证书的包：直接恢复可用，不用重新批准', () async {
      await approvedAndTrack();
      bridge.installed = [];
      await change('removed');
      bridge.installed = [echo()];
      await change('added');
      expect(entryOf(echoPackage).status, PluginStatus.ready);
    });

    test('不是插件的包变了：什么都不提示', () async {
      final notices = await approvedAndTrack();
      bridge.changes.add(const PackageChange('com.example.other', 'added'));
      await pumpEventQueue();
      expect(notices, isEmpty);
    });

    test('确认框开着时包被换了（证书或版本变了）：拒绝批准，让用户重新核对', () async {
      bridge.installed = [echo()];
      await discovery.start();
      final shown = entryOf(echoPackage);
      bridge.installed = [
        echo(json: descriptor(version: '0.2.0'), versionCode: 2)
      ];
      await expectLater(
        discovery.approve(shown),
        throwsA(isA<PluginApprovalRefused>()
            .having((e) => e.message, 'message', contains('确认期间插件有变化'))),
      );
      expect(entryOf(echoPackage).status, PluginStatus.needsApproval);
      expect(PluginApprovalStore(prefs).load(), isEmpty);
    });

    test('并发的重新发现合并成串行重跑，不会用旧列表把新装的包标成卸载', () async {
      bridge.installed = [echo()];
      final a = discovery.refresh();
      final b = discovery.refresh();
      final c = discovery.refresh();
      await Future.wait([a, b, c]);
      expect(bridge.discovers, 2);
      expect(entryOf(echoPackage).status, PluginStatus.needsApproval);
    });
  });

  group('X04 停用与启用', () {
    test('停用：断开、关会话、重启 App 后仍是停用；启用后直接可用，不用重新批准', () async {
      bridge.installed = [echo()];
      await discovery.start();
      await discovery.approve(entryOf(echoPackage));
      await discovery.disable(entryOf(echoPackage));
      expect(entryOf(echoPackage).status, PluginStatus.disabled);
      expect(bridge.disconnects, [echoPackage]);

      final registry2 = newRegistry();
      final after =
          PluginDiscovery(bridge, PluginApprovalStore(prefs), registry2);
      await after.start();
      expect(entryOf(echoPackage, registry2).status, PluginStatus.disabled);

      await after.enable(entryOf(echoPackage, registry2));
      expect(entryOf(echoPackage, registry2).status, PluginStatus.ready);
      expect(PluginApprovalStore(prefs).loadDisabled(), isEmpty);
    });

    test('撤销批准连停用标记一起清掉：以后重新批准不会莫名处在停用', () async {
      bridge.installed = [echo()];
      await discovery.start();
      await discovery.approve(entryOf(echoPackage));
      await discovery.disable(entryOf(echoPackage));
      await discovery.revoke(entryOf(echoPackage));
      expect(PluginApprovalStore(prefs).loadDisabled(), isEmpty);
      await discovery.approve(entryOf(echoPackage));
      expect(entryOf(echoPackage).status, PluginStatus.ready);
    });

    test('偏好里混进内置 ID 的停用记录：忽略，不让发现失败', () async {
      await PluginApprovalStore(prefs).setDisabled('builtin.ssh', true);
      bridge.installed = [echo()];
      await discovery.start();
      expect(entryOf(echoPackage).status, PluginStatus.needsApproval);
    });
  });

  group('X04 插件自己的设置页（SDK04）', () {
    test('只有可用的插件能打开；待批准、停用的都不碰插件', () async {
      bridge.installed = [echo()];
      await discovery.start();
      await expectLater(discovery.openSettings(entryOf(echoPackage)),
          throwsA(isA<PluginApprovalRefused>()));
      await discovery.approve(entryOf(echoPackage));
      await discovery.openSettings(entryOf(echoPackage));
      expect(bridge.settingsOpened,
          ['$echoPackage/example.shun.fixture.echo.SettingsActivity']);
      await discovery.disable(entryOf(echoPackage));
      await expectLater(discovery.openSettings(entryOf(echoPackage)),
          throwsA(isA<PluginApprovalRefused>()));
      expect(bridge.settingsOpened, hasLength(1));
    });

    test('没有声明设置页的插件：不提供', () async {
      bridge.installed = [echo(settings: null)];
      await discovery.start();
      await discovery.approve(entryOf(echoPackage));
      expect(entryOf(echoPackage).settingsActivity, isNull);
      await expectLater(discovery.openSettings(entryOf(echoPackage)),
          throwsA(isA<PluginApprovalRefused>()));
    });
  });
}
