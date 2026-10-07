import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/plugin_discovery.dart';
import 'package:netcatty_mobile/application/plugin_host_session.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/application/plugin_terminal.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/plugins/plugin_host.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/plugins/android_plugin_bridge.dart';
import 'package:plugin_api/plugin_api.dart'
    show AdmissionPolicy, ApprovedBinding, Capability, SessionPhase;
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/fake_plugin_bridge.dart';

// X12（所有者 10-07 决定）：主机协议选「插件」，用第三方终端插件开标签。
// 插件桥是假的（照 Kotlin 桥的行为），注册表、发现、会话管理、会话控制器都是 App 里真的那一套。
// 真插件在模拟器上从主机列表走一遍，见 evidence/X12.md。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const hello = 'example.xwshun.hello';
  const helloId = 'example.hello_terminal';

  HostProfile pluginHost([Map<String, Object?> extra = const {}]) =>
      HostProfile({
        'id': 'p1',
        'label': 'notes',
        'hostname': '',
        'username': '',
        'port': 22,
        'protocol': 'plugin',
        pluginIdKey: helloId,
        ...extra,
      });
  const socks = {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080};

  group('插件主机的路线：插件自己联网，代理和跳板设置不悄悄去掉', () {
    test('没有代理和跳板：没问题；有就说清楚是哪样、怎么改', () {
      expect(pluginHostRouteProblem(pluginHost()), isNull);
      expect(pluginHostRouteProblem(pluginHost({'proxyConfig': socks})),
          contains('配了代理'));
      expect(
          pluginHostRouteProblem(pluginHost({
            'hostChain': {
              'hostIds': ['j1'],
            },
          })),
          contains('配了跳板机'));
      final both = pluginHostRouteProblem(pluginHost({
        'proxyProfileId': 'pp1',
        'hostChain': {
          'hostIds': ['j1'],
        },
      }))!;
      expect(both, contains('代理和跳板机'));
      expect(both, contains('不会悄悄去掉'));
    });

    test('不给插件主机算路线：算出来就像在说插件会走这条路', () {
      expect(
        () => resolveRoutePlan(pluginHost(),
            hosts: [pluginHost()], proxyProfiles: const []),
        throwsA(isA<RouteConfigException>()),
      );
    });

    test('界面上只写用哪个插件，没有地址', () {
      expect(pluginHostEndpoint(pluginHost()), '插件 $helloId');
    });
  });

  group('会话控制器：插件主机走插件', () {
    const secureStorage =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    late FakePluginBridge bridge;
    late ProviderContainer container;
    late SessionController controller;

    Future<void> install(List<DiscoveredPackageSpec> specs,
        {Set<String> approve = const {}}) async {
      bridge.installed = [for (final s in specs) s.build()];
      final discovery = await container.read(pluginDiscoveryProvider.future);
      await discovery.start();
      for (final package in approve) {
        final entry = container
            .read(pluginRegistryProvider)
            .singleWhere((e) => e.packageName == package);
        await discovery.approve(entry);
      }
    }

    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorage, (call) async => null);
      SharedPreferences.setMockInitialValues({});
      bridge = FakePluginBridge();
      final repository = await VaultRepository.open();
      container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        androidPluginBridgeProvider.overrideWithValue(bridge),
      ]);
      controller = container.read(sessionControllerProvider.notifier);
      await container.read(vaultControllerProvider.notifier).ready();
    });

    tearDown(() => container.dispose());

    Future<bool> accept(HostProfile _, String __, String ___) async => true;

    test('主机上留着代理：一个插件都不碰，失败页说原因', () async {
      await install([const DiscoveredPackageSpec(hello, helloId)],
          approve: {hello});
      await expectLater(
        controller.connect(pluginHost({'proxyConfig': socks}), accept),
        throwsA(isA<PluginHostUnavailable>()),
      );
      expect(bridge.connects, isEmpty);
      expect(bridge.opened, isEmpty);
      final pending = controller.state.pendingConnections.single;
      expect(pending.phase, PendingConnectionPhase.failed);
      expect('${pending.error}', contains('插件主机只能直连'));
    });

    test('插件没批准、要临时凭据、只声明了设备目录：都停在本机这一步，说原因，不去开会话', () async {
      await install([
        const DiscoveredPackageSpec(hello, helloId),
        const DiscoveredPackageSpec('com.x.secret', 'com.x.secret',
            permissions: ['own-session-ephemeral-secret']),
        const DiscoveredPackageSpec('com.x.catalog', 'com.x.catalog',
            capabilities: ['device-catalog']),
      ], approve: {
        'com.x.secret',
        'com.x.catalog'
      });
      final cases = {
        helloId: '还没批准',
        'com.x.secret': '临时凭据',
        'com.x.catalog': '没有声明终端会话能力',
        'com.x.missing': '没有装插件',
      };
      for (final MapEntry(key: id, value: words) in cases.entries) {
        await expectLater(
          controller.connect(pluginHost({pluginIdKey: id}), accept),
          throwsA(isA<PluginHostUnavailable>()
              .having((e) => e.message, 'message', contains(words))),
          reason: id,
        );
      }
      expect(bridge.connects, isEmpty);
      expect(bridge.opened, isEmpty);
    });

    test('连上：80×24 开会话，不带任何主机数据；输入、输出、改尺寸都走插件；插件自己结束后不自动重连', () async {
      await install([const DiscoveredPackageSpec(hello, helloId)],
          approve: {hello});
      expect(
          await controller.connect(
              pluginHost({
                'hostname': 'secret.example.com',
                'username': 'root',
                'password': 'X12-HOST-SECRET',
              }),
              accept),
          isTrue);
      expect(bridge.connects, [hello]);
      expect(bridge.opened.single.cols, 80);
      expect(bridge.opened.single.rows, 24);
      final tab = controller.state.sessions.single;
      final link = tab.plugin! as PluginTerminalProvider;
      expect(link.protocol, 'Hello 终端（样例）');
      expect(tab.isSsh, isFalse);
      bridge.event(1, 'active');
      bridge.data('hello> ');
      await pumpEventQueue();
      expect(tab.terminal.allText(), contains('hello>'));
      tab.terminal.sendText('help\r');
      await pumpEventQueue();
      expect(bridge.writes, ['help\r']);
      expect(bridge.writes.join(), isNot(contains('X12-HOST-SECRET')));

      bridge.data('再见\r\n');
      bridge.event(2, 'closed');
      await pumpEventQueue();
      expect(link.session.phase, SessionPhase.closed);
      expect(tab.connected, isFalse);
      expect(tab.autoRestoreBlocked, isTrue);
      expect(
          tab.terminal.allText().replaceAll('\n', ''), contains('插件结束了这个会话'));
      await controller.reconnectDisconnected();
      await pumpEventQueue();
      expect(bridge.opened, hasLength(1), reason: '不自动重连');
      await controller.close(0);
      expect(controller.state.sessions, isEmpty);
    });

    test('插件已经连着（连接测试、别的标签在用）：沿用那条连接，不重新握手', () async {
      await install([const DiscoveredPackageSpec(hello, helloId)],
          approve: {hello});
      bridge.connected.add(hello);
      expect(await controller.connect(pluginHost(), accept), isTrue);
      expect(bridge.connects, isEmpty);
      expect(bridge.disconnects, isEmpty);
      await controller.close(0);
    });

    test('标签开着时插件被停用：会话关掉、写明原因，不自动拉起', () async {
      await install([const DiscoveredPackageSpec(hello, helloId)],
          approve: {hello});
      expect(await controller.connect(pluginHost(), accept), isTrue);
      final tab = controller.state.sessions.single;
      bridge.event(1, 'active');
      await pumpEventQueue();
      final discovery = await container.read(pluginDiscoveryProvider.future);
      final entry = container
          .read(pluginRegistryProvider)
          .singleWhere((e) => e.packageName == hello);
      await discovery.disable(entry);
      // 注册表先请插件关会话，随即断开连接；插件的确认赶不上，宿主等满 2 秒照实记「没确认」。
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      await pumpEventQueue();
      expect(bridge.closed, [bridge.opened.single.handle]);
      expect(bridge.disconnects, [hello]);
      expect(tab.connected, isFalse);
      expect(tab.terminal.allText().replaceAll('\n', ''),
          contains('本 App 关掉了这个会话（插件被停用、撤销批准或更新）'));
      await expectLater(
        controller.connect(pluginHost(), accept),
        throwsA(isA<PluginHostUnavailable>()
            .having((e) => e.message, 'message', contains('被停用了'))),
      );
      expect(bridge.opened, hasLength(1));
    });
  });

  group('能不能用的判断：连接、编辑器、主机列表共用', () {
    test('同一个 pluginId 一真一假：用可用的那个', () {
      final registry = PluginRegistry(
        policy: AdmissionPolicy(builtinIds: const {}),
      );
      for (final spec in [
        const DiscoveredPackageSpec('com.fake', helloId, cert: 'other'),
        const DiscoveredPackageSpec(hello, helloId),
      ]) {
        final p = spec.build();
        registry.offerInstalled(
          packageName: p.packageName,
          descriptorJson: p.descriptorJson!,
          signerDigests: {p.signers.single.sha256},
          serviceClass: p.serviceClass,
        );
      }
      registry.approve(const ApprovedBinding(
        pluginId: helloId,
        packageName: hello,
        signingDigest: 'author-cert',
        capabilities: {Capability.terminalSession},
      ));
      final result = pluginHostAvailability(registry.entries, helloId);
      expect(result.problem, isNull);
      expect(result.entry!.packageName, hello);
      expect(pluginHostAvailability(registry.entries, null).problem,
          contains('还没选插件'));
    });
  });
}

/// 测试里写安装包的简写。
class DiscoveredPackageSpec {
  const DiscoveredPackageSpec(
    this.package,
    this.pluginId, {
    this.cert = 'author-cert',
    this.capabilities = const ['terminal-session'],
    this.permissions = const ['own-session-input-output'],
  });

  final String package;
  final String pluginId;
  final String cert;
  final List<String> capabilities;
  final List<String> permissions;

  DiscoveredPackage build() => terminalPlugin(
        package: package,
        pluginId: pluginId,
        cert: cert,
        capabilities: capabilities,
        permissions: [
          ...permissions,
          if (permissions.contains('own-session-ephemeral-secret'))
            'own-session-input-output',
        ],
      );
}
