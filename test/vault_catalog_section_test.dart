import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/tailscale_catalog_access.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:shun/infrastructure/tailscale/tailscale_api.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';
import 'package:shun/presentation/screens/tailscale_catalog_screen.dart';
import 'package:shun/presentation/screens/vault_screen.dart';
import 'package:shun/presentation/widgets/catalog_import_sheet.dart';

// R43 / UX09：主机列表里的 Tailscale 分节。
// 两个来源里放同名、同 IP、同设备 ID 的设备；控制面已连接 / 未连接 / 不知道 / 列表里不见了；
// 一个来源缓存 3 小时前、另一个 3 天前且最近一次读取失败。
// 服务器是 MockClient（按官方响应形状回），缓存仓库在内存里（widget 测试的假时钟下真实文件读写不会完成）。

class _MemoryRepository extends CatalogCacheRepository {
  _MemoryRepository() : super(() async => Directory.systemTemp);
  final caches = <String, CatalogCache>{};

  @override
  Future<CatalogCache?> load(String catalogId) async => caches[catalogId];
  @override
  Future<List<CatalogCache>> loadAll() async => caches.values.toList();
  @override
  Future<void> save(CatalogCache cache) async =>
      caches[cache.catalogId] = cache;
  @override
  Future<void> delete(String catalogId) async => caches.remove(catalogId);
}

class _MemoryBackend implements CatalogSecretBackend {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

Map<String, Object?> device(String id, String hostname, String ip,
        {Object? connected}) =>
    {
      'id': id,
      'name': '$hostname.tail0000.ts.net',
      'hostname': hostname,
      'addresses': [ip],
      'os': 'linux',
      if (connected != null) 'connectedToControl': connected,
    };

CatalogCache source(
  String id,
  String label,
  List<Map<String, Object?>> devices,
  DateTime at, {
  Set<String> missing = const {},
  bool failedSince = false,
}) {
  var cache = CatalogCache(catalogId: id, tailnet: '-', label: label).merge(
      TailscaleDeviceSnapshot.parse(jsonEncode({'devices': devices})), at);
  cache = cache.copyWith(devices: {
    for (final MapEntry(:key, :value) in cache.devices.entries)
      key: missing.contains(key) ? value.markMissing(at) : value,
  });
  return failedSince
      ? cache.recordFailure('HTTP 500', at.add(const Duration(hours: 1)))
      : cache;
}

/// 一台绑定到目录设备的主机。[applied] 为地址上次由目录写入的值；和 hostname 一样就还跟随目录。
Map<String, Object?> bound(
  String id,
  String label,
  String catalogId,
  String deviceId, {
  String hostname = '100.64.0.1',
  String? applied = '100.64.0.1',
  String username = 'admin',
  int port = 2222,
  Map<String, Object?> extra = const {},
}) =>
    {
      'id': id,
      'label': label,
      'hostname': hostname,
      'username': username,
      'port': port,
      'protocol': 'ssh',
      CatalogBinding.key: CatalogBinding(
        catalogId: catalogId,
        deviceId: deviceId,
        appliedAddress: applied,
      ).toJson(),
      ...extra,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late _MemoryRepository repo;
  late _MemoryBackend secrets;
  late List<http.Request> requests;
  late List<Map<String, Object?>> listed;
  late Completer<void>? gate;
  late ProviderContainer container;

  final now = DateTime.now();

  Future<void> open(
    WidgetTester tester, {
    List<Map<String, Object?>> extraHosts = const [],
    List<String> groups = const [],
  }) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'shun_vault_v1': jsonEncode({
        'hosts': [
          bound('a-nas', '家里 NAS', 'ts-home', '1'),
          // 另一个来源里的同名、同 IP、同设备 ID：是另一台主机，各用各的账号。
          bound('b-nas', '公司 NAS', 'ts-work', '1',
              username: 'ops', port: 22),
          // 用户改过地址：不再跟随目录。
          bound('a-pc', '书房', 'ts-home', '3',
              hostname: 'pc.lan', applied: '100.64.0.3'),
          {
            'id': 'plain',
            'label': 'plain',
            'hostname': '192.0.2.10',
            'username': 'root',
            'protocol': 'ssh',
          },
          ...extraHosts,
        ],
        'keys': const [],
        'snippets': const [],
        'customGroups': groups,
      }),
      'shun_settings_v1': jsonEncode({'serverViewMode': 'list'}),
    });
    final vault = await VaultRepository.open();
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/v2/oauth/token') {
        return http.Response(
          jsonEncode({
            'access_token': 'tok',
            'token_type': 'Bearer',
            'expires_in': 3600,
            'scope': 'devices:core:read',
          }),
          200,
        );
      }
      await gate?.future;
      return http.Response(jsonEncode({'devices': listed}), 200);
    });
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(vault),
      catalogCacheRepositoryProvider.overrideWithValue(repo),
      tailscaleCatalogAccessProvider.overrideWithValue(TailscaleCatalogAccess(
        TailscaleCatalogSecretStore(secrets),
        (credential) => TailscaleCatalogClient.fixture(
          client,
          Uri.parse('http://127.0.0.1:1'),
          credential,
        ),
      )),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: VaultScreen())),
    ));
    await tester.pumpAndSettle();
  }

  Finder inGroup(String catalogId, Finder matching) => find.descendant(
      of: find.byKey(ValueKey('vault-catalog-$catalogId')), matching: matching);
  Finder key(String value) => find.byKey(ValueKey(value));
  final sections = key('vault-catalog-sections');

  HostProfile saved(String id) => container
      .read(vaultControllerProvider)
      .data!
      .hosts
      .firstWhere((h) => h.id == id);
  Object? fields(String id) => jsonDecode(jsonEncode(saved(id).data));

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    repo = _MemoryRepository();
    secrets = _MemoryBackend();
    requests = [];
    gate = null;
    repo.caches['ts-home'] = source(
      'ts-home',
      'Home',
      [
        device('1', 'nas', '100.64.0.1', connected: true),
        device('2', 'laptop', '100.64.0.2', connected: false),
        device('3', 'pc', '100.64.0.3'),
      ],
      now.subtract(const Duration(hours: 3, minutes: 5)),
    );
    repo.caches['ts-work'] = source(
      'ts-work',
      'Work',
      [
        device('1', 'nas', '100.64.0.1', connected: false),
        device('4', 'build', '100.64.0.9', connected: true),
      ],
      now.subtract(const Duration(days: 3, hours: 2)),
      missing: {'4'},
      failedSince: true,
    );
    // 只有 Home 在本机存了 OAuth client；Work 每次要粘 token。
    await TailscaleCatalogSecretStore(secrets).saveOAuthClient(
      'ts-home',
      const OAuthClientCredential(clientId: 'cid', clientSecret: 'csecret'),
    );
    listed = [
      device('1', 'nas', '100.64.0.50', connected: false),
      device('2', 'laptop', '100.64.0.2', connected: false),
      device('3', 'pc', '100.64.0.33', connected: true),
    ];
  });

  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorage, null));

  testWidgets('两来源同名同 IP：各在各的组、各是各的主机，不合并；普通列表里不重复', (tester) async {
    await open(tester);
    expect(inGroup('ts-home', key('vault-catalog-host-a-nas')), findsOneWidget);
    expect(inGroup('ts-work', key('vault-catalog-host-b-nas')), findsOneWidget);
    expect(inGroup('ts-home', key('vault-catalog-host-b-nas')), findsNothing);
    expect(inGroup('ts-work', key('vault-catalog-host-a-nas')), findsNothing);
    expect(inGroup('ts-home', find.text('家里 NAS')), findsOneWidget,
        reason: '显示的是用户起的别名，不是目录里的设备名');
    expect(inGroup('ts-home', find.text('admin@100.64.0.1:2222')), findsOneWidget);
    expect(inGroup('ts-work', find.text('ops@100.64.0.1:22')), findsOneWidget);
    // 两边的设备 1 都已导入，不再当成没导入的设备列出来。
    expect(key('vault-catalog-device-ts-home-1'), findsNothing);
    expect(key('vault-catalog-device-ts-work-1'), findsNothing);
    expect(key('vault-catalog-device-ts-home-2'), findsOneWidget);
    // 每台只出现一次：在分节里就不在普通列表里。
    expect(key('vault-host-menu-a-nas'), findsOneWidget);
    expect(key('vault-host-menu-plain'), findsOneWidget);
    expect(find.descendant(of: sections, matching: key('vault-host-menu-plain')),
        findsNothing);
  });

  testWidgets('控制面状态用字写、带缓存时间和多久前；不说在线；打开列表不发请求', (tester) async {
    await open(tester);
    String status(String k) => tester
        .widget<Text>(find.descendant(
            of: key(k), matching: find.byType(Text), matchRoot: true))
        .data!;
    expect(status('vault-catalog-status-a-nas'), 'Tailscale 控制面：已连接');
    expect(status('vault-catalog-status-b-nas'), 'Tailscale 控制面：未连接',
        reason: '同一个设备 ID，另一个来源说的是另一回事');
    expect(status('vault-catalog-status-a-pc'), 'Tailscale 控制面：不知道');
    expect(status('vault-catalog-device-status-ts-home-2'),
        'Tailscale 控制面：未连接');
    expect(status('vault-catalog-device-status-ts-work-4'),
        '目录：最近完整列表里没有它',
        reason: '不见了的设备不再拿上次的「已连接」说事');
    expect(status('vault-catalog-age-ts-home'), endsWith('3 小时前'));
    expect(status('vault-catalog-age-ts-work'), endsWith('3 天前'));
    expect(inGroup('ts-work', find.textContaining('最近一次读取失败：')),
        findsOneWidget);
    expect(inGroup('ts-home', find.textContaining('最近一次读取失败')),
        findsNothing);
    expect(find.textContaining('在线'), findsNothing);
    expect(find.textContaining('离线'), findsNothing);
    expect(find.textContaining('不代表手机能连上它'), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('没导入的设备点了走导入页，不连接；导入后变成这一组里的主机', (tester) async {
    await open(tester);
    await tester.tap(key('vault-catalog-device-ts-home-2'));
    await tester.pumpAndSettle();
    expect(find.byType(CatalogImportPage), findsOneWidget);
    expect(container.read(sessionControllerProvider).sessions, isEmpty);
    expect(container.read(sessionControllerProvider).pendingConnections,
        isEmpty);
    await tester.enterText(key('catalog-import-username'), 'me');
    await tester.pumpAndSettle();
    await tester.tap(key('catalog-import-confirm'));
    await tester.pumpAndSettle();
    expect(find.byType(CatalogImportPage), findsNothing);
    expect(key('vault-catalog-device-ts-home-2'), findsNothing);
    final added = container
        .read(vaultControllerProvider)
        .data!
        .hosts
        .where((h) => CatalogBinding.of(h)?.deviceId == '2')
        .single;
    expect(CatalogBinding.of(added)!.catalogId, 'ts-home');
    expect(inGroup('ts-home', key('vault-catalog-host-${added.id}')),
        findsOneWidget);
    expect(container.read(sessionControllerProvider).sessions, isEmpty,
        reason: '导入只建主机，不连');
    expect(requests, isEmpty);
  });

  testWidgets('刷新：点了才发；刷着的时候不能再点；只改跟随目录的地址，别名、账号、端口、另一来源都不动', (tester) async {
    await open(tester);
    final work = fields('b-nas');
    final pc = fields('a-pc');
    gate = Completer<void>();
    await tester.tap(key('vault-catalog-refresh-ts-home'));
    await tester.pump();
    await tester.pump();
    expect(key('vault-catalog-refresh-ts-home'), findsNothing,
        reason: '正在刷的来源只显示进度，不能再发一次');
    expect(inGroup('ts-home', find.byType(CircularProgressIndicator)),
        findsOneWidget);
    gate!.complete();
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.url.path.contains('/devices')), hasLength(1));

    final nas = saved('a-nas');
    expect(nas.hostname, '100.64.0.50', reason: '地址还跟随目录：跟着改');
    expect(nas.label, '家里 NAS');
    expect(nas.username, 'admin');
    expect(nas.port, 2222);
    expect(fields('a-pc'), pc, reason: '用户改过地址：一个字段都不动');
    expect(fields('b-nas'), work, reason: '另一个来源的同名同 IP 主机不动');
    String status(String k) => tester
        .widget<Text>(find.descendant(
            of: key(k), matching: find.byType(Text), matchRoot: true))
        .data!;
    expect(status('vault-catalog-status-a-nas'), 'Tailscale 控制面：未连接');
    expect(status('vault-catalog-age-ts-home'), endsWith('刚刚'));
    expect(status('vault-catalog-age-ts-work'), endsWith('3 天前'));
    expect(find.textContaining('读取成功，设备数：3'), findsOneWidget);
  });

  testWidgets('没存凭据的来源：刷新打开来源页，不发请求', (tester) async {
    await open(tester);
    await tester.tap(key('vault-catalog-refresh-ts-work'));
    await tester.pumpAndSettle();
    expect(find.byType(CatalogSourceScreen), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('收起只管显示；移除来源后它的主机回到普通列表，主机和关联都不动', (tester) async {
    await open(tester);
    final before = fields('b-nas');
    await tester.tap(key('vault-catalog-toggle-ts-home'));
    await tester.pumpAndSettle();
    expect(key('vault-catalog-host-a-nas'), findsNothing);
    expect(key('vault-catalog-device-ts-home-2'), findsNothing);
    expect(key('vault-catalog-host-b-nas'), findsOneWidget);
    await tester.tap(key('vault-catalog-toggle-ts-home'));
    await tester.pumpAndSettle();
    expect(key('vault-catalog-host-a-nas'), findsOneWidget);

    await tester.tap(key('vault-catalog-settings-ts-work'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除这个来源'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移除来源'));
    await tester.pumpAndSettle();

    expect(find.byType(CatalogSourceScreen), findsNothing);
    expect(key('vault-catalog-ts-work'), findsNothing);
    expect(key('vault-catalog-ts-home'), findsOneWidget);
    expect(key('vault-host-menu-b-nas'), findsOneWidget);
    expect(find.descendant(of: sections, matching: key('vault-host-menu-b-nas')),
        findsNothing,
        reason: '来源不在本机了，主机回到普通列表');
    expect(fields('b-nas'), before, reason: '主机和它上面的关联都留着');
    expect(repo.caches.keys, ['ts-home']);
    expect(requests, isEmpty);
  });

  testWidgets('藏起来的已导入主机：行不见了，对应设备也不变成「没导入」', (tester) async {
    await open(tester, extraHosts: [
      bound('h-nas', '藏起来的', 'ts-home', '2',
          hostname: '100.64.0.2',
          applied: '100.64.0.2',
          extra: {hiddenHostKey: true}),
    ]);
    expect(key('vault-catalog-host-h-nas'), findsNothing);
    expect(key('vault-catalog-device-ts-home-2'), findsNothing);
    expect(key('vault-show-hidden'), findsOneWidget);
    await tester.tap(key('vault-show-hidden'));
    await tester.pumpAndSettle();
    expect(inGroup('ts-home', key('vault-hidden-host-h-nas')), findsOneWidget);
  });

  testWidgets('搜索只留命中的组；选了自定义分组就不分节', (tester) async {
    await open(tester, extraHosts: [
      {
        'id': 'grouped',
        'label': 'grouped',
        'hostname': '192.0.2.20',
        'username': 'root',
        'protocol': 'ssh',
        'group': 'NAS',
      },
      bound('g-nas', '分组里的 NAS', 'ts-home', '9', extra: {'group': 'NAS'}),
    ], groups: [
      'NAS'
    ]);
    await tester.enterText(find.byType(TextField).first, '100.64.0.2');
    await tester.pumpAndSettle();
    expect(key('vault-catalog-device-ts-home-2'), findsOneWidget);
    expect(key('vault-catalog-ts-work'), findsNothing);
    expect(key('vault-catalog-host-a-nas'), findsNothing);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.tap(key('vault-group-chip-NAS'));
    await tester.pumpAndSettle();
    expect(sections, findsNothing);
    expect(key('vault-host-menu-g-nas'), findsOneWidget,
        reason: '选了分组：那一组的主机都在普通列表里，包括目录导入的');
    expect(key('vault-host-menu-grouped'), findsOneWidget);
    expect(key('vault-host-menu-a-nas'), findsNothing);
  });
}
