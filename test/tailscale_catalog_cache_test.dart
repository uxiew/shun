import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_access.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_refresh.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/tailscale_api.dart';

// R12：目录缓存、来源映射与非破坏合并。
// 服务器是 http 的 MockClient（按官方响应形状回），仓库是临时目录里的真实文件，主机表在内存。
// 没有真实 Tailscale 账号；这些测试证明合并规则，不证明 Tailscale 的真实行为。

Map<String, Object?> device(
  String id, {
  String? name,
  List<String> addresses = const ['100.64.0.7'],
  Object? connected = true,
  Map<String, Object?> extra = const {},
}) =>
    {
      'id': id,
      'name': name ?? 'dev-$id.tail0000.ts.net',
      'hostname': name ?? 'dev-$id',
      'addresses': addresses,
      'os': 'linux',
      if (connected != null) 'connectedToControl': connected,
      ...extra,
    };

class MemoryBackend implements CatalogSecretBackend {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class HostTable {
  HostTable(this.hosts);
  List<HostProfile> hosts;

  /// 模拟用户在「读主机列表」和「写主机」之间改了东西。
  void Function()? beforeWrite;

  Future<List<HostProfile>> list() async => hosts;

  Future<void> update(
    String id,
    HostProfile? Function(HostProfile current) change,
  ) async {
    beforeWrite?.call();
    final index = hosts.indexWhere((h) => h.id == id);
    if (index < 0) return;
    final next = change(hosts[index]);
    if (next != null) hosts = [...hosts]..[index] = next;
  }

  HostProfile byId(String id) => hosts.singleWhere((h) => h.id == id);
}

HostProfile boundHost(
  String id, {
  String catalogId = 'cat-a',
  String deviceId = 'A',
  String hostname = '100.64.0.7',
  String? applied = '100.64.0.7',
  CatalogAddressKind address = CatalogAddressKind.ipv4,
}) =>
    HostProfile({
      'id': id,
      'label': '我的 NAS',
      'hostname': hostname,
      'port': 2222,
      'username': 'me',
      'identityFileId': 'key-1',
      'proxyProfileId': 'proxy-1',
      'hostChainIds': ['jump-1'],
      'authMethod': 'key',
      CatalogBinding.key: CatalogBinding(
        catalogId: catalogId,
        deviceId: deviceId,
        address: address,
        appliedAddress: applied,
      ).toJson(),
    });

/// 用户字段：刷新永远不能改（TSC04）。
Map<String, Object?> userFields(HostProfile h) => {
      for (final k in [
        'label',
        'port',
        'username',
        'identityFileId',
        'proxyProfileId',
        'hostChainIds',
        'authMethod',
      ])
        k: h.data[k],
    };

void main() {
  late Directory dir;
  late CatalogCacheRepository repo;
  late MemoryBackend secrets;
  late HostTable table;
  late List<http.Response> replies;
  late List<http.Request> requests;
  var clock = DateTime.utc(2026, 9, 30, 8);

  CatalogRefresher refresher() {
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/v2/oauth/token') {
        return http.Response(
          jsonEncode({
            'access_token': 't',
            'token_type': 'Bearer',
            'expires_in': 3600,
            'scope': 'devices:core:read',
          }),
          200,
        );
      }
      return replies.length > 1 ? replies.removeAt(0) : replies.first;
    });
    return CatalogRefresher(
      access: TailscaleCatalogAccess(
        TailscaleCatalogSecretStore(secrets),
        (credential) => TailscaleCatalogClient.fixture(
          client,
          Uri.parse('http://127.0.0.1:1'),
          credential,
          now: () => clock,
        ),
      ),
      repository: repo,
      hosts: table.list,
      updateHost: table.update,
      now: () => clock,
    );
  }

  void serve(List<Map<String, Object?>> devices) => replies = [
        http.Response(jsonEncode({'devices': devices}), 200)
      ];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('r12-');
    repo = CatalogCacheRepository(() async => dir);
    secrets = MemoryBackend();
    table = HostTable([]);
    requests = [];
    replies = [
      http.Response(
          jsonEncode({
            'devices': [device('A')]
          }),
          200)
    ];
    clock = DateTime.utc(2026, 9, 30, 8);
  });
  tearDown(() => dir.delete(recursive: true));

  Future<CatalogRefresher> sourceWithHosts(List<HostProfile> hosts) async {
    table.hosts = hosts;
    final r = refresher();
    await r.addSource(catalogId: 'cat-a', label: '家里');
    return r;
  }

  group('TSC04 改名/换 IP、同名不同 id、旧 id 删除后同名重建', () {
    test('改名换 IP：缓存更新；跟随目录的主机只改地址，用户字段一个不动', () async {
      final r = await sourceWithHosts([boundHost('h1')]);
      serve([device('A', name: 'nas')]);
      await r.refreshWithToken('cat-a', 'tok');
      final before = userFields(table.byId('h1'));

      clock = clock.add(const Duration(hours: 1));
      serve([
        device('A', name: 'nas-renamed', addresses: ['100.64.0.9'])
      ]);
      final outcome = await r.refreshWithToken('cat-a', 'tok');

      expect(outcome.hostsReaddressed, 1);
      final host = table.byId('h1');
      expect(host.hostname, '100.64.0.9');
      expect(CatalogBinding.of(host)!.appliedAddress, '100.64.0.9');
      expect(userFields(host), before);
      expect(outcome.cache.devices['A']!.device.hostname, 'nas-renamed');
    });

    test('用户改过地址：刷新不再跟随目录', () async {
      final r = await sourceWithHosts([boundHost('h1', hostname: 'nas.lan')]);
      serve([
        device('A', addresses: ['100.64.0.9'])
      ]);
      final outcome = await r.refreshWithToken('cat-a', 'tok');
      expect(outcome.hostsReaddressed, 0);
      expect(table.byId('h1').hostname, 'nas.lan');
    });

    test('从没由目录写过地址（appliedAddress 为空）：不改', () async {
      final r = await sourceWithHosts([boundHost('h1', applied: null)]);
      serve([
        device('A', addresses: ['100.64.0.9'])
      ]);
      await r.refreshWithToken('cat-a', 'tok');
      expect(table.byId('h1').hostname, '100.64.0.7');
    });

    test('同名不同 id：各是各的设备，主机只跟随自己绑定的那个 id', () async {
      final r = await sourceWithHosts([boundHost('h1')]);
      serve([
        device('A', name: 'nas', addresses: ['100.64.0.7']),
        device('B', name: 'nas', addresses: ['100.64.0.8']),
      ]);
      final outcome = await r.refreshWithToken('cat-a', 'tok');
      expect(outcome.cache.devices.keys, containsAll(['A', 'B']));
      expect(table.byId('h1').hostname, '100.64.0.7');
    });

    test('旧 id 删除后同名重建：旧的标「不见了」，主机不被改绑、不改地址', () async {
      final r = await sourceWithHosts([boundHost('h1')]);
      serve([device('A', name: 'nas')]);
      await r.refreshWithToken('cat-a', 'tok');

      clock = clock.add(const Duration(days: 1));
      serve([
        device('C', name: 'nas', addresses: ['100.64.0.7']),
      ]);
      final outcome = await r.refreshWithToken('cat-a', 'tok');
      expect(outcome.cache.devices['A']!.missingSince, clock);
      expect(outcome.cache.devices['C']!.missing, isFalse);
      final host = table.byId('h1');
      expect(CatalogBinding.of(host)!.deviceId, 'A');
      expect(host.hostname, '100.64.0.7');
      expect(
        catalogStatusOf(host, {'cat-a': outcome.cache})!.presence,
        CatalogPresence.missing,
      );
    });

    test('用户恰好在刷新中途改了地址：以写入那一刻的主机为准，不覆盖', () async {
      final r = await sourceWithHosts([boundHost('h1')]);
      serve([
        device('A', addresses: ['100.64.0.9'])
      ]);
      table.beforeWrite = () {
        table.hosts = [
          HostProfile({...table.byId('h1').data, 'hostname': 'typed.by.user'}),
        ];
        table.beforeWrite = null;
      };
      final outcome = await r.refreshWithToken('cat-a', 'tok');
      expect(outcome.hostsReaddressed, 0);
      expect(table.byId('h1').hostname, 'typed.by.user');
    });
  });

  group('TSC05 完整/不完整快照、网络中断、合法空目录', () {
    Future<CatalogRefresher> withTwoDevices() async {
      final r = await sourceWithHosts([boundHost('h1')]);
      serve([
        device('A'),
        device('B', addresses: ['100.64.0.8'])
      ]);
      await r.refreshWithToken('cat-a', 'tok');
      clock = clock.add(const Duration(hours: 1));
      return r;
    }

    test('不完整快照（有条目缺 id）：没出现的设备不标不见了，并写明原因', () async {
      final r = await withTwoDevices();
      serve([
        device('A'),
        {'hostname': 'no-id'},
      ]);
      final outcome = await r.refreshWithToken('cat-a', 'tok');
      expect(outcome.cache.devices['B']!.missing, isFalse);
      expect(outcome.cache.lastSuccess!.complete, isFalse);
      expect(outcome.cache.lastSuccess!.note, contains('不完整'));
    });

    test('合法空目录：不据此标记任何设备，更不删主机', () async {
      final r = await withTwoDevices();
      serve([]);
      final outcome = await r.refreshWithToken('cat-a', 'tok');
      expect(outcome.cache.devices.values.where((d) => d.missing), isEmpty);
      expect(outcome.cache.lastSuccess!.note, contains('0 台'));
      expect(table.hosts, hasLength(1));
    });

    test('服务器出错、网络中断：设备和主机都不动，只记失败；上次成功的时间保留', () async {
      final r = await withTwoDevices();
      final lastGood = (await repo.load('cat-a'))!.lastSuccess!.at;
      replies = [http.Response('{"message":"boom"}', 500)];
      final failed = await r.refreshWithToken('cat-a', 'tok');
      expect(failed.error, isA<TailscaleServerError>());
      expect(failed.cache.devices.keys, containsAll(['A', 'B']));
      expect(failed.cache.lastAttempt!.ok, isFalse);
      expect(failed.cache.lastSuccess!.at, lastGood);
      expect(table.byId('h1').hostname, '100.64.0.7');

      final saved = (await repo.load('cat-a'))!;
      expect(saved.devices.keys, containsAll(['A', 'B']));
      expect(saved.lastAttempt!.ok, isFalse);
    });

    test('完整非空快照里没出现：标不见了；再次出现即恢复', () async {
      final r = await withTwoDevices();
      serve([device('A')]);
      var outcome = await r.refreshWithToken('cat-a', 'tok');
      expect(outcome.cache.devices['B']!.missingSince, clock);

      clock = clock.add(const Duration(hours: 1));
      serve([
        device('A'),
        device('B', addresses: ['100.64.0.8'])
      ]);
      outcome = await r.refreshWithToken('cat-a', 'tok');
      expect(outcome.cache.devices['B']!.missing, isFalse);
    });

    test('只按官方口径：列设备请求不带分页或任何查询参数', () async {
      final r = await withTwoDevices();
      serve([device('A')]);
      await r.refreshWithToken('cat-a', 'tok');
      expect(
        requests
            .where((q) => q.url.path.endsWith('/devices'))
            .every((q) => q.url.query.isEmpty),
        isTrue,
      );
    });
  });

  group('TSC03 字段缺失、类型错误、控制字符、缺 IP', () {
    test('缺字段和类型不对记为不知道；缓存读写往返不补默认值', () async {
      final r = await sourceWithHosts([]);
      serve([
        {
          'id': 'W',
          'name': 'evil\u0007name',
          'addresses': 'not-a-list',
          'os': 42,
          'connectedToControl': 'yes',
        },
      ]);
      await r.refreshWithToken('cat-a', 'tok');
      final record = (await repo.load('cat-a'))!.devices['W']!;
      expect(record.device.name, isNull);
      expect(record.device.addresses, isEmpty);
      expect(record.device.os, isNull);
      expect(record.device.connectedToControl, isNull);
    });

    test('设备当前没有 IPv4：不改主机地址，也不回退到别的地址种类', () async {
      final r = await sourceWithHosts([boundHost('h1')]);
      serve([
        device('A', addresses: ['fd7a:115c:a1e0::7']),
      ]);
      final outcome = await r.refreshWithToken('cat-a', 'tok');
      expect(outcome.hostsReaddressed, 0);
      expect(table.byId('h1').hostname, '100.64.0.7');
    });

    test('状态里没有「在线」「SSH 可用」：控制面状态不知道就是 null', () async {
      expect(
        CatalogPresence.values.map((p) => p.name.toLowerCase()),
        everyElement(isNot(anyOf(contains('online'), contains('ssh')))),
      );
      final r = await sourceWithHosts([boundHost('h1')]);
      serve([device('A', connected: null)]);
      final outcome = await r.refreshWithToken('cat-a', 'tok');
      final status =
          catalogStatusOf(table.byId('h1'), {'cat-a': outcome.cache})!;
      expect(status.presence, CatalogPresence.listed);
      expect(status.connectedToControl, isNull);
    });
  });

  group('TSC10 别名 tailnet 的两个来源、删凭据再刷新', () {
    test('两个来源都写 -、设备 id 和名字都一样：各自隔离，互不影响', () async {
      table.hosts = [
        boundHost('h1', catalogId: 'cat-a'),
        boundHost('h2', catalogId: 'cat-b'),
      ];
      final r = refresher();
      await r.addSource(catalogId: 'cat-a');
      await r.addSource(catalogId: 'cat-b');
      serve([
        device('A', addresses: ['100.64.0.9'])
      ]);
      await r.refreshWithToken('cat-b', 'tok');

      expect(table.byId('h1').hostname, '100.64.0.7');
      expect(table.byId('h2').hostname, '100.64.0.9');
      expect((await repo.load('cat-a'))!.devices, isEmpty);
      expect((await repo.load('cat-b'))!.devices.keys, ['A']);
    });

    test('删了保存的凭据再刷新：要求重新授权，缓存设备和手动编辑过的主机都不动', () async {
      final manual = HostProfile({
        'id': 'manual',
        'label': '手动添加',
        'hostname': '10.0.0.5',
        'username': 'root2',
      });
      final r = await sourceWithHosts([boundHost('h1'), manual]);
      // 相当于用户开了持续刷新后保存的 client。
      secrets.values['tailscale.catalog.cat-a.oauth.clientId'] = 'cid';
      secrets.values['tailscale.catalog.cat-a.oauth.clientSecret'] = 'csecret';
      serve([device('A')]);
      expect((await r.refreshSaved('cat-a')).error, isNull);
      final before = table.hosts.map((h) => h.data).toList();

      await r.forgetCredentials('cat-a');
      expect(secrets.values, isEmpty);
      final outcome = await r.refreshSaved('cat-a');
      expect(outcome.error, isA<TailscaleReauthorizationRequired>());
      expect(outcome.cache.devices.keys, ['A']);
      expect(table.hosts.map((h) => h.data).toList(), before);
    });

    test('移除来源：只删缓存和凭据副本，主机和它上面的关联都留着', () async {
      final r = await sourceWithHosts([boundHost('h1')]);
      await r.refreshWithToken('cat-a', 'tok');
      await r.removeSource('cat-a');
      expect(await repo.load('cat-a'), isNull);
      final host = table.byId('h1');
      expect(CatalogBinding.of(host)!.deviceId, 'A');
      expect(
        catalogStatusOf(host, {})!.presence,
        CatalogPresence.sourceNotOnThisDevice,
      );
    });
  });

  group('缓存文件', () {
    test('被改坏：读作没有缓存，原文件改名留存，不被下次保存悄悄覆盖', () async {
      await File('${dir.path}/cat-a.json').writeAsString('{"schemaVersion":1');
      expect(await repo.load('cat-a'), isNull);
      expect(await File('${dir.path}/cat-a.json.corrupt').exists(), isTrue);

      await File('${dir.path}/cat-b.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'catalogId': 'cat-b',
          'tailnet': '-',
          'devices': [
            {'id': 'X', 'firstSeenAt': 42},
          ],
        }),
      );
      expect(await repo.load('cat-b'), isNull);
    });

    test('BAS03 回滚：更新版本写的缓存不读、不改名、不覆盖，刷新也不动它', () async {
      final newer = jsonEncode({
        'schemaVersion': 2,
        'catalogId': 'cat-a',
        'tailnet': '-',
        'devices': [],
        'somethingNew': true,
      });
      final file = File('${dir.path}/cat-a.json');
      await file.writeAsString(newer);
      await expectLater(
        repo.load('cat-a'),
        throwsA(isA<CatalogCacheTooNew>()),
      );
      expect(await repo.loadAll(), isEmpty);
      await expectLater(
        refresher().refreshWithToken('cat-a', 'tok'),
        throwsA(isA<CatalogCacheTooNew>()),
      );
      expect(await file.readAsString(), newer);
      expect(await File('${file.path}.corrupt').exists(), isFalse);
    });

    test('BAS03 未知字段：主机上的目录关联经保险库 JSON 往返不丢', () {
      final host = boundHost('h1');
      final back = HostProfile(
        jsonDecode(jsonEncode(host.data)) as Map<String, dynamic>,
      );
      expect(
          CatalogBinding.of(back)!.toJson(), CatalogBinding.of(host)!.toJson());
    });

    test('catalogId 只能是字母数字和连字符，不能拼出别的路径', () {
      expect(() => repo.load('../vault'), throwsArgumentError);
    });

    test('缓存里没有任何凭据字段', () async {
      final r = await sourceWithHosts([]);
      await r.refreshWithToken('cat-a', 'tskey-api-SECRETCANARY');
      final text = await File('${dir.path}/cat-a.json').readAsString();
      expect(text, isNot(contains('SECRETCANARY')));
      expect(text, isNot(contains('machineKey')));
    });
  });

  group('R13 界面用到的入口：OAuth client 读取与是否已保存', () {
    const client =
        OAuthClientCredential(clientId: 'cid', clientSecret: 'csecret');

    test('不要求持续刷新：读完即丢，不保存，也不报「没保存」的原因', () async {
      final r = await sourceWithHosts([]);
      final outcome =
          await r.refreshWithOAuthClient('cat-a', client, persist: false);
      expect(outcome.error, isNull);
      expect(outcome.cache.devices, contains('A'));
      expect(outcome.persistRefusal, isNull);
      expect(outcome.scope, TokenScopeStatus.deviceReadOnly);
      expect(await r.hasSavedCredentials('cat-a'), isFalse);
      expect(secrets.values, isEmpty);
    });

    test('要求持续刷新、服务器确认只读设备：保存，之后能直接刷新', () async {
      final r = await sourceWithHosts([]);
      final outcome =
          await r.refreshWithOAuthClient('cat-a', client, persist: true);
      expect(outcome.persistRefusal, isNull);
      expect(await r.hasSavedCredentials('cat-a'), isTrue);
      expect((await refresher().refreshSaved('cat-a')).error, isNull);
      await r.forgetCredentials('cat-a');
      expect(await refresher().hasSavedCredentials('cat-a'), isFalse);
    });

    test('失败时不保存，缓存里的设备不动', () async {
      final r = await sourceWithHosts([]);
      await r.refreshWithToken('cat-a', 'tok');
      replies = [http.Response('{"message":"boom"}', 500)];
      final outcome =
          await r.refreshWithOAuthClient('cat-a', client, persist: true);
      expect(outcome.error, isNotNull);
      expect(outcome.cache.devices, contains('A'));
      expect(await r.hasSavedCredentials('cat-a'), isFalse);
    });
  });
}
