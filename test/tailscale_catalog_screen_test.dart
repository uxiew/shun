import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/tailscale_catalog_access.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:shun/infrastructure/tailscale/tailscale_api.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/screens/tailscale_catalog_screen.dart';
import 'package:shun/presentation/screens/tailscale_settings_screen.dart';
import 'package:shun/presentation/ui/non_modal_panel.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/secret_content.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/route_editor_actions.dart';

// R13 界面，R26 按所有者反馈改过：目录页显示缓存时间和「不完整」（TSC05），在线状态照 Tailscale 写、
// 不说能连上（TSC03 的底线），key 框遮挡、tskey-api 不保存（TSC09），点设备按来源默认值导入、连接前问登录，
// 编辑器里看得到来源和跟随状态。
// 服务器是 MockClient，缓存仓库在内存里（widget 测试的假时钟下真实文件读写不会完成）。

class MemoryCatalogRepository extends CatalogCacheRepository {
  MemoryCatalogRepository() : super(() async => Directory.systemTemp);
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

/// 和真实仓库在全新安装时一样：没有任何来源时返回 const 空列表。
class _ConstEmptyRepository extends MemoryCatalogRepository {
  @override
  Future<List<CatalogCache>> loadAll() async => const [];
}

class MemoryBackend implements CatalogSecretBackend {
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

// 状态过了 10 分钟就不再当真（R67），这里要的是刚读到的。
final at = DateTime.now().toUtc().subtract(const Duration(minutes: 1));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late MemoryCatalogRepository repo;
  late MemoryBackend secrets;
  late List<http.Response> replies;
  late List<http.Request> requests;
  late VaultRepository vault;

  Future<void> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/v2/oauth/token') {
        return http.Response(
          jsonEncode({
            'access_token': 'tok-oauth',
            'token_type': 'Bearer',
            'expires_in': 3600,
            'scope': 'devices:core:read',
          }),
          200,
        );
      }
      return replies.length > 1 ? replies.removeAt(0) : replies.first;
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
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
      ],
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    vault = await VaultRepository.open();
    repo = MemoryCatalogRepository();
    secrets = MemoryBackend();
    requests = [];
    replies = [
      http.Response(
        jsonEncode({
          'devices': [
            device('1', 'nas', '100.64.0.1', connected: true),
            device('2', 'laptop', '100.64.0.2'),
          ],
        }),
        200,
      ),
    ];
  });

  /// 一个已有来源：上次列表不完整（有一条缺 id），设备 2 的控制面状态不知道。
  void seedIncomplete() {
    final snapshot = TailscaleDeviceSnapshot.parse(jsonEncode({
      'devices': [
        device('1', 'nas', '100.64.0.1', connected: true),
        device('2', 'laptop', '100.64.0.2'),
        {'name': 'no-id'},
      ],
    }));
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home')
            .merge(snapshot, at);
  }

  String allText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join('\n');

  testWidgets('编辑器：显示来源、设备、目录状态和地址是否跟随；断开关联后保存只去掉关联', (tester) async {
    seedIncomplete();
    final host = HostProfile({
      ...HostProfile.create(
        id: 'h1',
        label: 'nas',
        hostname: '100.64.0.1',
        username: 'ubuntu',
      ).data,
      CatalogBinding.key: const CatalogBinding(
        catalogId: 'ts-home',
        deviceId: '1',
        appliedAddress: '100.64.0.1',
      ).toJson(),
    });
    HostProfile? result;
    await open(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await Navigator.push<HostProfile>(
              context,
              MaterialPageRoute(builder: (_) => HostEditor(host: host)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await openAdvanced(tester);

    final section = find.byKey(const ValueKey('catalog-source-section'));
    expect(section, findsOneWidget);
    String text() => tester
        .widgetList<Text>(
            find.descendant(of: section, matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .join('\n');
    expect(text(), contains('来源：home'));
    expect(text(), contains('设备：nas · 1'));
    expect(text(), contains('目录状态：最近一次列表里有它'));
    expect(text(), contains('在线'));
    expect(text(), isNot(contains('控制面')));
    expect(text(), contains('地址跟随目录'));

    await tester.enterText(
        find.widgetWithText(TextFormField, '主机名 / IP'), 'nas.lan');
    await tester.pumpAndSettle();
    expect(text(), contains('地址不跟随目录'));

    await tester.tap(find.byKey(const ValueKey('catalog-unlink')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.data.containsKey(CatalogBinding.key), isFalse);
    expect(result!.username, 'ubuntu');
    expect(result!.hostname, 'nas.lan');
  });

  Future<void> saveHosts(List<Map<String, Object?>> hosts) =>
      vault.saveVault(VaultData.fromJson({
        'hosts': hosts,
        'keys': [],
        'snippets': [],
        'customGroups': [],
      }));

  Map<String, Object?> boundHost(
          String id, String label, String catalogId, String deviceId,
          {String? applied}) =>
      {
        ...HostProfile.create(
                id: id, label: label, hostname: '100.64.0.1', username: 'u')
            .toJson(),
        CatalogBinding.key: CatalogBinding(
          catalogId: catalogId,
          deviceId: deviceId,
          appliedAddress: applied,
        ).toJson(),
      };

  testWidgets('TSC05/R26：来源页显示缓存时间和「不完整」；在线状态照 Tailscale 写，不说能连、SSH 可用',
      (tester) async {
    seedIncomplete();
    await open(tester, const TailscaleCatalogScreen());
    expect(find.text('home'), findsOneWidget);
    final time = catalogTimeForTest(at);
    expect(find.text('缓存时间：$time'), findsOneWidget);

    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    expect(find.text('缓存时间：$time'), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-incomplete')), findsOneWidget);
    expect(find.textContaining('1 条无法识别'), findsOneWidget);
    // 设备 1 连着 Tailscale：在线、绿点；设备 2 没报：不明、不画点（不能当成离线）。
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('在线状态不明'), findsOneWidget);
    expect(find.byKey(const ValueKey('presence-online')), findsOneWidget);
    expect(find.byKey(const ValueKey('presence-offline')), findsNothing);
    final text = allText(tester);
    for (final word in ['可连接', 'SSH 可用', '控制面']) {
      expect(text, isNot(contains(word)));
    }
    expect(requests, isEmpty); // 没存 key：打开页面不发请求
  });

  /// 从一个按钮打开 Tailscale 设置页，记下它返回的结果（设置页保存后会自己关掉）。
  Future<List<TailscaleSettingsResult?>> openSettings(
      WidgetTester tester, String? catalogId) async {
    final results = <TailscaleSettingsResult?>[];
    await open(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
                await openTailscaleSettings(context, catalogId: catalogId)),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  void seedSavedToken() {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    secrets.values['tailscale.catalog.ts-home.accessToken'] = 'tskey-api-OLD';
  }

  /// 存着 key 时：只有写死的圆点和改、删，没有输入框、没有「显示」，key 的内容不在界面上。
  void expectMaskedKey(WidgetTester tester) {
    expect(find.byKey(const ValueKey('ts-settings-saved-key')), findsOneWidget);
    expect(find.text('••••••••••••'), findsOneWidget);
    expect(find.byKey(const ValueKey('ts-settings-key')), findsNothing);
    expect(
        find.byKey(const ValueKey('ts-settings-change-key')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('ts-settings-forget-key')), findsOneWidget);
    expect(find.byIcon(Icons.visibility), findsNothing);
    expect(find.byIcon(Icons.visibility_off), findsNothing);
    expect(find.textContaining('tskey-'), findsNothing);
  }

  testWidgets('TSC09：设置页的 key 框一直遮着、关联想；tskey-api 读成功存进安全存储，不进缓存',
      (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    final results = await openSettings(tester, 'ts-home');
    final field =
        tester.widget<TextField>(find.byKey(const ValueKey('ts-settings-key')));
    expect(field.obscureText, isTrue);
    expect(field.enableSuggestions, isFalse);
    expect(field.autocorrect, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
    expect(find.byIcon(Icons.visibility), findsNothing, reason: '没有「显示」按钮');
    expect(find.byIcon(Icons.visibility_off), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-key')), 'tskey-api-CANARY');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();

    expect(requests.single.headers['authorization'], 'Bearer tskey-api-CANARY');
    expect(results.single?.catalogId, 'ts-home');
    expect(find.textContaining('读取成功，设备数：2'), findsOneWidget);
    expect(secrets.values,
        {'tailscale.catalog.ts-home.accessToken': 'tskey-api-CANARY'});
    expect(repo.caches['ts-home']!.devices, hasLength(2));
    expect(jsonEncode(repo.caches['ts-home']!.toJson()),
        isNot(contains('CANARY')));
  });

  testWidgets(
      'R26：tskey-client 当 OAuth client 用，client ID 从 secret 里取，读成功后存在本机',
      (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    await openSettings(tester, 'ts-home');
    await tester.enterText(find.byKey(const ValueKey('ts-settings-key')),
        ' tskey-client-kABC123CNTRL-s3cr3t ');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();

    final token = requests.first;
    expect(token.url.path, '/api/v2/oauth/token');
    expect(token.bodyFields['client_id'], 'kABC123CNTRL');
    expect(
        token.bodyFields['client_secret'], 'tskey-client-kABC123CNTRL-s3cr3t');
    expect(secrets.values.values,
        containsAll(['kABC123CNTRL', 'tskey-client-kABC123CNTRL-s3cr3t']));
    expect(repo.caches['ts-home']!.devices, hasLength(2));
  });

  testWidgets('R26：填错了种类的 key（auth key）直接说，不发请求、不关页面', (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    final results = await openSettings(tester, 'ts-home');
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-key')), 'tskey-auth-k1-xyz');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('auth key'), findsOneWidget);
    expect(requests, isEmpty);
    expect(results, isEmpty);
    expect(find.byKey(const ValueKey('ts-settings-key')), findsOneWidget);
  });

  testWidgets('所有者 11-02：存过的再打开都在，key 显示成已保存，才有东西可移除', (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    await openSettings(tester, 'ts-home');
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-key')), 'tskey-api-CANARY');
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-username')), 'ubuntu');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ts-settings-key')), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectMaskedKey(tester);
    expect(find.textContaining('已加密保存'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('ts-settings-username')))
            .controller!
            .text,
        'ubuntu');
    expect(find.byKey(const ValueKey('ts-settings-remove')), findsOneWidget);
  });

  testWidgets('所有者 11-02：改 key：换成输入框，新 key 保存后替换旧的', (tester) async {
    seedSavedToken();
    await openSettings(tester, 'ts-home');
    await tester.tap(find.byKey(const ValueKey('ts-settings-change-key')));
    await tester.pumpAndSettle();
    final field =
        tester.widget<TextField>(find.byKey(const ValueKey('ts-settings-key')));
    expect(field.controller!.text, isEmpty, reason: '不把旧的填回来');
    expect(field.obscureText, isTrue);
    expect(find.byKey(const ValueKey('ts-settings-saved-key')), findsNothing);

    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-key')), 'tskey-api-NEW');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(requests.single.headers['authorization'], 'Bearer tskey-api-NEW');
    expect(secrets.values,
        {'tailscale.catalog.ts-home.accessToken': 'tskey-api-NEW'});
  });

  testWidgets('所有者 11-02：点了修改又不填：取消回到掩码；空着保存用旧的', (tester) async {
    seedSavedToken();
    final results = await openSettings(tester, 'ts-home');
    await tester.tap(find.byKey(const ValueKey('ts-settings-change-key')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-key')), 'tskey-api-DRAFT');
    await tester
        .tap(find.byKey(const ValueKey('ts-settings-cancel-change-key')));
    await tester.pumpAndSettle();
    expectMaskedKey(tester);

    await tester.tap(find.byKey(const ValueKey('ts-settings-change-key')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ts-settings-key')))
            .controller!
            .text,
        isEmpty,
        reason: '取消掉的不留');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(requests.single.headers['authorization'], 'Bearer tskey-api-OLD');
    expect(secrets.values,
        {'tailscale.catalog.ts-home.accessToken': 'tskey-api-OLD'});
    expect(results.single?.catalogId, 'ts-home');
  });

  testWidgets('所有者 11-02：新 key 被拒绝：旧的还在，新的留在框里能改', (tester) async {
    seedSavedToken();
    replies = [http.Response('{}', 401)];
    final results = await openSettings(tester, 'ts-home');
    await tester.tap(find.byKey(const ValueKey('ts-settings-change-key')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-key')), 'tskey-api-BAD');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(secrets.values,
        {'tailscale.catalog.ts-home.accessToken': 'tskey-api-OLD'});
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ts-settings-key')))
            .controller!
            .text,
        'tskey-api-BAD');
  });

  testWidgets('没网时填的 key 也存下：框里换成已保存，说一声；保留设备', (tester) async {
    seedIncomplete();
    replies = [http.Response('{"message":"boom"}', 500)];
    final results = await openSettings(tester, 'ts-home');
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-key')), 'tskey-api-CANARY');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('key 已保存'), findsOneWidget);
    expect(results, isEmpty);
    expect(secrets.values,
        {'tailscale.catalog.ts-home.accessToken': 'tskey-api-CANARY'});
    expectMaskedKey(tester);
    expect(repo.caches['ts-home']!.devices, hasLength(2));
  });

  testWidgets('Tailscale 明确不接受的 key 不存，框里留着', (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    replies = [http.Response('{}', 401)];
    await openSettings(tester, 'ts-home');
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-key')), 'tskey-api-BAD');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(secrets.values, isEmpty);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ts-settings-key')))
            .controller!
            .text,
        'tskey-api-BAD');
  });

  testWidgets('所有者 11-02：面板非模态，背后的按钮点得到；下滑能关', (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    final results = await openSettings(tester, 'ts-home');
    // 判据（docs/24 3.4）：面板没新增遮罩、背后真点得到。页面路由自己那层不可见、不拦点击的
    // barrier 本来就在，不要求整棵树为零。
    expect(find.byKey(nonModalPanelKey), findsOneWidget);
    expect(find.byType(ModalBarrier), findsOneWidget,
        reason: '只有页面路由自己那一层（不可见、不拦点击）');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(results, [null], reason: '背后的按钮真点到了：又开一个，旧的关掉');
    expect(find.byType(TailscaleSettingsScreen), findsOneWidget);

    await tester.fling(
        find.text('Tailscale 设置').first, const Offset(0, 800), 2000);
    await tester.pumpAndSettle();
    expect(find.byType(TailscaleSettingsScreen), findsNothing);
  });

  testWidgets('所有者 11-02：切底栏就关', (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    final results = await openSettings(tester, 'ts-home');
    ProviderScope.containerOf(tester.element(find.text('open')))
        .read(homeTabProvider.notifier)
        .state = 2;
    await tester.pumpAndSettle();
    expect(find.byType(TailscaleSettingsScreen), findsNothing);
    expect(results, [null]);
  });

  testWidgets('状态同步间隔：存进设置，再打开还是它', (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    await openSettings(tester, 'ts-home');
    await tester.tap(find.byKey(const ValueKey('ts-settings-sync')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 分钟').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(
        ProviderScope.containerOf(tester.element(find.text('open')))
            .read(settingsControllerProvider)
            .tailscaleSyncSeconds,
        300);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('5 分钟'), findsOneWidget);
  });

  testWidgets('读取失败：写明失败、留在设置页、缓存里的设备不动', (tester) async {
    seedIncomplete();
    replies = [http.Response('{"message":"boom"}', 500)];
    final results = await openSettings(tester, 'ts-home');
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-key')), 'tok');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('读取失败，缓存里的设备和主机都没动'), findsOneWidget);
    expect(results, isEmpty);
    expect(find.byKey(const ValueKey('ts-settings-saved-key')), findsOneWidget);
    expect(repo.caches['ts-home']!.devices, hasLength(2));
  });

  testWidgets('R26：导入默认值存进来源、再打开时原样显示；只存设置不发请求', (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    var results = await openSettings(tester, 'ts-home');
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-username')), ' ubuntu ');
    await tester.tap(find.byKey(const ValueKey('ts-settings-advanced')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-port')), '2222');
    await tester.tap(find.text('MagicDNS 名称'));
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-group')), 'lab');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(results.single?.removed, isFalse);
    expect(repo.caches['ts-home']!.importDefaults, {
      'username': 'ubuntu',
      'port': 2222,
      'address': 'fqdn',
      'group': 'lab',
    });
    expect(requests, isEmpty);

    results = await openSettings(tester, 'ts-home');
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('ts-settings-username')))
            .controller!
            .text,
        'ubuntu');
    await tester.tap(find.byKey(const ValueKey('ts-settings-advanced')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ts-settings-port')))
            .controller!
            .text,
        '2222');
  });

  testWidgets('UXR04：底部面板，默认只有两项输入；key 框防截屏；第一个来源不问名称', (tester) async {
    await openSettings(tester, null);
    final panel = find.byKey(nonModalPanelKey);
    expect(panel, findsOneWidget);
    expect(find.descendant(of: panel, matching: find.byType(EditableText)),
        findsNWidgets(2));
    final field = find.byKey(const ValueKey('ts-settings-key'));
    expect(field, findsOneWidget);
    expect(find.ancestor(of: field, matching: find.byType(SecretContent)),
        findsOneWidget);
    expect(find.byKey(const ValueKey('ts-settings-username')), findsOneWidget);
    expect(find.text('端口、连接路径、分组'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ts-settings-advanced')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ts-settings-port')), findsOneWidget);
    expect(find.byKey(const ValueKey('ts-settings-tailnet')), findsOneWidget);
    expect(find.text('连接路径'), findsOneWidget);
    expect(find.byKey(const ValueKey('ts-settings-name')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(repo.caches.values.single.label, 'Tailscale');
  });

  testWidgets('UXR04：只有一个来源时不提「来源」；接第二个才问名称，按钮才写「移除来源」', (tester) async {
    repo.caches['ts-home'] = const CatalogCache(
        catalogId: 'ts-home', tailnet: '-', label: 'Tailscale');
    await openSettings(tester, 'ts-home');
    expect(find.text('移除 Tailscale'), findsOneWidget);
    expect(find.textContaining('来源'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ts-settings-cancel')));
    await tester.pumpAndSettle();

    await openSettings(tester, null);
    await tester.tap(find.byKey(const ValueKey('ts-settings-advanced')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ts-settings-name')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ts-settings-cancel')));
    await tester.pumpAndSettle();

    repo.caches['ts-work'] =
        const CatalogCache(catalogId: 'ts-work', tailnet: '-', label: 'work');
    await openSettings(tester, 'ts-home');
    expect(find.text('移除来源'), findsOneWidget);
  });

  testWidgets('UXR04：已有来源的代理、端口、分组收着也看得见，保存不丢', (tester) async {
    repo.caches['ts-home'] = const CatalogCache(
      catalogId: 'ts-home',
      tailnet: '-',
      label: 'home',
      importDefaults: {'port': 2222, 'proxyProfileId': 'p', 'group': 'lab'},
    );
    await vault.saveVault(VaultData.fromJson({
      'hosts': [],
      'keys': [],
      'snippets': [],
      'customGroups': [],
      'proxyProfiles': [
        {
          'id': 'p',
          'label': 'office',
          'config': {'type': 'socks5', 'host': '192.0.2.1', 'port': 1080},
        },
      ],
    }));
    await openSettings(tester, 'ts-home');
    expect(find.text('端口 2222 · 代理 · 分组'), findsOneWidget);
    expect(find.byKey(const ValueKey('ts-settings-port')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(repo.caches['ts-home']!.importDefaults, {
      'port': 2222,
      'address': 'ipv4',
      'proxyProfileId': 'p',
      'group': 'lab',
    });
  });

  testWidgets('UXR04：面板里照样能配代理和跳板（R06、R07），存进默认值', (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    await vault.saveVault(VaultData.fromJson({
      'hosts': [
        HostProfile.create(
                id: 'edge',
                label: 'edge',
                hostname: 'edge.example',
                username: 'ops')
            .data,
      ],
      'keys': [],
      'snippets': [],
      'customGroups': [],
      'proxyProfiles': [
        {
          'id': 'p',
          'label': 'office',
          'config': {'type': 'socks5', 'host': '192.0.2.1', 'port': 1080},
        },
      ],
    }));
    await openSettings(tester, 'ts-home');
    await tester.tap(find.byKey(const ValueKey('ts-settings-advanced')));
    await tester.pumpAndSettle();
    await addRouteJump(tester, 'edge');
    await tapRoute(tester, find.byKey(const ValueKey('route-add-proxy')));
    await tapRoute(tester, find.byKey(const ValueKey('proxy-profile-p')));
    expect(find.text('代理 · 跳板机'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    final saved = repo.caches['ts-home']!.importDefaults;
    expect(saved['proxyProfileId'], 'p');
    expect(saved['jumpHostIds'], ['edge']);
  });

  testWidgets('UXR04：错在收着的高级里就自己打开，话写在面板上；路径坏了一打开就摆出来', (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    await openSettings(tester, 'ts-home');
    // 点标题：展开后整块的中心落在里面的输入框上，点不到收起。
    final advanced = find.text('高级');
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ts-settings-port')), '0');
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ts-settings-port')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(find.text('端口要在 1–65535 之间。'), findsOneWidget);
    expect(find.byKey(const ValueKey('ts-settings-port')), findsOneWidget);
    expect(requests, isEmpty);
    await tester.tap(find.byKey(const ValueKey('ts-settings-cancel')));
    await tester.pumpAndSettle();

    repo.caches['ts-home'] = const CatalogCache(
      catalogId: 'ts-home',
      tailnet: '-',
      label: 'home',
      importDefaults: {'proxyProfileId': 'gone'},
    );
    await openSettings(tester, 'ts-home');
    expect(find.byKey(const ValueKey('ts-settings-port')), findsOneWidget);
  });

  testWidgets('F31：默认登录可以是用户名或凭据；以前选的默认私钥照常显示，能清掉', (tester) async {
    repo.caches['ts-home'] = const CatalogCache(
      catalogId: 'ts-home',
      tailnet: '-',
      label: 'home',
      importDefaults: {'username': 'ubuntu', 'identityFileId': 'k1'},
    );
    await vault.saveVault(VaultData.fromJson({
      'hosts': [],
      'keys': [
        {'id': 'k1', 'label': 'laptop', 'type': 'ED25519'},
      ],
      'snippets': [],
      'customGroups': [],
      'identities': [
        {
          'id': 'pw',
          'label': 'team',
          'username': 'ops',
          'authMethod': 'password',
          'password': 'NOT-IN-DEFAULTS',
        },
      ],
    }));
    await openSettings(tester, 'ts-home');
    expect(find.text('私钥“laptop”'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('own-key-drop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(repo.caches['ts-home']!.importDefaults,
        {'username': 'ubuntu', 'address': 'ipv4'});

    await openSettings(tester, 'ts-home');
    await tester.tap(find.byKey(const ValueKey('ts-settings-login')));
    await tester.pumpAndSettle();
    // 选了「凭据」却没选中：不存。
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('ts-settings-credential')), findsOneWidget);
    expect(repo.caches['ts-home']!.importDefaults.containsKey('identityId'),
        isFalse);
    await tester.tap(find.byKey(const ValueKey('ts-settings-credential')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('credential-option-pw')));
    await tester.pumpAndSettle();
    expect(find.text('ops · 密码'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(repo.caches['ts-home']!.importDefaults,
        {'address': 'ipv4', 'identityId': 'pw'});

    await openSettings(tester, 'ts-home');
    expect(find.text('ops · 密码'), findsOneWidget, reason: '再打开，回显还在');
  });

  testWidgets('R26：设置页里删除保存的 OAuth client、移除来源（主机都留着）', (tester) async {
    seedIncomplete();
    secrets.values['tailscale.catalog.ts-home.oauth.clientId'] = 'cid';
    secrets.values['tailscale.catalog.ts-home.oauth.clientSecret'] = 'cs';
    await saveHosts(
        [boundHost('h1', 'nas', 'ts-home', '1', applied: '100.64.0.1')]);
    final results = await openSettings(tester, 'ts-home');
    expectMaskedKey(tester);
    await tester.tap(find.byKey(const ValueKey('ts-settings-forget-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(secrets.values, hasLength(2), reason: '确认框点取消，什么都不删');
    await tester.tap(find.byKey(const ValueKey('ts-settings-forget-key')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('ts-settings-forget-key-confirm')));
    await tester.pumpAndSettle();
    expect(secrets.values, isEmpty);
    expect(find.byKey(const ValueKey('ts-settings-forget-key')), findsNothing);
    expect(find.byKey(const ValueKey('ts-settings-key')), findsOneWidget,
        reason: '删了就回到能填新 key');

    await tester.tap(find.byKey(const ValueKey('ts-settings-remove')));
    await tester.pumpAndSettle();
    expect(find.text('关联它的主机：1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ts-settings-remove-confirm')));
    await tester.pumpAndSettle();
    expect(results.single?.removed, isTrue);
    expect(repo.caches, isEmpty);
    expect((await vault.loadVault()).hosts.single.label, 'nas');
    expect(requests, isEmpty);
  });

  testWidgets('R26：点一台设备按默认值导入，连接前先问登录；取消就只留下主机、不连接', (tester) async {
    seedIncomplete();
    repo.caches['ts-home'] = repo.caches['ts-home']!
        .copyWith(importDefaults: {'username': 'ubuntu'});
    await saveHosts([
      HostProfile.create(
              id: 'manual', label: 'manual', hostname: 'x', username: 'me')
          .toJson(),
    ]);
    await open(tester, const CatalogSourceScreen(catalogId: 'ts-home'));
    expect(find.textContaining('导入'), findsNothing, reason: 'R76：用户不用知道有导入这一步');
    await tester.tap(find.byKey(const ValueKey('catalog-device-1')));
    await tester.pumpAndSettle();

    // 不再弹批量设置页；第一次连之前问这一台的用户名和密码，默认值先填好。
    expect(find.byKey(const ValueKey('catalog-import-confirm')), findsNothing);
    expect(find.byKey(const ValueKey('first-login-dialog')), findsOneWidget);
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('first-login-username')))
            .controller!
            .text,
        'ubuntu');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('已导入为主机：nas'), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-device-menu-1')), findsNothing);
    final hosts = (await vault.loadVault()).hosts;
    expect(hosts.map((h) => h.label), ['manual', 'nas']);
    final added = hosts.last;
    expect(added.username, 'ubuntu');
    expect(added.distro, 'linux');
    expect(CatalogBinding.of(added)!.deviceId, '1');
    expect(added.lastConnectedAt, 0);
    expect(requests, isEmpty); // 导入不发任何网络请求
  });

  testWidgets('UXR05：设备页没有导入入口；⋮ 能隐藏、能取消；连过的没有这个菜单', (tester) async {
    seedIncomplete();
    await open(tester, const CatalogSourceScreen(catalogId: 'ts-home'));
    for (final gone in ['catalog-import-all', 'catalog-more']) {
      expect(find.byKey(ValueKey(gone)), findsNothing);
    }
    await tester.tap(find.byKey(const ValueKey('catalog-device-menu-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalog-import-only-2')), findsNothing);
    expect(find.byKey(const ValueKey('catalog-link-2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('catalog-device-hide-2')));
    await tester.pumpAndSettle();
    expect(repo.caches['ts-home']!.hiddenDevices, {'2'});
    expect(find.text('已隐藏'), findsOneWidget);
    expect((await vault.loadVault()).hosts, isEmpty, reason: '隐藏不建主机');

    await tester.tap(find.byKey(const ValueKey('catalog-device-menu-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-device-hide-2')));
    await tester.pumpAndSettle();
    expect(repo.caches['ts-home']!.hiddenDevices, isEmpty);
    expect(requests, isEmpty);
  });

  testWidgets('R26：登录成功过的主机在设备页标「登录过」', (tester) async {
    seedIncomplete();
    await saveHosts([
      {
        ...boundHost('h1', 'nas', 'ts-home', '1', applied: '100.64.0.1'),
        'lastConnectedAt': 1,
      },
      boundHost('h2', 'laptop', 'ts-home', '2', applied: '100.64.0.2'),
    ]);
    await open(tester, const CatalogSourceScreen(catalogId: 'ts-home'));
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('catalog-device-1')),
            matching: find.byKey(const ValueKey('logged-in-mark'))),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('catalog-device-2')),
            matching: find.byKey(const ValueKey('logged-in-mark'))),
        findsNothing);
  });

  testWidgets('X05 主机引用了本机没有的来源：列出来；在本机恢复后进入来源页，主机不变、不发请求', (tester) async {
    await saveHosts([
      boundHost('h1', 'nas', 'ts-gone', '1', applied: '100.64.0.1'),
    ]);
    final before = jsonEncode((await vault.loadVault()).hosts.single.data);
    await open(tester, const TailscaleCatalogScreen());
    expect(
        find.byKey(const ValueKey('catalog-missing-ts-gone')), findsOneWidget);
    expect(find.text('引用它的主机：nas'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('catalog-restore-ts-gone')));
    await tester.pumpAndSettle();
    expect(find.textContaining('不发请求、不改任何主机'), findsOneWidget);
    await tester.tap(find.text('恢复来源'));
    await tester.pumpAndSettle();

    expect(repo.caches['ts-gone']!.devices, isEmpty);
    expect(find.text('还没读过设备列表'), findsOneWidget);
    expect(requests, isEmpty);
    expect(jsonEncode((await vault.loadVault()).hosts.single.data), before);

    // 在 Tailscale 设置里填 key 读一次同一个 tailnet：设备 1 对上，列表里显示它就是那台导入的主机。
    await tester.tap(find.byKey(const ValueKey('catalog-open-settings')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('ts-settings-key')), 'tok');
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(find.text('已导入为主机：nas'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalog-missing-ts-gone')), findsNothing);
  });

  testWidgets('英文界面：来源页、设置页和首次登录渲染出来的文字里没有汉字', (tester) async {
    ShunLocalizations.use('en');
    addTearDown(() => ShunLocalizations.use('zh'));
    seedIncomplete();
    await saveHosts([
      HostProfile.create(
              id: 'manual',
              label: 'my nas',
              hostname: '10.0.0.5',
              username: 'me')
          .toJson(),
      boundHost('h1', 'gone', 'ts-gone', '1', applied: '100.64.0.1'),
    ]);
    final han = RegExp(r'[一-鿿]');
    await open(tester, const TailscaleCatalogScreen());
    expect(
        find.byKey(const ValueKey('catalog-missing-ts-gone')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('catalog-restore-ts-gone')));
    await tester.pumpAndSettle();
    expect(han.hasMatch(allText(tester)), isFalse, reason: allText(tester));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    expect(han.allMatches(allText(tester)).map((m) => m.group(0)), isEmpty,
        reason: allText(tester));
    expect(find.text('Online status unknown'), findsOneWidget);
    expect(find.textContaining('This list was incomplete'), findsOneWidget);
    // 设备列表的 ⓘ 是几段逐句本地化后拼的，其中一段是按片段翻的多行句子。
    await tester.tap(find.byTooltip('About “Devices”'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tailscale#16911'), findsOneWidget);
    expect(han.hasMatch(allText(tester)), isFalse, reason: allText(tester));
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-device-menu-2')));
    await tester.pumpAndSettle();
    expect(han.hasMatch(allText(tester)), isFalse, reason: allText(tester));
    await tester.tap(find.byKey(const ValueKey('catalog-device-hide-2')));
    await tester.pumpAndSettle();
    expect(han.hasMatch(allText(tester)), isFalse, reason: allText(tester));
    // Tailscale 设置页（展开「高级」）。
    await tester.tap(find.byKey(const ValueKey('catalog-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ts-settings-advanced')));
    await tester.pumpAndSettle();
    expect(han.hasMatch(allText(tester)), isFalse, reason: allText(tester));
    await tester.tap(find.byKey(const ValueKey('ts-settings-cancel')));
    await tester.pumpAndSettle();
    // 点设备：首次登录的对话框。
    await tester.tap(find.byKey(const ValueKey('catalog-device-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('first-login-dialog')), findsOneWidget);
    expect(han.hasMatch(allText(tester)), isFalse, reason: allText(tester));
  });

  test('真实仓库：缓存目录还不存在时返回不可修改的空列表（界面必须先复制再排序）', () async {
    final real = CatalogCacheRepository(() async => Directory(
        '${Directory.systemTemp.path}/r13-none-${DateTime.now().microsecondsSinceEpoch}'));
    final list = await real.loadAll();
    expect(list, isEmpty);
    expect(() => list.sort((a, b) => 0), throwsUnsupportedError);
  });

  testWidgets('没起名的来源：标题不用内部 ID；填过 tailnet 用 tailnet，否则「未命名来源」另写一行 ID',
      (tester) async {
    repo.caches['ts-a0b1c2d3e4'] =
        const CatalogCache(catalogId: 'ts-a0b1c2d3e4', tailnet: '-');
    repo.caches['ts-f5g6h7i8j9'] =
        const CatalogCache(catalogId: 'ts-f5g6h7i8j9', tailnet: 'example.com');
    await open(tester, const TailscaleCatalogScreen());
    expect(find.text('未命名来源'), findsOneWidget);
    expect(find.text('ID：ts-a0b1c2d3e4'), findsOneWidget,
        reason: '几个未命名来源要靠它分开');
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('ts-a0b1c2d3e4'), findsNothing);
    expect(find.text('ts-f5g6h7i8j9'), findsNothing);
    expect(find.textContaining('ts-f5g6h7i8j9'), findsNothing,
        reason: '有 tailnet 能叫，就不另写 ID');

    await tester.tap(find.text('未命名来源'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('未命名来源')),
        findsOneWidget);
  });

  testWidgets('添加来源：走 Tailscale 设置页，名称预先填「Tailscale」，被占了填「Tailscale 2」；建好后就叫它',
      (tester) async {
    repo.caches['ts-home'] = const CatalogCache(
        catalogId: 'ts-home', tailnet: '-', label: 'Tailscale');
    await open(tester, const TailscaleCatalogScreen());
    await tester.tap(find.byKey(const ValueKey('catalog-add-source')));
    await tester.pumpAndSettle();
    // 新建走 Tailscale 设置页，名称在「高级」里。
    await tester.tap(find.byKey(const ValueKey('ts-settings-advanced')));
    await tester.pumpAndSettle();
    expect(find.text('Tailscale 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ts-settings-save')));
    await tester.pumpAndSettle();
    expect(requests, isEmpty, reason: '没填 key 就只建来源，不读');
    final added = repo.caches.values.where((c) => c.catalogId != 'ts-home');
    expect(added.single.label, 'Tailscale 2');
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.text('Tailscale 2')),
        findsOneWidget);
  });

  testWidgets('全新安装：来源页正常显示「还没有目录来源」，不因空列表崩溃', (tester) async {
    repo = _ConstEmptyRepository();
    await open(tester, const TailscaleCatalogScreen());
    expect(find.textContaining('还没有目录来源'), findsOneWidget);
    expect(find.textContaining('Unsupported'), findsNothing);
  });

  testWidgets('没关联目录的主机，编辑器里不出现目录来源', (tester) async {
    await open(
      tester,
      HostEditor(
        host: HostProfile.create(
            id: 'm', label: 'm', hostname: 'm.example.com', username: 'u'),
      ),
    );
    await openAdvanced(tester);
    expect(find.byKey(const ValueKey('catalog-source-section')), findsNothing);
  });
}

String catalogTimeForTest(DateTime at) {
  final local = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
