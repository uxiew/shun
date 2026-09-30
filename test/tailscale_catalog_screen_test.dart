import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_access.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_refresh.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/catalog_cache.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/tailscale_api.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/tailscale_device.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:netcatty_mobile/presentation/screens/tailscale_catalog_screen.dart';
import 'package:netcatty_mobile/presentation/widgets/host_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

// R13 界面：目录页显示缓存时间和「不完整」（TSC05），控制面状态不说成「在线」（TSC03），
// 粘贴框遮挡、不保存（TSC09），导入只建主机、写明还没连接过（TSC06），编辑器里看得到来源和跟随状态。
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

final at = DateTime.utc(2026, 9, 30, 8, 5);

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

  testWidgets('TSC05/TSC03：来源页显示缓存时间和「不完整」；控制面不知道就写不知道，不出现「在线」',
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
    expect(find.text('Tailscale 控制面：已连接'), findsOneWidget);
    expect(find.text('Tailscale 控制面：不知道'), findsOneWidget);
    final text = allText(tester);
    for (final word in ['在线', '可连接', 'SSH 可用', 'online']) {
      expect(text, isNot(contains(word)));
    }
    expect(requests, isEmpty); // 打开页面不发请求：只在用户操作时读
  });

  testWidgets('TSC09：粘贴 token 的输入框遮挡、关闭联想；读完不保存任何东西', (tester) async {
    repo.caches['ts-home'] =
        const CatalogCache(catalogId: 'ts-home', tailnet: '-', label: 'home');
    await open(tester, const CatalogSourceScreen(catalogId: 'ts-home'));
    expect(find.text('缓存里还没有设备。读一次设备列表后会出现在这里。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('catalog-read-token')));
    await tester.pumpAndSettle();
    final field = tester
        .widget<TextField>(find.byKey(const ValueKey('catalog-secret-field')));
    expect(field.obscureText, isTrue);
    expect(field.enableSuggestions, isFalse);
    expect(field.autocorrect, isFalse);
    await tester.enterText(
        find.byKey(const ValueKey('catalog-secret-field')), 'tskey-api-CANARY');
    await tester.tap(find.text('读取'));
    await tester.pumpAndSettle();

    expect(requests.single.headers['authorization'], 'Bearer tskey-api-CANARY');
    expect(find.text('nas'), findsOneWidget);
    expect(find.text('laptop'), findsOneWidget);
    expect(find.textContaining('读取成功，设备数：2'), findsOneWidget);
    expect(find.textContaining('无法确认它只能读设备'), findsOneWidget);
    expect(secrets.values, isEmpty);
    expect(jsonEncode(repo.caches['ts-home']!.toJson()),
        isNot(contains('CANARY')));
  });

  testWidgets('OAuth client：ID 和 secret 都填了才能点读取；「不完整」只说一次', (tester) async {
    seedIncomplete();
    await open(tester, const CatalogSourceScreen(catalogId: 'ts-home'));
    expect(find.textContaining('不完整'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('catalog-read-oauth')));
    await tester.pumpAndSettle();
    FilledButton read() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '读取'));
    expect(read().onPressed, isNull);
    await tester.enterText(
        find.byKey(const ValueKey('catalog-oauth-id')), 'cid');
    await tester.pump();
    expect(read().onPressed, isNull);
    await tester.enterText(
        find.byKey(const ValueKey('catalog-oauth-secret')), 'csecret');
    await tester.pump();
    expect(read().onPressed, isNotNull);
    final secret = tester
        .widget<TextField>(find.byKey(const ValueKey('catalog-oauth-secret')));
    expect(secret.obscureText, isTrue);
  });

  testWidgets('读取失败：写明失败、缓存里的设备不动', (tester) async {
    seedIncomplete();
    replies = [http.Response('{"message":"boom"}', 500)];
    await open(tester, const CatalogSourceScreen(catalogId: 'ts-home'));
    await tester.tap(find.byKey(const ValueKey('catalog-read-token')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('catalog-secret-field')), 'tok');
    await tester.tap(find.text('读取'));
    await tester.pumpAndSettle();
    expect(find.textContaining('读取失败，缓存里的设备和主机都没动'), findsOneWidget);
    expect(find.textContaining('最近一次读取失败：'), findsOneWidget);
    expect(find.text('nas'), findsOneWidget);
    expect(repo.caches['ts-home']!.devices, hasLength(2));
  });

  testWidgets('TSC06：导入要填用户名；只建主机不连接，提示还没连接过；已导入的不能再选', (tester) async {
    seedIncomplete();
    await vault.saveVault(VaultData.fromJson({
      'hosts': [
        HostProfile.create(
                id: 'manual', label: 'manual', hostname: 'x', username: 'me')
            .toJson(),
      ],
      'keys': [],
      'snippets': [],
      'customGroups': [],
    }));
    await open(tester, const CatalogSourceScreen(catalogId: 'ts-home'));
    await tester.tap(find.byKey(const ValueKey('catalog-device-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-import-selected')));
    await tester.pumpAndSettle();

    expect(find.textContaining('不会默认用 root'), findsWidgets);
    final confirm = find.byKey(const ValueKey('catalog-import-confirm'));
    expect(tester.widget<TextButton>(confirm).onPressed, isNull);

    await tester.enterText(
        find.byKey(const ValueKey('catalog-import-username')), 'ubuntu');
    await tester.pumpAndSettle();
    expect(find.text('将新建主机：1'), findsOneWidget);
    expect(find.text('nas  →  ubuntu@100.64.0.1:22'), findsOneWidget);
    expect(find.textContaining('目标“nas”'), findsOneWidget);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(find.textContaining('已导入主机：1'), findsOneWidget);
    expect(find.textContaining('还没有连接过'), findsOneWidget);
    expect(find.text('已导入为主机：nas'), findsOneWidget);
    final checkbox = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('catalog-device-1')));
    expect(checkbox.onChanged, isNull);

    final hosts = (await vault.loadVault()).hosts;
    expect(hosts.map((h) => h.label), ['manual', 'nas']);
    final added = hosts.last;
    expect(added.username, 'ubuntu');
    expect(CatalogBinding.of(added)!.deviceId, '1');
    expect(requests, isEmpty); // 导入不发任何网络请求
  });

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
    expect(text(), contains('Tailscale 控制面：已连接'));
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

  testWidgets('X05 关联已有主机：只列没关联的主机；只写绑定、不改地址、不发请求', (tester) async {
    seedIncomplete();
    await saveHosts([
      HostProfile.create(
              id: 'manual',
              label: 'my nas',
              hostname: '10.0.0.5',
              username: 'me')
          .toJson(),
      boundHost('bound', 'bound', 'ts-home', '9'),
    ]);
    await open(tester, const CatalogSourceScreen(catalogId: 'ts-home'));
    await tester.tap(find.byKey(const ValueKey('catalog-link-1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('一概不改'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('catalog-link-host-manual')), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-link-host-bound')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('catalog-link-host-manual')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已关联。'), findsOneWidget);
    expect(find.text('已关联主机：my nas'), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-link-1')), findsNothing);
    final checkbox = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('catalog-device-1')));
    expect(checkbox.onChanged, isNull);

    final manual =
        (await vault.loadVault()).hosts.singleWhere((h) => h.id == 'manual');
    expect(manual.hostname, '10.0.0.5');
    expect(manual.username, 'me');
    expect(CatalogBinding.of(manual)!.deviceId, '1');
    expect(CatalogBinding.of(manual)!.appliedAddress, isNull);
    expect(requests, isEmpty);
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
    expect(find.text('缓存里还没有设备。读一次设备列表后会出现在这里。'), findsOneWidget);
    expect(requests, isEmpty);
    expect(jsonEncode((await vault.loadVault()).hosts.single.data), before);

    // 读一次同一个 tailnet：设备 1 对上，列表里显示它就是那台导入的主机。
    await tester.tap(find.byKey(const ValueKey('catalog-read-token')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('catalog-secret-field')), 'tok');
    await tester.tap(find.text('读取'));
    await tester.pumpAndSettle();
    expect(find.text('已导入为主机：nas'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalog-missing-ts-gone')), findsNothing);
  });

  testWidgets('英文界面：来源页和导入页渲染出来的文字里没有汉字', (tester) async {
    NetcattyLocalizations.use('en');
    addTearDown(() => NetcattyLocalizations.use('zh'));
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
    expect(find.text('Tailscale control plane: unknown'), findsOneWidget);
    expect(find.textContaining('This list was incomplete'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('catalog-link-2')));
    await tester.pumpAndSettle();
    expect(han.hasMatch(allText(tester)), isFalse, reason: allText(tester));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-device-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-import-selected')));
    await tester.pumpAndSettle();
    expect(han.hasMatch(allText(tester)), isFalse, reason: allText(tester));
    expect(find.textContaining('root is never assumed'), findsWidgets);
  });

  test('真实仓库：缓存目录还不存在时返回不可修改的空列表（界面必须先复制再排序）', () async {
    final real = CatalogCacheRepository(() async => Directory(
        '${Directory.systemTemp.path}/r13-none-${DateTime.now().microsecondsSinceEpoch}'));
    final list = await real.loadAll();
    expect(list, isEmpty);
    expect(() => list.sort((a, b) => 0), throwsUnsupportedError);
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
    expect(find.byKey(const ValueKey('catalog-source-section')), findsNothing);
  });
}

String catalogTimeForTest(DateTime at) {
  final local = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
