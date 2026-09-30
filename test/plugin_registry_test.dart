import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/domain/device_references.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/plugins/builtin_plugins.dart';
import 'package:plugin_api/plugin_api.dart';

// X01：registry 的运行时装配。准入规则本身由 packages/plugin_api 的契约测试覆盖，
// 这里测的是主 App 里把"装了哪些包、批准过什么、停用了什么"合成状态这一层。
// 没有任何真实 APK：安装包信息是手写的，真实发现与证书读取在 X02。

String descriptor({
  String id = 'example.mosh',
  String package = 'example.terminal.mosh',
  String deployment = 'android-service',
  List<String> capabilities = const ['terminal-session'],
  int apiMajor = 1,
  int apiMinor = 0,
}) =>
    jsonEncode({
      'schemaVersion': 1,
      'pluginId': id,
      'displayName': 'Example',
      'version': '0.1.0',
      'apiMajor': apiMajor,
      'apiMinor': apiMinor,
      'deployment': deployment,
      'capabilities': capabilities,
      'supportedRoutes': ['system-default'],
      'platforms': ['android'],
      'permissions': ['own-session-input-output'],
      'packageName': package,
      if (deployment == 'android-service')
        'serviceClass': '$package.ProviderService',
    });

ApprovedBinding approval({
  String id = 'example.mosh',
  String package = 'example.terminal.mosh',
  String cert = 'author-cert',
  Set<Capability> capabilities = const {Capability.terminalSession},
}) =>
    ApprovedBinding(
      pluginId: id,
      packageName: package,
      signingDigest: cert,
      capabilities: capabilities,
    );

PluginRegistry registry() => PluginRegistry(
      policy: AdmissionPolicy(builtinIds: BuiltinPlugins.ids),
    );

PluginStatus? statusOfPackage(PluginRegistry r, String package) =>
    r.entries.where((e) => e.packageName == package).firstOrNull?.status;

class FakeSession implements PluginSessionHandle {
  FakeSession(this.ref);
  @override
  final SessionKind ref;
  var closeCalls = 0;
  @override
  Future<void> close() async => closeCalls++;
}

TerminalSessionRef terminalOf(String providerId, String handle) =>
    TerminalSessionRef(
      handle,
      providerId,
      const SessionState(1, 0, SessionPhase.active),
    );

void main() {
  group('核心 SSH 不依赖外部插件', () {
    test('一个外部包都没有时，内置 SSH 与路由已是 Ready，可直接取到终端能力', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final r = container.read(pluginRegistryProvider.notifier);
      expect(
        r.require(BuiltinPlugins.ssh, Capability.terminalSession).pluginId,
        BuiltinPlugins.ssh,
      );
      expect(
        r.require(BuiltinPlugins.route, Capability.route).pluginId,
        BuiltinPlugins.route,
      );
      expect(r.entries.every((e) => e.isBuiltin), isTrue);
    });

    test('X05 Tailscale 目录是内置 provider：构造即可用，只有目录能力、只走系统网络', () {
      final r = registry();
      expect(
        r.require(BuiltinPlugins.tailscale, Capability.deviceCatalog).pluginId,
        BuiltinPlugins.tailscale,
      );
      // 目录只列设备：没有终端能力，也就开不了任何会话（发现不等于能连）。
      expect(
        () => r.require(BuiltinPlugins.tailscale, Capability.terminalSession),
        throwsA(isA<UnsupportedCapability>()),
      );
      final d = r.readyEntry(BuiltinPlugins.tailscale)!.descriptor!;
      expect(d.deployment, Deployment.bundled);
      expect(d.supportedRoutes, {RouteSupport.systemDefault});
      expect(d.permissions, {Permission.ownProviderState});
      expect(() => r.disable(BuiltinPlugins.tailscale), throwsArgumentError);
    });

    test('内置 provider 不能被停用，外部包怎样折腾都遮蔽不了它', () {
      final r = registry();
      expect(() => r.disable(BuiltinPlugins.ssh), throwsArgumentError);
      for (final (id, capabilities) in [
        ('builtin.ssh', ['terminal-session']),
        ('BUILTIN.SSH', ['terminal-session']),
        ('builtin.route', ['terminal-session']),
        ('builtin.tailscale', ['device-catalog']),
      ]) {
        r.offerInstalled(
          packageName: 'evil.$id'.toLowerCase(),
          descriptorJson: descriptor(
            id: id.toLowerCase(),
            package: 'evil.$id'.toLowerCase(),
            capabilities: capabilities,
          ),
          signerDigests: {'evil'},
        );
        r.approve(
          approval(
            id: id,
            package: 'evil.$id'.toLowerCase(),
            cert: 'evil',
            capabilities: {
              for (final c in capabilities)
                Capability.values.singleWhere((v) => v.wire == c),
            },
          ),
        );
      }
      expect(r.readyEntry(BuiltinPlugins.ssh)!.isBuiltin, isTrue);
      expect(r.readyEntry(BuiltinPlugins.tailscale)!.isBuiltin, isTrue);
      expect(
        r.entries.where((e) => !e.isBuiltin).map((e) => e.status).toSet(),
        {PluginStatus.rejected},
      );
    });

    test('单独安装的包自称 bundled：拒绝，不跳过批准', () {
      final r = registry()
        ..offerInstalled(
          packageName: 'example.fake',
          descriptorJson: descriptor(
            id: 'example.fake',
            package: 'example.fake',
            deployment: 'bundled',
          ),
          signerDigests: {'x'},
        );
      expect(statusOfPackage(r, 'example.fake'), PluginStatus.rejected);
      expect(
        () => r.require('example.fake', Capability.terminalSession),
        throwsA(isA<PluginUnavailable>()),
      );
    });
  });

  group('PLG01 同 ID / 大小写 / 恶意描述符', () {
    test('没批准前谁都不是 Ready；批准一个后，同 ID 的另一个包被拒，与安装先后无关', () {
      for (final order in [
        ['a.real', 'z.fake'],
        ['z.fake', 'a.real'],
      ]) {
        final r = registry();
        for (final pkg in order) {
          r.offerInstalled(
            packageName: pkg,
            descriptorJson: descriptor(package: pkg),
            signerDigests: {'cert-$pkg'},
          );
        }
        expect(statusOfPackage(r, 'a.real'), PluginStatus.needsApproval);
        expect(statusOfPackage(r, 'z.fake'), PluginStatus.needsApproval);

        // 用户批准的是 z.fake 这个包（不是按字母序先来的那个）。
        r.approve(approval(package: 'z.fake', cert: 'cert-z.fake'));
        expect(statusOfPackage(r, 'z.fake'), PluginStatus.ready,
            reason: '$order');
        expect(statusOfPackage(r, 'a.real'), PluginStatus.rejected,
            reason: '$order');
      }
    });

    test('大小写不同的同一 ID 视为同一个，不能借大小写并存', () {
      final r = registry()
        ..offerInstalled(
          packageName: 'a.one',
          descriptorJson: descriptor(package: 'a.one'),
          signerDigests: {'c1'},
        )
        ..approve(approval(package: 'a.one', cert: 'c1'));
      // pluginId 格式只允许小写，大写 ID 在描述符层直接不合规。
      r.offerInstalled(
        packageName: 'b.two',
        descriptorJson: descriptor(id: 'Example.Mosh', package: 'b.two'),
        signerDigests: {'c2'},
      );
      expect(statusOfPackage(r, 'b.two'), PluginStatus.incompatible);
      // 批准记录里写成大写，也只对应到同一个 provider。
      expect(
        r.require('EXAMPLE.MOSH', Capability.terminalSession).packageName,
        'a.one',
      );
    });

    test('超长、多余字段（exec/intent）、不是 JSON：incompatible，且不影响其他 provider', () {
      final r = registry();
      final exec = (jsonDecode(descriptor(package: 'p.exec')) as Map)
        ..['exec'] = 'sh -c id';
      final bad = {
        'p.long': descriptor(package: 'p.long').replaceFirst(
          '"Example"',
          '"${'x' * 20000}"',
        ),
        'p.exec': jsonEncode(exec),
        'p.junk': '{not json',
      };
      for (final MapEntry(:key, :value) in bad.entries) {
        r.offerInstalled(
          packageName: key,
          descriptorJson: value,
          signerDigests: {'c'},
        );
      }
      for (final pkg in bad.keys) {
        expect(statusOfPackage(r, pkg), PluginStatus.incompatible, reason: pkg);
      }
      expect(r.readyEntry(BuiltinPlugins.ssh), isNotNull);
    });
  });

  group('PLG02 版本与能力', () {
    test('API major 不符：incompatible，不冒充可用', () {
      final r = registry()
        ..offerInstalled(
          packageName: 'example.terminal.mosh',
          descriptorJson: descriptor(apiMajor: 2),
          signerDigests: {'author-cert'},
        )
        ..approve(approval());
      expect(
        statusOfPackage(r, 'example.terminal.mosh'),
        PluginStatus.incompatible,
      );
      expect(
        () => r.require('example.mosh', Capability.terminalSession),
        throwsA(isA<PluginUnavailable>()),
      );
    });

    test('插件 minor 更新、带宿主不认识的能力：忽略该能力，已知能力照常可用', () {
      final r = registry()
        ..offerInstalled(
          packageName: 'example.terminal.mosh',
          descriptorJson: descriptor(
            apiMinor: 3,
            capabilities: ['terminal-session', 'future-thing'],
          ),
          signerDigests: {'author-cert'},
        )
        ..approve(approval());
      final entry = r.readyEntry('example.mosh')!;
      expect(entry.descriptor!.ignoredNewerCapabilities, {'future-thing'});
      expect(
        () => r.require('example.mosh', Capability.terminalSession),
        returnsNormally,
      );
    });

    test('调用没声明的能力抛 UnsupportedCapability，不返回空结果', () {
      final r = registry()
        ..offerInstalled(
          packageName: 'example.terminal.mosh',
          descriptorJson: descriptor(),
          signerDigests: {'author-cert'},
        )
        ..approve(approval());
      expect(
        () => r.require('example.mosh', Capability.deviceCatalog),
        throwsA(isA<UnsupportedCapability>()),
      );
      expect(
        r.readyWith(Capability.deviceCatalog).map((e) => e.pluginId),
        isNot(contains('example.mosh')),
      );
    });

    test('新版本申请了批准之外的能力：退回待批准，旧能力也暂停', () {
      final r = registry()
        ..offerInstalled(
          packageName: 'example.terminal.mosh',
          descriptorJson: descriptor(),
          signerDigests: {'author-cert'},
        )
        ..approve(approval());
      r.offerInstalled(
        packageName: 'example.terminal.mosh',
        descriptorJson: descriptor(
          capabilities: ['terminal-session', 'device-catalog'],
        ),
        signerDigests: {'author-cert'},
      );
      expect(
        statusOfPackage(r, 'example.terminal.mosh'),
        PluginStatus.needsApproval,
      );
    });

    test('更新后换了签名：禁用，旧批准不自动沿用', () {
      final r = registry()
        ..offerInstalled(
          packageName: 'example.terminal.mosh',
          descriptorJson: descriptor(),
          signerDigests: {'author-cert'},
        )
        ..approve(approval());
      r.offerInstalled(
        packageName: 'example.terminal.mosh',
        descriptorJson: descriptor(),
        signerDigests: {'attacker-cert'},
      );
      expect(
        statusOfPackage(r, 'example.terminal.mosh'),
        PluginStatus.rejected,
      );
    });
  });

  group('会话分型：没有所有能力共用的 connected 布尔值', () {
    PluginRegistry withTwoProviders() => registry()
      ..offerInstalled(
        packageName: 'example.terminal.mosh',
        descriptorJson: descriptor(),
        signerDigests: {'author-cert'},
      )
      ..approve(approval())
      ..offerInstalled(
        packageName: 'example.remote',
        descriptorJson: descriptor(
          id: 'example.remote',
          package: 'example.remote',
          capabilities: ['remote-desktop-external'],
        ),
        signerDigests: {'remote-cert'},
      )
      ..approve(
        approval(
          id: 'example.remote',
          package: 'example.remote',
          cert: 'remote-cert',
          capabilities: {Capability.remoteDesktopExternal},
        ),
      );

    test('三类会话各带各的状态；外部拉起只有"已拉起未确认"，没有"已连接"', () {
      final r = withTwoProviders();
      r.attachSession(FakeSession(terminalOf('example.mosh', 'h1')));
      r.attachSession(
        FakeSession(
          const ExternalLaunchAttempt(
            'h2',
            'example.remote',
            SessionState(1, 0, ExternalLaunchPhase.launchedUnverified),
          ),
        ),
      );
      final kinds = r.pluginSessions;
      expect(kinds.whereType<TerminalSessionRef>().single.state.phase,
          SessionPhase.active);
      expect(
        kinds.whereType<ExternalLaunchAttempt>().single.state.phase,
        ExternalLaunchPhase.launchedUnverified,
      );
      expect(
        ExternalLaunchPhase.values.map((p) => p.name),
        isNot(contains(matches(RegExp('connected', caseSensitive: false)))),
      );
    });

    test('provider 没声明对应能力，或不是 Ready：会话登记不上并被立刻关掉', () {
      final r = withTwoProviders();
      final wrongKind = FakeSession(terminalOf('example.remote', 'h1'));
      expect(
        () => r.attachSession(wrongKind),
        throwsA(isA<UnsupportedCapability>()),
      );
      final unknown = FakeSession(terminalOf('example.nothere', 'h2'));
      expect(
        () => r.attachSession(unknown),
        throwsA(isA<PluginUnavailable>()),
      );
      final builtin = FakeSession(terminalOf(BuiltinPlugins.ssh, 'h3'));
      expect(() => r.attachSession(builtin), throwsArgumentError);
      expect(wrongKind.closeCalls + unknown.closeCalls + builtin.closeCalls, 3);
      expect(r.pluginSessions, isEmpty);
    });

    test('停用一个插件只关它自己的会话；另一个插件和内置 SSH 不受影响', () {
      final r = withTwoProviders();
      final mosh = FakeSession(terminalOf('example.mosh', 'h1'));
      final remote = FakeSession(
        const ExternalLaunchAttempt(
          'h2',
          'example.remote',
          SessionState(1, 0, ExternalLaunchPhase.launching),
        ),
      );
      r
        ..attachSession(mosh)
        ..attachSession(remote)
        ..disable('example.mosh');
      expect(mosh.closeCalls, 1);
      expect(remote.closeCalls, 0);
      expect(r.pluginSessions.single.providerId, 'example.remote');
      expect(
          statusOfPackage(r, 'example.terminal.mosh'), PluginStatus.disabled);
      expect(r.readyEntry(BuiltinPlugins.ssh), isNotNull);

      // 重新启用不用再批准；被关掉的会话不会复活。
      r.enable('example.mosh');
      expect(statusOfPackage(r, 'example.terminal.mosh'), PluginStatus.ready);
      expect(r.pluginSessions.single.providerId, 'example.remote');
    });

    test('撤销批准与换签同样关掉会话', () {
      final r = withTwoProviders();
      final a = FakeSession(terminalOf('example.mosh', 'h1'));
      r
        ..attachSession(a)
        ..revoke('example.mosh');
      expect(a.closeCalls, 1);

      r.approve(approval());
      final b = FakeSession(terminalOf('example.mosh', 'h2'));
      r
        ..attachSession(b)
        ..offerInstalled(
          packageName: 'example.terminal.mosh',
          descriptorJson: descriptor(),
          signerDigests: {'attacker-cert'},
        );
      expect(b.closeCalls, 1);
      expect(r.pluginSessions, isEmpty);
    });
  });

  group('DEV01/DEV02 设备引用', () {
    final host = HostProfile({
      'id': 'host-1',
      'label': 'nas',
      'hostname': '100.64.0.7',
      'username': 'me',
      'port': 22,
    });

    test('SSH 主机引用只认主机 id；目录报出同名同 IP 不会合并', () {
      final ssh = hostDeviceRef(host);
      final renamed = hostDeviceRef(
        host.copyWith(label: 'renamed', hostname: '10.0.0.9'),
      );
      expect(ssh, renamed);
      const catalog = ProviderDeviceRef(
        providerId: 'example.catalog',
        refId: 'node-abc',
        displayName: 'nas',
        addresses: ['100.64.0.7'],
      );
      expect(ssh == catalog, isFalse);
      expect(DeviceLinks().recordOf(ssh), isNull);
    });

    test('X05 目录设备引用：身份是（来源 ID，设备 ID），和同名同 IP 的主机、另一个来源都不相等', () {
      final a = catalogDeviceRef('ts-a', 'node-1',
          displayName: 'nas', addresses: ['100.64.0.7']);
      expect(a.providerId, BuiltinPlugins.tailscale);
      expect(catalogRefKey(a), (catalogId: 'ts-a', deviceId: 'node-1'));
      // 两个来源都报出 node-1：各是各的（TSC10）。
      expect(a == catalogDeviceRef('ts-b', 'node-1'), isFalse);
      // 名字、地址只是展示：同来源同 ID 就是同一条引用。
      expect(a == catalogDeviceRef('ts-a', 'node-1', displayName: 'x'), isTrue);
      expect(a == hostDeviceRef(host), isFalse);
      // 设备 ID 里有冒号也不会切错：来源 ID 本身不允许冒号。
      expect(
        catalogRefKey(catalogDeviceRef('ts-a', 'n:1:2')),
        (catalogId: 'ts-a', deviceId: 'n:1:2'),
      );
    });

    test('X05 来源 ID 只有一条规则：拼不出路径、别的键或别的引用', () {
      for (final bad in ['', 'a/b', '../x', 'a.b', 'a:b', 'a b', 'x' * 65]) {
        expect(isValidCatalogId(bad), isFalse, reason: bad);
        expect(() => catalogDeviceRef(bad, 'n'), throwsArgumentError);
      }
      expect(isValidCatalogId('ts-0abc'), isTrue);
      expect(() => catalogDeviceRef('ts-a', ''), throwsArgumentError);
      // 别的 provider 的引用、格式不对的引用都不是目录引用。
      for (final ref in [
        hostDeviceRef(host),
        const ProviderDeviceRef(
          providerId: 'example.catalog',
          refId: 'ts-a:n',
          displayName: 'n',
        ),
        const ProviderDeviceRef(
          providerId: BuiltinPlugins.tailscale,
          refId: 'no-separator',
          displayName: 'n',
        ),
        const ProviderDeviceRef(
          providerId: BuiltinPlugins.tailscale,
          refId: 'bad/id:n',
          displayName: 'n',
        ),
      ]) {
        expect(catalogRefKey(ref), isNull, reason: ref.refId);
      }
    });

    test('移除一个来源插件：只断开它那条关联，SSH 与另一个 provider 的引用、会话都不动', () {
      final r = withCatalogAndRemote();
      final ssh = hostDeviceRef(host);
      const catalog = ProviderDeviceRef(
        providerId: 'example.catalog',
        refId: 'node-abc',
        displayName: 'nas',
      );
      const remote = ProviderDeviceRef(
        providerId: 'example.remote',
        refId: 'peer-1',
        displayName: 'nas',
      );
      final links = DeviceLinks();
      final record = links.linkByUser([ssh, catalog, remote]);
      final remoteSession = FakeSession(
        const ExternalLaunchAttempt(
          'h1',
          'example.remote',
          SessionState(1, 0, ExternalLaunchPhase.launchedUnverified),
        ),
      );
      r.attachSession(remoteSession);

      r.markUninstalled('example.catalog');

      // provider 缺失：引用和关联原样保留，状态可见，等用户决定。
      expect(r.availabilityOf(catalog), DeviceRefAvailability.providerMissing);
      expect(r.availabilityOf(ssh), DeviceRefAvailability.available);
      expect(r.availabilityOf(remote), DeviceRefAvailability.available);
      expect(links.recordOf(catalog)?.id, record.id);
      expect(statusOfPackage(r, 'example.catalog'), PluginStatus.missing);
      expect(remoteSession.closeCalls, 0);

      // 用户选择断开这一条：其余两条仍关联在一起。
      links.unlinkRef(catalog);
      expect(links.recordOf(catalog), isNull);
      expect(links.recordOf(ssh)!.refs, {ssh, remote});

      // 重装同一证书的包：批准仍在，直接恢复可用，不需要重新关联以外的任何修复。
      r.offerInstalled(
        packageName: 'example.catalog',
        descriptorJson: catalogDescriptor,
        signerDigests: {'catalog-cert'},
      );
      expect(r.availabilityOf(catalog), DeviceRefAvailability.available);
    });

    test('只剩一条引用时记录解散，引用本身不删', () {
      final ssh = hostDeviceRef(host);
      const catalog = ProviderDeviceRef(
        providerId: 'example.catalog',
        refId: 'node-abc',
        displayName: 'nas',
      );
      final links = DeviceLinks()..linkByUser([ssh, catalog]);
      links.unlinkRef(catalog);
      expect(links.records, isEmpty);
      expect(hostDeviceRef(host), ssh);
    });

    test('provider 装着但未批准/被停用：providerNotReady，不当作缺失', () {
      final r = registry()
        ..offerInstalled(
          packageName: 'example.catalog',
          descriptorJson: catalogDescriptor,
          signerDigests: {'catalog-cert'},
        );
      const catalog = ProviderDeviceRef(
        providerId: 'example.catalog',
        refId: 'n',
        displayName: 'n',
      );
      expect(r.availabilityOf(catalog), DeviceRefAvailability.providerNotReady);
      r.approve(catalogApproval);
      expect(r.availabilityOf(catalog), DeviceRefAvailability.available);
      r.disable('example.catalog');
      expect(r.availabilityOf(catalog), DeviceRefAvailability.providerNotReady);
    });
  });
}

final catalogDescriptor = descriptor(
  id: 'example.catalog',
  package: 'example.catalog',
  capabilities: ['device-catalog'],
);

final catalogApproval = approval(
  id: 'example.catalog',
  package: 'example.catalog',
  cert: 'catalog-cert',
  capabilities: {Capability.deviceCatalog},
);

PluginRegistry withCatalogAndRemote() => registry()
  ..offerInstalled(
    packageName: 'example.catalog',
    descriptorJson: catalogDescriptor,
    signerDigests: {'catalog-cert'},
  )
  ..approve(catalogApproval)
  ..offerInstalled(
    packageName: 'example.remote',
    descriptorJson: descriptor(
      id: 'example.remote',
      package: 'example.remote',
      capabilities: ['remote-desktop-external'],
    ),
    signerDigests: {'remote-cert'},
  )
  ..approve(
    approval(
      id: 'example.remote',
      package: 'example.remote',
      cert: 'remote-cert',
      capabilities: {Capability.remoteDesktopExternal},
    ),
  );
