import 'remote_entry_fakes.dart';
import 'dart:convert';
import 'package:shun/infrastructure/storage/remote_entry_store.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/device_links.dart';
import 'package:shun/application/external_remote.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/rustdesk.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/application/uuremote.dart';
import 'package:shun/domain/device_references.dart';
import 'package:shun/domain/plugins/builtin_plugins.dart';
import 'package:shun/infrastructure/plugins/rustdesk_external.dart';
import 'package:plugin_api/plugin_api.dart';

import 'rustdesk_fakes.dart';

// X07：RustDesk 关联与发起远控。平台层是假的（记下发出的链接、包名、证书），存储在内存里。
// 证明的是本 App 发什么、发给谁、记成什么；不证明真实 RustDesk 的行为——那要装真实的 RustDesk 和一台被控电脑。

void main() {
  late FakeRustDeskPlatform platform;
  late MemoryRustDeskBackend backend;
  late List<RemoteControlHost> hosts;
  late DateTime clock;
  late RustDeskController c;

  RustDeskController build({PluginRegistry? registry}) => RustDeskController(
        platform: platform,
        store: RustDeskStore(backend),
        registry: registry ??
            PluginRegistry(
              policy: AdmissionPolicy(builtinIds: BuiltinPlugins.ids),
            ),
        hosts: () async => hosts,
        now: () => clock,
      );

  setUp(() async {
    platform = FakeRustDeskPlatform();
    backend = MemoryRustDeskBackend();
    hosts = const [
      RemoteControlHost(
          id: 'h1', label: 'win-pc', sshRoute: RequestedRoute.systemDefault),
      RemoteControlHost(
          id: 'h2', label: 'mac', sshRoute: RequestedRoute.socks5Connect),
      RemoteControlHost(
          id: 'h3', label: 'lab', sshRoute: RequestedRoute.proxyJump),
    ];
    clock = DateTime.utc(2026, 9, 30, 12);
    seedRemoteEntries(backend.values, 'rustdesk', hosts);
    c = build();
    await c.ready;
  });

  tearDown(() => c.dispose());

  group('关联（DEV01）', () {
    test('填 ID 只保存、不发请求；同一台主机再填就是替换', () async {
      await c.saveLink('h1', '123 456 789');
      expect(c.state.linkOf('h1')!.peer.value, '123456789');
      expect(platform.launched, isEmpty);

      final first = c.state.linkOf('h1')!.id;
      clock = clock.add(const Duration(minutes: 1));
      await c.saveLink('h1', 'office-pc');
      expect(c.state.links, hasLength(1));
      expect(c.state.linkOf('h1')!.peer.value, 'office-pc');
      expect(c.state.linkOf('h1')!.id, first);
      expect(platform.launched, isEmpty);
    });

    test('不合规的 ID 不保存；主机不在了也不保存', () async {
      await expectLater(
        c.saveLink('h1', '123456789?password=x'),
        throwsA(isA<RustDeskPeerIdRejected>()),
      );
      await expectLater(
        c.saveLink('gone', '123456789'),
        throwsA(isA<RustDeskRequestRefused>()),
      );
      expect(c.state.links, isEmpty);
      expect(storedField(backend.values, 'rustdesk', 'records'), isEmpty);
    });

    test('两台主机填同一个 RustDesk ID：两条各自独立的关联', () async {
      await c.saveLink('h1', '123456789');
      await c.saveLink('h2', '123456789');
      expect(c.state.links, hasLength(2));
      expect(c.state.links.map((l) => l.id).toSet(), hasLength(2));
      await c.deleteLink(c.state.linkOf('h1')!.id);
      expect(c.state.linkOf('h1'), isNull);
      expect(c.state.linkOf('h2')!.peer.value, '123456789');
    });

    test('重开遇到损坏 ID：阻止整份存储启用，不丢记录也不发链接', () async {
      await c.saveLink('h1', '123456789');
      final stored = storedField(backend.values, 'rustdesk', 'records') as List;
      stored.add({
        'id': 'tampered',
        'hostId': 'h2',
        'peerId': '1?password=x',
        'createdAt': clock.toIso8601String(),
      });
      final snapshot =
          jsonDecode(backend.values['rustdesk.entries.v2']!) as Map;
      snapshot['records'] = stored;
      backend.values['rustdesk.entries.v2'] = jsonEncode(snapshot);

      final reopened = build();
      addTearDown(reopened.dispose);
      await reopened.ready;
      expect(reopened.state.links, isEmpty);
      expect(reopened.state.notice, contains('迁移失败'));
      await expectLater(
          reopened.launch('h2'), throwsA(isA<RemoteEntryStorageException>()));
      expect(platform.launched, isEmpty);
    });

    test('存储坏了：显示失败，禁止写入，不回退', () async {
      backend.values['rustdesk.entries.v2'] = '{not json';
      backend.values['rustdesk.trust.v1'] = '[1,2';
      final reopened = build();
      addTearDown(reopened.dispose);
      await reopened.ready;
      expect(reopened.state.loaded, isTrue);
      expect(reopened.state.links, isEmpty);
      expect(reopened.state.notice, contains('迁移失败'));
    });

    test('SSH、目录设备、UU 绑定、RustDesk 关联聚成一条；引用里没有 RustDesk ID', () async {
      await c.saveLink('h1', '123456789');
      const catalogHosts = [
        CatalogHost(
          id: 'h1',
          label: 'win-pc',
          hostname: '100.64.0.5',
          binding: CatalogBinding(catalogId: 'ts-a', deviceId: 'n1'),
        ),
        CatalogHost(id: 'h2', label: 'win-pc', hostname: '100.64.0.5'),
      ];
      final uu = [
        UuBinding(
          id: 'uu-1',
          hostId: 'h1',
          anonymousDeviceId: 'opaque',
          createdAt: clock,
        ),
      ];
      final link = c.state.linkOf('h1')!;
      final links =
          deviceLinksOf(hosts: catalogHosts, uu: uu, rustdesk: c.state.links);
      expect(links.records.single.refs, {
        sshHostRef('h1', displayName: 'win-pc'),
        catalogDeviceRef('ts-a', 'n1'),
        uuBindingRef('uu-1'),
        rustDeskPeerRef(link.id),
      });
      // 同名同地址的另一台主机没被合进来（DEV01）。
      expect(links.recordOf(sshHostRef('h2', displayName: 'win-pc')), isNull);
      expect(links.records.single.refs.map((r) => r.refId),
          isNot(contains('123456789')));
    });

    test('DEV02：删 RustDesk 关联只断这一条；删 UU 绑定、移除目录来源时 RustDesk 这条还在', () async {
      await c.saveLink('h1', '123456789');
      final link = c.state.linkOf('h1')!;
      const bound = [
        CatalogHost(
          id: 'h1',
          label: 'win-pc',
          hostname: '100.64.0.5',
          binding: CatalogBinding(catalogId: 'ts-a', deviceId: 'n1'),
        ),
      ];
      const unbound = [
        CatalogHost(id: 'h1', label: 'win-pc', hostname: '100.64.0.5'),
      ];
      final uu = [
        UuBinding(
          id: 'uu-1',
          hostId: 'h1',
          anonymousDeviceId: 'opaque',
          createdAt: clock,
        ),
      ];
      final ssh = sshHostRef('h1', displayName: 'win-pc');

      // 移除目录来源（主机上的目录绑定没了）：SSH、UU、RustDesk 仍在一起。
      expect(
        deviceLinksOf(hosts: unbound, uu: uu, rustdesk: c.state.links)
            .records
            .single
            .refs,
        {ssh, uuBindingRef('uu-1'), rustDeskPeerRef(link.id)},
      );
      // 删 UU 绑定：SSH、目录、RustDesk 仍在一起。
      expect(
        deviceLinksOf(hosts: bound, rustdesk: c.state.links)
            .records
            .single
            .refs,
        {ssh, catalogDeviceRef('ts-a', 'n1'), rustDeskPeerRef(link.id)},
      );
      // 只剩 SSH 和 RustDesk 也仍是一条。
      expect(
        deviceLinksOf(hosts: unbound, rustdesk: c.state.links)
            .records
            .single
            .refs,
        {ssh, rustDeskPeerRef(link.id)},
      );
      // 删 RustDesk 关联：别的都不动。
      await c.deleteLink(link.id);
      expect(
        deviceLinksOf(hosts: bound, uu: uu, rustdesk: c.state.links)
            .records
            .single
            .refs,
        {ssh, catalogDeviceRef('ts-a', 'n1'), uuBindingRef('uu-1')},
      );
    });

    test('DEV02：RustDesk 被卸载，关联原样留着；装回来不用重填', () async {
      await c.saveLink('h1', '123456789');
      platform.probeResult = const RustDeskProbe(platformSupported: true);
      await c.refreshApp();
      expect(c.state.app, isA<RustDeskNotInstalled>());
      expect(c.state.linkOf('h1')!.peer.value, '123456789');
      await expectLater(c.launch('h1'), throwsA(isA<RustDeskRequestRefused>()));

      platform.probeResult = RustDeskProbe(
        platformSupported: true,
        handlers: [official()],
        officialInstalled: official(),
      );
      await c.launch('h1');
      expect(platform.launched.single.$1, 'rustdesk://connect/123456789');
    });
  });

  group('RDX02/RDX03 发起', () {
    test('发出的只有 rustdesk://connect/<ID>，发给官方包和它此刻的证书', () async {
      await c.saveLink('h1', '123 456 789');
      await c.launch('h1');
      expect(platform.launched.single, (
        'rustdesk://connect/123456789',
        RustDeskProtocol.officialPackage,
        githubCert,
      ));
      expect(rustDeskConnectUri.hasMatch(platform.launched.single.$1), isTrue);
    });

    test('发出去只记「已交给」：没有成功、失败、已连接这些状态', () async {
      await c.saveLink('h1', '123456789');
      await c.launch('h1');
      final attempt = c.state.attempts['h1']!;
      expect(attempt.phase, ExternalLaunchPhase.launchedUnverified);
      expect(attempt.at, clock);
      expect(attempt.code, isNull);
      // 过多久、刷新多少次，状态都不会自己变成别的：没有任何东西会来回报。
      clock = clock.add(const Duration(hours: 1));
      await c.refreshApp();
      expect(c.state.attempts['h1']!.phase,
          ExternalLaunchPhase.launchedUnverified);
      expect(c.state.attempts['h1']!.at, DateTime.utc(2026, 9, 30, 12));
    });

    test('RDX05：每次请求记下交给了哪个包、当时是什么版本', () async {
      await c.saveLink('h1', '123456789');
      await c.launch('h1');
      expect(c.state.attempts['h1']!.package, RustDeskProtocol.officialPackage);
      expect(c.state.attempts['h1']!.versionName, '1.4.9');

      platform.probeResult = RustDeskProbe(
        platformSupported: true,
        handlers: [official(version: '1.6.0')],
        officialInstalled: official(version: '1.6.0'),
      );
      await c.launch('h1');
      // 新版本没核对过：链接还是原来的写法，不猜新写法。
      expect(platform.launched.last.$1, 'rustdesk://connect/123456789');
      expect(c.state.attempts['h1']!.versionName, '1.6.0');
      expect((c.state.app as RustDeskReady).version,
          RustDeskVersionSupport.newerUnverified);
    });

    test('系统没接下这次启动：记「没能打开」和原因，不重试、不换别的 App', () async {
      await c.saveLink('h1', '123456789');
      platform.probeResult = RustDeskProbe(
        platformSupported: true,
        handlers: [official(), custom()],
        officialInstalled: official(),
      );
      platform.failLaunch = 'RustDesk 没有接收这个请求';
      await expectLater(c.launch('h1'), throwsA(isA<RustDeskLaunchFailed>()));
      final attempt = c.state.attempts['h1']!;
      expect(attempt.phase, ExternalLaunchPhase.launchFailed);
      expect(attempt.code, 'RustDesk 没有接收这个请求');
      expect(platform.launched, isEmpty);
    });

    test('没填 ID 不发；删除 SSH 主机不删除独立远控条目', () async {
      await expectLater(c.launch('h1'), throwsA(isA<RustDeskRequestRefused>()));
      await c.saveLink('h1', '123456789');
      hosts = const [];
      await c.launch('h1');
      expect(platform.launched, hasLength(1));
      await c.deleteEntry('h1');
      await expectLater(c.launch('h1'), throwsA(isA<RustDeskRequestRefused>()));
      expect(platform.launched, hasLength(1));
    });

    test('改了 ID：上一次请求的记录不再挂在这台主机上', () async {
      await c.saveLink('h1', '123456789');
      await c.launch('h1');
      expect(c.state.attempts['h1'], isNotNull);
      await c.saveLink('h1', '987654321');
      expect(c.state.attempts['h1'], isNull);
    });

    test('registry 里没有 RustDesk 能力：在探测、发请求之前就拒绝', () async {
      final none = build(
        registry: PluginRegistry(
          policy: AdmissionPolicy(builtinIds: BuiltinPlugins.ids),
          builtins: [
            for (final d in BuiltinPlugins.descriptors)
              if (d.pluginId != BuiltinPlugins.rustdesk) d,
          ],
        ),
      );
      addTearDown(none.dispose);
      await none.ready;
      await none.saveLink('h1', '123456789');
      final probes = platform.probes;
      await expectLater(none.launch('h1'), throwsA(isA<PluginUnavailable>()));
      await expectLater(
        none.trustClient('com.example.myrustdesk', 'cert-mine'),
        throwsA(isA<PluginUnavailable>()),
      );
      expect(platform.probes, probes);
      expect(platform.launched, isEmpty);
    });
  });

  group('RDX01 发给谁', () {
    test('手机上的 RustDesk 每次发之前重新查：中途被换成别人签的同名包就不发', () async {
      await c.saveLink('h1', '123456789');
      await c.launch('h1');
      platform.probeResult = RustDeskProbe(
        platformSupported: true,
        handlers: [
          official(signers: {'cert-evil'})
        ],
        officialInstalled: official(signers: {'cert-evil'}),
      );
      await expectLater(c.launch('h1'), throwsA(isA<RustDeskRequestRefused>()));
      expect(platform.launched, hasLength(1));
      expect(c.state.app, isA<RustDeskSignerNeedsApproval>());
    });

    test('只有别的包声明 rustdesk://：不发给它', () async {
      platform.probeResult =
          RustDeskProbe(platformSupported: true, handlers: [custom()]);
      await c.saveLink('h1', '123456789');
      await expectLater(c.launch('h1'), throwsA(isA<RustDeskRequestRefused>()));
      expect(platform.launched, isEmpty);
    });

    test('用户信任自建客户端后才发给它；撤销后不再发', () async {
      platform.probeResult = RustDeskProbe(
        platformSupported: true,
        handlers: [custom(), official()],
        officialInstalled: official(),
      );
      await c.saveLink('h1', '123456789');
      await c.trustClient('com.example.myrustdesk', 'cert-mine');
      expect((c.state.app as RustDeskReady).client.package,
          'com.example.myrustdesk');
      await c.launch('h1');
      expect(platform.launched.last, (
        'rustdesk://connect/123456789',
        'com.example.myrustdesk',
        'cert-mine',
      ));
      expect(c.state.attempts['h1']!.package, 'com.example.myrustdesk');

      await c.revokeTrust();
      await c.launch('h1');
      expect(platform.launched.last.$2, RustDeskProtocol.officialPackage);
    });

    test('信任只认此刻系统读出的那张证书：确认期间换了就不信任', () async {
      platform.probeResult = RustDeskProbe(
        platformSupported: true,
        handlers: [
          custom(signers: {'cert-swapped'})
        ],
      );
      await expectLater(
        c.trustClient('com.example.myrustdesk', 'cert-mine'),
        throwsA(isA<RustDeskRequestRefused>()),
      );
      await expectLater(
        c.trustClient('com.example.notinstalled', 'cert-mine'),
        throwsA(isA<RustDeskRequestRefused>()),
      );
      expect(storedField(backend.values, 'rustdesk', 'records'), isEmpty);
      expect(c.state.app, isA<RustDeskNotInstalled>());
      expect(backend.values['rustdesk.trust.v1'], isNull);
    });

    test('信任的客户端换了签名：停下，不发；重新信任后恢复', () async {
      platform.probeResult =
          RustDeskProbe(platformSupported: true, handlers: [custom()]);
      await c.saveLink('h1', '123456789');
      await c.trustClient('com.example.myrustdesk', 'cert-mine');
      await c.launch('h1');

      platform.probeResult = RustDeskProbe(
        platformSupported: true,
        handlers: [
          custom(signers: {'cert-new'})
        ],
      );
      await expectLater(c.launch('h1'), throwsA(isA<RustDeskRequestRefused>()));
      expect(c.state.app, isA<RustDeskSignerChanged>());
      expect(platform.launched, hasLength(1));

      await c.trustClient('com.example.myrustdesk', 'cert-new');
      await c.launch('h1');
      expect(platform.launched.last.$3, 'cert-new');
    });

    test('信任记录跨重开保留', () async {
      platform.probeResult =
          RustDeskProbe(platformSupported: true, handlers: [custom()]);
      await c.trustClient('com.example.myrustdesk', 'cert-mine');
      final reopened = build();
      addTearDown(reopened.dispose);
      await reopened.ready;
      expect(reopened.state.app, isA<RustDeskReady>());
    });

    test('版本太旧、平台不支持：不发', () async {
      await c.saveLink('h1', '123456789');
      platform.probeResult = RustDeskProbe(
        platformSupported: true,
        handlers: [official(version: '1.2.3')],
        officialInstalled: official(version: '1.2.3'),
      );
      await expectLater(c.launch('h1'), throwsA(isA<RustDeskRequestRefused>()));
      platform.probeResult = const RustDeskProbe(platformSupported: false);
      await expectLater(c.launch('h1'), throwsA(isA<RustDeskRequestRefused>()));
      expect(platform.launched, isEmpty);
    });
  });

  group('RDX04 路线', () {
    test('SSH 经代理或跳板的主机：不确认就不发，连探测都不做', () async {
      await c.saveLink('h2', '123456789');
      await c.saveLink('h3', '987654321');
      final probes = platform.probes;
      await expectLater(
          c.launch('h2'), throwsA(isA<RustDeskRouteNeedsConfirmation>()));
      await expectLater(
          c.launch('h3'), throwsA(isA<RustDeskRouteNeedsConfirmation>()));
      expect(platform.launched, isEmpty);
      expect(platform.probes, probes);
      expect(c.state.attempts, isEmpty);
    });

    test('确认「RustDesk 走它自己的网络」后才发；链接里没有任何代理或路线信息', () async {
      await c.saveLink('h2', '123456789');
      await c.launch('h2', acceptProviderManagedNetwork: true);
      expect(platform.launched.single.$1, 'rustdesk://connect/123456789');
    });

    test('确认只管这一次：下次还要再确认', () async {
      await c.saveLink('h2', '123456789');
      await c.launch('h2', acceptProviderManagedNetwork: true);
      await expectLater(
          c.launch('h2'), throwsA(isA<RustDeskRouteNeedsConfirmation>()));
      expect(platform.launched, hasLength(1));
    });

    test('直连的主机不用确认', () async {
      await c.saveLink('h1', '123456789');
      await c.launch('h1');
      expect(platform.launched, hasLength(1));
    });
  });
}
