import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/host_trust.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_import.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_refresh.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/catalog_cache.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/tailscale_device.dart';
import 'package:shared_preferences/shared_preferences.dart';

// R13：从目录批量导入主机。只写保险库；用户名必须填；路线按用户选；不写任何指纹信任；
// 已导入的设备跳过、已有主机一台都不改。
final at = DateTime.utc(2026, 9, 30, 8);

CatalogCache cacheOf(List<Map<String, Object?>> devices,
    {Set<String> missing = const {}}) {
  final snapshot = TailscaleDeviceSnapshot.parse(jsonEncode({
    'devices': devices,
  }));
  var cache =
      const CatalogCache(catalogId: 'cat-a', tailnet: '-').merge(snapshot, at);
  if (missing.isNotEmpty) {
    cache = cache.copyWith(devices: {
      for (final entry in cache.devices.entries)
        entry.key: missing.contains(entry.key)
            ? entry.value.markMissing(at)
            : entry.value,
    });
  }
  return cache;
}

Map<String, Object?> device(String id,
        {List<String> addresses = const ['100.64.0.7', 'fd7a::7'],
        String? hostname}) =>
    {
      'id': id,
      'name': '${hostname ?? 'dev-$id'}.tail0000.ts.net.',
      'hostname': hostname ?? 'dev-$id',
      'addresses': addresses,
      'os': 'linux',
    };

final cache = cacheOf([
  device('1', addresses: ['100.64.0.1', 'fd7a::1'], hostname: 'nas'),
  device('2', addresses: ['fd7a::2'], hostname: 'v6only'),
  device('3', addresses: ['100.64.0.3'], hostname: 'gone'),
  device('4', addresses: ['100.64.0.4'], hostname: 'already'),
], missing: {
  '3'
});

HostProfile manual(String id, String hostname, {Map<String, Object?>? extra}) =>
    HostProfile({
      ...HostProfile.create(
        id: id,
        label: id,
        hostname: hostname,
        username: 'admin',
      ).data,
      ...?extra,
    });

VaultData vaultWith(List<HostProfile> hosts,
        {List<ProxyProfile> proxies = const []}) =>
    VaultData(
      hosts: hosts,
      keys: [
        SshKeyProfile({'id': 'k1', 'label': 'laptop', 'privateKey': 'KEY'}),
      ],
      snippets: [],
      customGroups: [],
      proxyProfiles: proxies,
    );

final already = manual('h-already', '100.64.0.4', extra: {
  CatalogBinding.key: const CatalogBinding(
    catalogId: 'cat-a',
    deviceId: '4',
    appliedAddress: '100.64.0.4',
  ).toJson(),
});

var _ids = 0;
String newId() => 'new-${++_ids}';

CatalogImportResult run(
  CatalogImportOptions options, {
  List<String> ids = const ['1', '2', '3', '4'],
  VaultData? vault,
}) =>
    buildCatalogImport(
      cache: cache,
      deviceIds: ids,
      options: options,
      vault: vault ?? vaultWith([already]),
      newId: newId,
    );

void main() {
  setUp(() => _ids = 0);

  group('设置不成立就一台都不导', () {
    test('没填用户名：报错，不默认 root', () {
      for (final name in ['', '   ']) {
        expect(
          () => run(CatalogImportOptions(username: name)),
          throwsA(isA<CatalogImportInvalid>()
              .having((e) => e.message, 'message', contains('不会默认用 root'))),
        );
      }
    });

    test('用户名带空格、端口越界、私钥认证没选私钥', () {
      expect(() => run(const CatalogImportOptions(username: 'a b')),
          throwsA(isA<CatalogImportInvalid>()));
      expect(() => run(const CatalogImportOptions(username: 'u', port: 0)),
          throwsA(isA<CatalogImportInvalid>()));
      expect(
          () => run(const CatalogImportOptions(
              username: 'u', authMethod: HostAuthMethod.key)),
          throwsA(isA<CatalogImportInvalid>()));
    });

    test('路线本身不成立（跳板不存在、代理配置不存在）：整批拒绝，用和连接时同一个检查', () {
      expect(
        () => run(const CatalogImportOptions(
            username: 'u', jumpHostIds: ['no-such-host'])),
        throwsA(isA<CatalogImportInvalid>()
            .having((e) => e.message, 'message', contains('找不到跳板机'))),
      );
      expect(
        () => run(const CatalogImportOptions(
            username: 'u', proxyProfileId: 'no-such-proxy')),
        throwsA(isA<CatalogImportInvalid>()
            .having((e) => e.message, 'message', contains('找不到代理配置'))),
      );
    });
  });

  group('逐台决定导不导', () {
    test('没有所选种类地址的、目录里不见了的、已导入的：跳过并写明原因', () {
      final result = run(const CatalogImportOptions(username: 'ubuntu'));
      expect(result.hosts.map((h) => h.label), ['nas']);
      expect(
        {for (final s in result.skipped) s.name: s.reason},
        {
          'v6only': '没有 IPv4 地址',
          'gone': '最近一次完整列表里没有它',
          'already': '已导入为“h-already”',
        },
      );
    });

    test('选 IPv6 或 MagicDNS 名称就用对应地址，不回退到别的种类', () {
      final v6 = run(const CatalogImportOptions(
          username: 'u', address: CatalogAddressKind.ipv6));
      expect(v6.hosts.map((h) => h.hostname), ['fd7a::1', 'fd7a::2']);
      final dns = run(const CatalogImportOptions(
          username: 'u', address: CatalogAddressKind.fqdn));
      expect(dns.hosts.map((h) => h.hostname),
          ['nas.tail0000.ts.net', 'v6only.tail0000.ts.net']);
    });

    test('同一批里选了两次同一台设备，只建一台', () {
      final result =
          run(const CatalogImportOptions(username: 'u'), ids: ['1', '1']);
      expect(result.hosts, hasLength(1));
      expect(result.skipped.single.reason, '已导入为“nas”');
    });

    test('设备地址和选的跳板机是同一台机器：只跳过这台，其他照导', () {
      final hop = manual('hop', '100.64.0.1');
      final result = run(
        const CatalogImportOptions(username: 'u', jumpHostIds: ['hop']),
        ids: ['1', '4'],
        vault: vaultWith([hop]),
      );
      expect(result.hosts.map((h) => h.label), ['already']);
      expect(result.skipped.single.reason, contains('同一台机器出现了两次'));
    });
  });

  group('生成的主机', () {
    test('用户的设置原样写入，并带上来源关联（appliedAddress 就是写进去的地址）', () {
      final proxy = ProxyProfile({
        'id': 'p1',
        'label': 'tailsocks',
        'config': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1055},
      });
      final hop = manual('hop', 'bastion.example.com');
      final result = run(
        const CatalogImportOptions(
          username: 'ubuntu',
          port: 2222,
          proxyProfileId: 'p1',
          jumpHostIds: ['hop'],
          authMethod: HostAuthMethod.key,
          identityFileId: 'k1',
          group: 'tailnet',
        ),
        ids: ['1'],
        vault: vaultWith([hop], proxies: [proxy]),
      );
      final host = result.hosts.single;
      expect(host.id, 'new-1');
      expect(host.hostname, '100.64.0.1');
      expect(host.username, 'ubuntu');
      expect(host.port, 2222);
      expect(host.authMethod, HostAuthMethod.key);
      expect(host.identityFileId, 'k1');
      expect(host.group, 'tailnet');
      expect(host.proxyProfileId, 'p1');
      expect(host.hostChainIds, ['hop']);
      expect(host.password, isNull);
      final binding = CatalogBinding.of(host)!;
      expect(binding.catalogId, 'cat-a');
      expect(binding.deviceId, '1');
      expect(binding.appliedAddress, '100.64.0.1');
      // 路线就是连接时会走的那条：代理只用于连第一台跳板机。
      final plan =
          resolveRoutePlan(host, hosts: [hop, host], proxyProfiles: [proxy]);
      expect(plan.entry, isA<ProxyEntry>());
      expect(plan.jumps.single.host.id, 'hop');
    });

    test('自定义代理写进每台新主机；和已保存配置二选一；地址不合法整批拒绝', () {
      const socks = ProxyConfig(
        type: ProxyType.socks5,
        host: '127.0.0.1',
        port: 1055,
        username: 'u',
        password: 'PROXY-PW',
      );
      final result = run(
        const CatalogImportOptions(username: 'u', proxyConfig: socks),
        ids: ['1'],
      );
      final host = result.hosts.single;
      expect(host.proxyConfig?.port, 1055);
      expect(host.proxyConfig?.password, 'PROXY-PW');
      expect(host.proxyProfileId, isNull);
      expect(
        () => run(const CatalogImportOptions(
            username: 'u', proxyConfig: socks, proxyProfileId: 'p1')),
        throwsA(isA<CatalogImportInvalid>()),
      );
      expect(
        () => run(const CatalogImportOptions(
            username: 'u',
            proxyConfig:
                ProxyConfig(type: ProxyType.socks5, host: '', port: 1055))),
        throwsA(isA<CatalogImportInvalid>()),
      );
    });

    test('导入不带指纹信任：第一次连接照常要核对（TSC04）', () {
      final host = run(const CatalogImportOptions(username: 'u'), ids: ['1'])
          .hosts
          .single;
      expect(host.data.keys, isNot(contains('knownHosts')));
      final check = checkHostKey(
        const [],
        hostname: host.hostname,
        port: host.port,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:anything',
      );
      expect(check.status, HostKeyStatus.unknown);
    });

    test('刷新时地址跟随目录：导入写下的 appliedAddress 让 R12 的跟随规则生效', () {
      final host = run(const CatalogImportOptions(username: 'u'), ids: ['1'])
          .hosts
          .single;
      final moved = cacheOf([
        device('1', addresses: ['100.64.0.99'], hostname: 'nas'),
      ]);
      expect(refreshedHost(host, moved)?.hostname, '100.64.0.99');
    });
  });

  group('写进保险库', () {
    const secureStorage =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    late VaultController vault;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorage, (call) async => null);
      SharedPreferences.setMockInitialValues({});
      vault = VaultController(await VaultRepository.open());
      await vault.ready();
    });
    tearDown(() => vault.dispose());

    test('只新建，已有主机逐字段不变、指纹记录一条不增；分组加进分组列表', () async {
      final mine = manual('mine', '100.64.0.1', extra: {'password': 'PW'});
      final known = [
        {
          'hostname': 'bastion.example.com',
          'port': 22,
          'keyType': 'ssh-ed25519',
          'fingerprint': 'SHA256:verified-by-user',
        },
      ];
      await vault.replace(VaultData(
        hosts: [mine],
        keys: [],
        snippets: [],
        customGroups: [],
        extras: {'knownHosts': known},
      ));
      final before = jsonEncode((await vault.ready()).hosts.single.data);
      final result = run(
        const CatalogImportOptions(username: 'u', group: 'tailnet'),
        ids: ['1'],
        vault: await vault.ready(),
      );
      final added = await vault.addHosts(result.hosts);
      final saved = await vault.ready();
      expect(added.map((h) => h.label), ['nas']);
      expect(jsonEncode(saved.hosts.first.data), before);
      expect(saved.hosts.map((h) => h.id), ['mine', 'new-1']);
      expect(saved.customGroups, ['tailnet']);
      // 导入不替新主机记任何指纹（TSC04）：它第一次连接时按「第一次见」让用户核对。
      expect(saved.extras['knownHosts'], known);
    });

    test('同一台设备在别处刚导入过：写入时再查一次，不重复建', () async {
      final first = run(const CatalogImportOptions(username: 'u'),
          ids: ['1'], vault: await vault.ready());
      _ids = 100;
      final second = run(const CatalogImportOptions(username: 'u'),
          ids: ['1'], vault: await vault.ready());
      bool sameDevice(VaultData current, HostProfile host) {
        final binding = CatalogBinding.of(host)!;
        return current.hosts.any((h) {
          final other = CatalogBinding.of(h);
          return other?.catalogId == binding.catalogId &&
              other?.deviceId == binding.deviceId;
        });
      }

      await vault.addHosts(first.hosts, skip: sameDevice);
      final again = await vault.addHosts(second.hosts, skip: sameDevice);
      expect(again, isEmpty);
      expect((await vault.ready()).hosts, hasLength(1));
    });
  });
}
