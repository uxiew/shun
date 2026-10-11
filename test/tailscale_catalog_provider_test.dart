import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/tailscale_catalog_access.dart';
import 'package:shun/application/tailscale_catalog_import.dart';
import 'package:shun/application/tailscale_catalog_provider.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/device_references.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/plugins/builtin_plugins.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:shun/infrastructure/tailscale/tailscale_api.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

// X05：Tailscale 目录作为内置 provider。经 Riverpod 装配的真实对象：保险库（偏好在内存里）、
// 临时目录里的真实缓存文件、R11 的 HTTP 客户端；只有 Tailscale 服务器是 MockClient（按官方响应形状回）。
// 没有真实 Tailscale 账号：这些测试证明 App 发了什么、改了什么，不证明 Tailscale 的真实行为。

class LoggingBackend implements CatalogSecretBackend {
  final values = <String, String>{};
  final reads = <String>[];
  @override
  Future<String?> read(String key) async {
    reads.add(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

Map<String, Object?> device(String id, String hostname, String ip) => {
      'id': id,
      'name': '$hostname.tail0000.ts.net',
      'hostname': hostname,
      'addresses': [ip],
      'os': 'linux',
      'connectedToControl': true,
    };

HostProfile manualHost(String id, String label, String hostname) =>
    HostProfile({
      'id': id,
      'label': label,
      'hostname': hostname,
      'port': 2222,
      'username': 'me',
      'password': 'ssh-secret-x05',
      'authMethod': 'password',
      'proxyConfig': {
        'type': 'socks5',
        'host': '127.0.0.1',
        'port': 1080,
        'username': 'u',
        'password': 'proxy-secret-x05',
      },
      'startupCommand': 'echo hi',
    });

/// 主机的全部字段（深拷贝）。按字段比，不按 JSON 文本比：重启后密码从安全存储合回来，字段顺序会变。
Object? fields(HostProfile host) => jsonDecode(jsonEncode(host.data));

const secureStorage =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LoggingBackend secrets;
  late List<http.Request> requests;
  late List<Map<String, Object?>> devices;
  late List<http.Response> overrides;
  late ProviderContainer container;

  ProviderContainer build(
    VaultRepository repository, {
    PluginRegistry Function()? registry,
  }) {
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/v2/oauth/token') {
        return http.Response(
          jsonEncode({
            'access_token': 'tok-${request.bodyFields['client_id']}',
            'token_type': 'Bearer',
            'expires_in': 3600,
            'scope': 'devices:core:read',
          }),
          200,
        );
      }
      if (overrides.isNotEmpty) return overrides.removeAt(0);
      return http.Response(jsonEncode({'devices': devices}), 200);
    });
    return ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      catalogCacheRepositoryProvider
          .overrideWithValue(CatalogCacheRepository(() async => dir)),
      tailscaleCatalogAccessProvider.overrideWithValue(TailscaleCatalogAccess(
        TailscaleCatalogSecretStore(secrets),
        (credential) => TailscaleCatalogClient.fixture(
          client,
          Uri.parse('http://127.0.0.1:1'),
          credential,
        ),
      )),
      if (registry != null)
        pluginRegistryProvider.overrideWith((ref) => registry()),
    ]);
  }

  /// 模拟重启：保险库从同一份偏好重新打开，其余对象全部新建（内存里的 token 也没了）。
  Future<ProviderContainer> restart(
      {PluginRegistry Function()? registry}) async {
    final next = build(await VaultRepository.open(), registry: registry);
    addTearDown(next.dispose);
    await next.read(vaultControllerProvider.notifier).ready();
    return next;
  }

  TailscaleCatalogProvider provider() =>
      container.read(tailscaleCatalogProvider);
  VaultController vault() => container.read(vaultControllerProvider.notifier);
  Future<VaultData> saved() => vault().ready();
  Future<HostProfile> hostById(String id) async =>
      (await saved()).hosts.singleWhere((h) => h.id == id);

  setUp(() async {
    // 安全存储真的存在内存里：模拟重启时保险库里的密码也要读得回来，否则「逐字段不变」没法比。
    final stored = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      return switch (call.method) {
        'write' => stored[key!] = args['value'] as String,
        'read' => stored[key],
        'delete' => stored.remove(key),
        'containsKey' => stored.containsKey(key),
        'readAll' => Map<String, String>.of(stored),
        'deleteAll' => stored.clear(),
        _ => null,
      };
    });
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('x05-');
    secrets = LoggingBackend();
    requests = [];
    overrides = [];
    devices = [
      device('1', 'nas', '100.64.0.1'),
      device('2', 'laptop', '100.64.0.2'),
    ];
    container = await restart();
  });
  tearDown(() => dir.delete(recursive: true));

  /// 按真实导入流程（R13 的 buildCatalogImport + VaultController.addHosts）从目录建主机。
  Future<List<HostProfile>> import(String catalogId, List<String> ids) async {
    final cache =
        await container.read(catalogCacheRepositoryProvider).load(catalogId);
    var n = 0;
    final result = buildCatalogImport(
      cache: cache!,
      deviceIds: ids,
      options: const CatalogImportOptions(username: 'ops', port: 2200),
      vault: await saved(),
      newId: () => 'imported-${n++}',
    );
    return vault().addHosts(result.hosts, skip: alreadyImported);
  }

  group('TSC01/TSC02 经 provider 读取：HTTP 是 R11 那一套，没有新请求', () {
    test('只有换 token 和列设备两种请求；只请求 devices:core:read；复用内存 token', () async {
      final p = provider();
      await p.addSource(catalogId: 'ts-a');
      await p.refreshWithOAuthClient(
        'ts-a',
        const OAuthClientCredential(clientId: 'client-a', clientSecret: 's-a'),
        persist: true,
      );
      await p.refreshSaved('ts-a');
      expect(
        requests.map((r) => '${r.method} ${r.url.path}${r.url.query}'),
        [
          'POST /api/v2/oauth/token',
          'GET /api/v2/tailnet/-/devices',
          'GET /api/v2/tailnet/-/devices',
        ],
      );
      expect(requests.first.bodyFields['scope'], 'devices:core:read');
      expect(requests[2].headers['Authorization'], 'Bearer tok-client-a');
    });

    test('401 两次：受控刷新一次后要求重新授权；403、429 不重试；缓存、主机、关联都不动', () async {
      final p = provider();
      await p.addSource(catalogId: 'ts-a');
      await p.refreshWithOAuthClient(
        'ts-a',
        const OAuthClientCredential(clientId: 'client-a', clientSecret: 's-a'),
        persist: true,
      );
      await import('ts-a', ['1']);
      final before = fields((await saved()).hosts.single);

      requests.clear();
      overrides = [
        http.Response('{"message":"expired"}', 401),
        http.Response('{"message":"expired"}', 401),
      ];
      final expired = await p.refreshSaved('ts-a');
      expect(expired.error, isA<TailscaleReauthorizationRequired>());
      // 列设备 → 401 → 换一次 token → 再列一次 → 401 → 停。
      expect(requests.map((r) => r.url.path), [
        '/api/v2/tailnet/-/devices',
        '/api/v2/oauth/token',
        '/api/v2/tailnet/-/devices',
      ]);

      for (final status in [403, 429]) {
        requests.clear();
        overrides = [http.Response('{"message":"no"}', status)];
        expect((await p.refreshSaved('ts-a')).error, isNotNull);
        expect(requests.where((r) => r.url.path.endsWith('/devices')),
            hasLength(1),
            reason: '$status 不重试');
      }
      expect(expired.cache.devices.keys, containsAll(['1', '2']));
      expect(fields((await saved()).hosts.single), before);
      expect((await p.links()).records, hasLength(1));
    });
  });

  group('X05 provider 只访问本来源的控制面凭据', () {
    test('两个来源各存一个 client：重启后刷新 A 只读 A 的键、只用 A 的 client', () async {
      final p = provider();
      for (final (id, client) in [('ts-a', 'client-a'), ('ts-b', 'client-b')]) {
        await p.addSource(catalogId: id);
        await p.refreshWithOAuthClient(
          id,
          OAuthClientCredential(clientId: client, clientSecret: 's-$client'),
          persist: true,
        );
      }
      container = await restart();
      secrets.reads.clear();
      requests.clear();

      expect((await provider().refreshSaved('ts-a')).error, isNull);
      expect(secrets.reads, isNotEmpty);
      expect(secrets.reads.every((k) => k.contains('.ts-a.')), isTrue,
          reason: '${secrets.reads}');
      expect(requests.first.bodyFields['client_id'], 'client-a');
      expect(
        requests.every(
            (r) => !(r.headers['Authorization'] ?? '').contains('client-b')),
        isTrue,
      );
    });

    test('registry 里没有目录能力：每个操作都在发请求、读凭据、碰主机之前被拒', () async {
      await vault().upsertHost(manualHost('m', 'nas', '100.64.0.1'));
      final before = fields((await saved()).hosts.single);
      container = await restart(
        registry: () => PluginRegistry(
          policy: AdmissionPolicy(builtinIds: BuiltinPlugins.ids),
          builtins: [
            for (final d in BuiltinPlugins.descriptors)
              if (d.pluginId != BuiltinPlugins.tailscale) d,
          ],
        ),
      );
      final p = provider();
      final calls = <Future<Object?> Function()>[
        () => p.addSource(catalogId: 'ts-a'),
        () => p.refreshWithToken('ts-a', 'tok'),
        () => p.refreshSaved('ts-a'),
        () => p.hasSavedCredentials('ts-a'),
        () => p.restoreSource('ts-a'),
        () => p.linkHost(hostId: 'm', catalogId: 'ts-a', deviceId: '1'),
        () => p.links(),
      ];
      for (final call in calls) {
        await expectLater(call(), throwsA(isA<PluginUnavailable>()));
      }
      expect(requests, isEmpty);
      expect(secrets.reads, isEmpty);
      expect(fields((await saved()).hosts.single), before);
    });
  });

  group('DEV01 只有用户关联才形成关联', () {
    test('同名同 IP 的手动主机和目录设备：不自动关联；用户关联后只多一个绑定，其余逐字段不变', () async {
      final manual = manualHost('m', 'nas', '100.64.0.1');
      await vault().upsertHost(manual);
      final p = provider();
      await p.addSource(catalogId: 'ts-a');
      await p.refreshWithToken('ts-a', 'tok');
      expect((await p.links()).records, isEmpty);

      final before = (await hostById('m')).data;
      requests.clear();
      await p.linkHost(hostId: 'm', catalogId: 'ts-a', deviceId: '1');
      expect(requests, isEmpty, reason: '关联不发任何请求，也不连接设备');

      final after = await hostById('m');
      final binding = CatalogBinding.of(after)!;
      expect((binding.catalogId, binding.deviceId), ('ts-a', '1'));
      expect(binding.appliedAddress, isNull);
      Map<String, Object?> rest(Map<String, dynamic> d) => {...d}
        ..remove(CatalogBinding.key)
        ..remove('updatedAt');
      expect(rest(after.data), rest(before));

      final records = (await p.links()).records.toList();
      expect(records.single.refs, {
        hostDeviceRef(after),
        catalogDeviceRef('ts-a', '1'),
      });

      // 手动关联的主机地址不跟随目录：appliedAddress 是空的。
      devices = [device('1', 'nas', '100.64.0.99')];
      expect((await p.refreshWithToken('ts-a', 'tok')).hostsReaddressed, 0);
      expect((await hostById('m')).hostname, '100.64.0.1');
    });

    test('拒绝：主机已关联别的设备、设备已关联别的主机、设备不在缓存或不见了、主机不存在', () async {
      final p = provider();
      await p.addSource(catalogId: 'ts-a');
      await p.refreshWithToken('ts-a', 'tok');
      await import('ts-a', ['1']);
      await vault().upsertHost(manualHost('m', 'spare', '10.0.0.5'));

      Future<void> refused(String host, String device) => expectLater(
            p.linkHost(hostId: host, catalogId: 'ts-a', deviceId: device),
            throwsA(isA<CatalogLinkRefused>()),
          );
      await refused('imported-0', '2'); // 主机已关联设备 1
      await refused('m', '1'); // 设备 1 已关联 imported-0
      await refused('m', 'nope'); // 缓存里没有
      await refused('ghost', '2'); // 主机不存在
      devices = [device('1', 'nas', '100.64.0.1')];
      await p.refreshWithToken('ts-a', 'tok'); // 完整非空列表里没有 2 → 不见了
      await refused('m', '2');
      expect(CatalogBinding.of(await hostById('m')), isNull);
    });
  });

  group('DEV02 移除来源、断开一条、重启、恢复', () {
    test('移除来源：主机与用户字段、关联都留着；恢复同一来源 ID 后重新对上，地址继续跟随', () async {
      final p = provider();
      await p.addSource(catalogId: 'ts-a', label: '家里');
      await p.refreshWithToken('ts-a', 'tok');
      await import('ts-a', ['1', '2']);
      await vault().upsertHost(manualHost('m', 'other', '10.0.0.5'));
      final before = {
        for (final h in (await saved()).hosts) h.id: fields(h),
      };
      final knownBefore = (await saved()).extras['knownHosts'];

      await p.removeSource('ts-a');
      expect({
        for (final h in (await saved()).hosts) h.id: fields(h),
      }, before);
      expect((await p.links()).records, hasLength(2));
      final missing = await p.missingSources();
      expect(missing.single.catalogId, 'ts-a');
      expect(missing.single.hosts.map((h) => h.id),
          unorderedEquals(['imported-0', 'imported-1']));

      // 重启：关联存在保险库的主机上，不在内存里。
      container = await restart();
      final q = provider();
      expect(
        (await q.links()).records.map((r) => r.refs).toList(),
        unorderedEquals([
          {
            hostDeviceRef(await hostById('imported-0')),
            catalogDeviceRef('ts-a', '1')
          },
          {
            hostDeviceRef(await hostById('imported-1')),
            catalogDeviceRef('ts-a', '2')
          },
        ]),
      );

      // 用户在编辑器里断开其中一台（编辑器保存时就是去掉绑定字段）：只断这一条。
      await vault().updateHost(
        'imported-1',
        (h) => HostProfile({...h.data}..remove(CatalogBinding.key)),
      );
      expect((await q.links()).records.single.refs,
          contains(catalogDeviceRef('ts-a', '1')));

      // 恢复同一个来源 ID：只建空缓存，不发请求、不改主机。
      requests.clear();
      final restored = await q.restoreSource('ts-a', label: '家里');
      expect(restored.devices, isEmpty);
      expect(requests, isEmpty);
      expect(await q.missingSources(), isEmpty);

      devices = [device('1', 'nas', '100.64.0.77')];
      final outcome = await q.refreshWithToken('ts-a', 'tok');
      expect(outcome.hostsReaddressed, 1);
      final back = await hostById('imported-0');
      expect(back.hostname, '100.64.0.77');
      expect(back.username, 'ops');
      expect(back.port, 2200);
      // 断开的那台不再跟随，手动主机一个字段都没变。
      expect((await hostById('imported-1')).hostname, '100.64.0.2');
      expect(fields(await hostById('m')), before['m']);
      expect((await saved()).extras['knownHosts'], knownBefore);
    });

    test('恢复被拒：没有主机引用、来源已在本机（不覆盖缓存）', () async {
      final p = provider();
      await expectLater(
          p.restoreSource('ts-x'), throwsA(isA<CatalogLinkRefused>()));
      await p.addSource(catalogId: 'ts-a');
      await p.refreshWithToken('ts-a', 'tok');
      await import('ts-a', ['1']);
      await expectLater(p.restoreSource('ts-a'), throwsStateError);
      final cache =
          await container.read(catalogCacheRepositoryProvider).load('ts-a');
      expect(cache!.devices.keys, containsAll(['1', '2']));
    });

    test('更新版本写的缓存：不算缺失，恢复也不覆盖它', () async {
      final p = provider();
      await p.addSource(catalogId: 'ts-a');
      await p.refreshWithToken('ts-a', 'tok');
      await import('ts-a', ['1']);
      final file = File('${dir.path}/ts-a.json');
      final newer = jsonEncode({
        ...jsonDecode(await file.readAsString()) as Map<String, Object?>,
        'schemaVersion': 99,
      });
      await file.writeAsString(newer);
      expect(await p.missingSources(), isEmpty);
      await expectLater(
          p.restoreSource('ts-a'), throwsA(isA<CatalogCacheTooNew>()));
      expect(await file.readAsString(), newer);
    });
  });

  test('同一台设备被两台主机绑定（同步来的旧数据）：只算一条关联，两台主机的绑定都不删', () async {
    final p = provider();
    await p.addSource(catalogId: 'ts-a');
    await p.refreshWithToken('ts-a', 'tok');
    await import('ts-a', ['1']);
    final copy = HostProfile({
      ...(await hostById('imported-0')).data,
      'id': 'copy',
      'label': 'nas copy',
    });
    await vault().upsertHost(copy);
    final links = await p.links();
    expect(links.records, hasLength(1));
    expect(CatalogBinding.of(await hostById('copy')), isNotNull);
    await expectLater(
      p.linkHost(hostId: 'copy', catalogId: 'ts-a', deviceId: '2'),
      throwsA(isA<CatalogLinkRefused>()),
    );
  });
}
