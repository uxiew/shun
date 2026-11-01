import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/catalog_overview.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/tailscale_catalog_access.dart';
import 'package:shun/application/tailscale_catalog_provider.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:shun/infrastructure/tailscale/tailscale_api.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';
import 'package:shun/presentation/widgets/catalog_text.dart';

// R67 / TSC11：Tailscale 在线状态前台自动刷新。服务器是 MockClient，没有真实 Tailscale 账号：
// 这里证明 App 什么时候发请求、发几次，不证明 Tailscale 真实的限流和 connectedToControl 的行为。

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

const _home = 'ts-home';
const _nokey = 'ts-nokey';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryRepository repo;
  late _MemoryBackend secrets;
  late List<http.Request> requests;
  late List<http.Response> replies;
  late ProviderContainer container;
  late DateTime clock;

  http.Response ok() => http.Response(
        jsonEncode({
          'devices': [
            {'id': '1', 'hostname': 'nas', 'connectedToControl': true},
          ],
        }),
        200,
      );

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
    SharedPreferences.setMockInitialValues({});
    repo = _MemoryRepository();
    secrets = _MemoryBackend();
    requests = [];
    replies = [];
    clock = DateTime.utc(2026, 11, 1, 12);
    final client = MockClient((request) async {
      requests.add(request);
      return replies.isEmpty ? ok() : replies.removeAt(0);
    });
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(await VaultRepository.open()),
      catalogCacheRepositoryProvider.overrideWithValue(repo),
      tailscaleCatalogAccessProvider.overrideWithValue(TailscaleCatalogAccess(
        TailscaleCatalogSecretStore(secrets),
        (credential) => TailscaleCatalogClient.fixture(
          client,
          Uri.parse('http://127.0.0.1:1'),
          credential,
        ),
      )),
      catalogRefresherProvider.overrideWith((ref) => CatalogRefresher(
            access: ref.watch(tailscaleCatalogAccessProvider),
            repository: ref.watch(catalogCacheRepositoryProvider),
            hosts: ref.watch(catalogHostsProvider),
            now: () => clock,
          )),
    ]);
    addTearDown(container.dispose);
    repo.caches[_home] = const CatalogCache(catalogId: _home, tailnet: '-');
    await TailscaleCatalogSecretStore(secrets)
        .saveAccessToken(_home, 'tskey-api-TEST');
  });

  /// 走过 [wait] 这么久：定时器用的假时钟和缓存、控制器看的 [clock] 一起往前。
  Future<void> walk(WidgetTester tester, Duration wait) async {
    clock = clock.add(wait);
    await tester.pump(wait);
    await tester.pump();
  }

  CatalogOverviewController controller() => CatalogOverviewController(
        repository: repo,
        catalog: container.read(tailscaleCatalogProvider),
        now: () => clock,
      );

  testWidgets('前台停在「连接」页：马上读一次，之后隔满 60 秒才读', (tester) async {
    final overview = controller();

    overview.setVisible(true);
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(1));
    expect(repo.caches[_home]!.lastSuccess, isNotNull);

    await walk(tester, const Duration(seconds: 30));
    expect(requests, hasLength(1), reason: '没满 60 秒不读');
    await walk(tester, const Duration(seconds: 31));
    expect(requests, hasLength(2));
    overview.dispose();
  });

  // 设备上撞到的（tool/r67-device.py）：切回「连接」页时页面自己也 reload。上一轮的 reload 结果被后来的扔掉，
  // 自动读看到的还是空列表，以为一个存了 key 的来源都没有，定时器排不上，要等下次切页。
  testWidgets('切回这页时页面也在 reload：第一个来源也要读，定时器也要排上', (tester) async {
    final added = repo.caches.remove(_home)!;
    final overview = controller();
    overview.setVisible(true);
    await tester.pump();
    await tester.pump();
    expect(overview.state, isEmpty, reason: '还没有来源');

    // 到设置里加上第一个来源、存好 key，再回「连接」页。
    overview.setVisible(false);
    repo.caches[_home] = added;
    overview.setVisible(true);
    unawaited(overview.reload());
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(1), reason: '马上读');

    await walk(tester, const Duration(seconds: 61));
    expect(requests, hasLength(2), reason: '定时器排上了');
    overview.dispose();
  });

  testWidgets('切到别的页、切后台：一条请求都不发；回来时够久了才补一次', (tester) async {
    final overview = controller();
    overview.setVisible(true);
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(1));

    overview.setVisible(false);
    await walk(tester, const Duration(minutes: 5));
    expect(requests, hasLength(1), reason: '别的页看不到状态');

    overview.setVisible(true);
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(2), reason: '回到这页就补一次');

    overview.setForeground(false);
    await walk(tester, const Duration(minutes: 5));
    expect(requests, hasLength(2), reason: '后台不发');

    overview.setForeground(true);
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(3));

    // 回来得太快（比如下拉通知栏）：不够 60 秒不补。
    overview.setForeground(false);
    overview.setForeground(true);
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(3));
    overview.dispose();
  });

  testWidgets('没存 key 的来源不发请求，也不留定时器', (tester) async {
    repo.caches
      ..remove(_home)
      ..[_nokey] = const CatalogCache(catalogId: _nokey, tailnet: '-');
    final overview = controller();
    overview.setVisible(true);
    await tester.pump();
    await tester.pump();
    expect(requests, isEmpty);
    // 故意不 dispose：还留着定时器的话，testWidgets 收尾时会报 pending timer。
  });

  testWidgets('读失败不连续重试：隔 10 分钟再试，手动刷新不受限', (tester) async {
    final overview = controller();
    replies.add(http.Response('{"message":"boom"}', 500));
    overview.setVisible(true);
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(1));
    expect(repo.caches[_home]!.lastAttempt!.ok, isFalse);

    await walk(tester, const Duration(minutes: 9));
    expect(requests, hasLength(1));

    // 手动点刷新随时能读，这次也还是失败。
    replies.add(http.Response('{"message":"boom"}', 500));
    await overview.refresh(_home);
    expect(requests, hasLength(2));

    await walk(tester, const Duration(minutes: 9));
    expect(requests, hasLength(2), reason: '手动失败也从那时起算 10 分钟');
    await walk(tester, const Duration(minutes: 2));
    expect(requests, hasLength(3));
    expect(repo.caches[_home]!.lastAttempt!.ok, isTrue);
    overview.dispose();
  });

  testWidgets('429 按 Retry-After 等，不是按 10 分钟', (tester) async {
    final overview = controller();
    replies.add(http.Response('{"message":"slow down"}', 429,
        headers: {'retry-after': '3600'}));
    overview.setVisible(true);
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(1));

    await walk(tester, const Duration(minutes: 30));
    expect(requests, hasLength(1), reason: 'Tailscale 说了等一小时');
    await walk(tester, const Duration(minutes: 31));
    expect(requests, hasLength(2));
    overview.dispose();
  });

  testWidgets('打开设备页：够久没读才读，刚读过不读', (tester) async {
    final overview = controller();
    expect(await overview.refreshIfDue(_home), isNotNull);
    expect(requests, hasLength(1));
    expect(await overview.refreshIfDue(_home), isNull);
    expect(requests, hasLength(1));
    clock = clock.add(const Duration(seconds: 61));
    expect(await overview.refreshIfDue(_home), isNotNull);
    expect(requests, hasLength(2));
    expect(await overview.refreshIfDue('ts-unknown'), isNull);
    expect(requests, hasLength(2));
    overview.dispose();
  });

  test('provider 跟着底栏：停在「连接」页才算可见', () async {
    final overview = container.read(catalogOverviewProvider.notifier);
    await pumpEventQueue();
    expect(requests, hasLength(1), reason: '默认就在「连接」页');
    container.read(homeTabProvider.notifier).state = 1;
    await pumpEventQueue();
    expect(requests, hasLength(1));
    expect(overview.mounted, isTrue);
  });

  group('状态过期', () {
    final now = DateTime.utc(2026, 11, 1, 12);
    CatalogCache cacheAt(DateTime at, {bool? connected = true}) =>
        const CatalogCache(catalogId: _home, tailnet: '-').merge(
          TailscaleDeviceSnapshot.parse(jsonEncode({
            'devices': [
              {
                'id': '1',
                if (connected != null) 'connectedToControl': connected,
              },
            ],
          })),
          at,
        );

    test('10 分钟内照 Tailscale 说的', () {
      final cache = cacheAt(now.subtract(const Duration(minutes: 9)));
      final record = cache.devices['1'];
      expect(catalogStatusStale(cache, now), isFalse);
      expect(deviceOnline(record, stale: false), DeviceOnline.online);
      expect(
          deviceOnlineText(record, now, statusAt: cache.lastSuccess!.at), '在线');
    });

    test('过了 10 分钟不画绿点，也不画灰点，文字写明多久前', () {
      for (final connected in [true, false]) {
        final cache = cacheAt(
          now.subtract(const Duration(hours: 3)),
          connected: connected,
        );
        final record = cache.devices['1'];
        expect(catalogStatusStale(cache, now), isTrue);
        expect(deviceOnline(record, stale: true), DeviceOnline.unknown);
        expect(deviceOnlineColor(DeviceOnline.unknown), isNull);
        expect(
          deviceOnlineText(record, now, statusAt: cache.lastSuccess!.at),
          connected ? '3 小时前：在线' : '3 小时前：离线',
        );
      }
    });

    test('手机时钟往回调过：不说负数，也不算过期', () {
      final cache = cacheAt(now.add(const Duration(hours: 3)));
      expect(catalogStatusStale(cache, now), isFalse);
      expect(
        deviceOnlineText(cache.devices['1'], now,
            statusAt: cache.lastSuccess!.at),
        '在线',
      );
    });

    test('不见了的设备一直写不见了，不加时间前缀', () {
      final cache = cacheAt(now.subtract(const Duration(hours: 3)));
      final gone = cache.devices['1']!.markMissing(now);
      expect(deviceOnline(gone, stale: true), DeviceOnline.gone);
      expect(
        deviceOnlineText(gone, now, statusAt: cache.lastSuccess!.at),
        '最近的设备列表里没有它了',
      );
    });
  });
}
