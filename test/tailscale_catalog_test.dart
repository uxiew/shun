import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shun/application/tailscale_catalog_access.dart';
import 'package:shun/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:shun/infrastructure/tailscale/tailscale_api.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';

// R11：只读 Tailscale 目录的 HTTP 适配。
//
// 服务器是本机真实的 HTTP fixture（dart:io HttpServer），按官方 OpenAPI 的路径和响应形状回应，
// 记录每个请求的 method / path / query / 头 / 请求体。**没有真实 Tailscale 账号或 token**——
// 这些测试证明客户端发了什么、在各种响应下怎么做，不证明 Tailscale 服务器的真实行为。

const clientSecret = 'tskey-client-kCANARY1CNTRL-SECRETCANARY9f3e';
const clientId = 'kCANARY1CNTRL';
const pastedToken = 'tskey-api-kPASTED2CNTRL-PASTEDCANARY51ab';

class Recorded {
  Recorded(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;
  String get path => uri.path;
  String get all => '$method $uri ${jsonEncode(headers)} $body';
}

class Reply {
  const Reply(this.status, [this.body = '', this.headers = const {}]);
  final int status;
  final String body;
  final Map<String, String> headers;
}

/// 按路径脚本化回应。每个路径一串回应，用完后重复最后一个。
class FakeTailscale {
  late HttpServer server;
  final requests = <Recorded>[];
  final scripts = <String, List<Reply>>{};
  var _tokens = 0;

  Uri get origin => Uri.parse('http://127.0.0.1:${server.port}');

  static String tokenBody({
    String? token,
    int? expiresIn = 3600,
    String? scope = 'devices:core:read',
  }) =>
      jsonEncode({
        if (token != null) 'access_token': token,
        'token_type': 'Bearer',
        if (expiresIn != null) 'expires_in': expiresIn,
        if (scope != null) 'scope': scope,
      });

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decodeStream(request);
      final headers = <String, String>{};
      request.headers.forEach((k, v) => headers[k] = v.join(','));
      requests.add(Recorded(request.method, request.uri, headers, body));
      final script = scripts[request.uri.path];
      Reply reply;
      if (script != null && script.isNotEmpty) {
        reply = script.length > 1 ? script.removeAt(0) : script.first;
      } else if (request.uri.path == '/api/v2/oauth/token') {
        reply = Reply(200, tokenBody(token: 'tok-${++_tokens}'));
      } else if (request.uri.path.endsWith('/devices')) {
        reply = Reply(200, sampleDevices);
      } else {
        reply = const Reply(404, '{"message":"not found"}');
      }
      request.response.statusCode = reply.status;
      reply.headers.forEach(request.response.headers.set);
      request.response.write(reply.body);
      await request.response.close();
    });
  }

  Iterable<Recorded> at(String path) => requests.where((r) => r.path == path);
  Future<void> stop() => server.close(force: true);
}

const tokenPath = '/api/v2/oauth/token';
const devicesPath = '/api/v2/tailnet/-/devices';

final sampleDevices = jsonEncode({
  'devices': [
    {
      'addresses': ['100.64.0.7', 'fd7a:115c:a1e0::7', 'not-an-ip'],
      'id': '12345',
      'nodeId': 'nAbc123CNTRL',
      'user': 'me@example.com',
      'name': 'nas.tail1234.ts.net',
      'hostname': 'nas',
      'clientVersion': '1.80.0',
      'updateAvailable': false,
      'os': 'linux',
      'created': '2025-01-01T00:00:00Z',
      'connectedToControl': true,
      'keyExpiryDisabled': true,
      'expires': '0001-01-01T00:00:00Z',
      'authorized': true,
      'isExternal': false,
      'machineKey': 'mkey:MACHINEKEYCANARY',
      'nodeKey': 'nodekey:NODEKEYCANARY',
      'blocksIncomingConnections': false,
      'tailnetLockKey': 'tlpub:x',
      'tailnetLockError': '',
      'tags': ['tag:server'],
      'isEphemeral': false,
    },
    {
      // 缺字段、类型不对：全部记 UNKNOWN（null），不补默认值。
      'id': '67890',
      'hostname': 'phone',
      'lastSeen': '2026-09-29T10:00:00Z',
      'authorized': 'yes',
    },
  ],
});

class MemoryBackend implements CatalogSecretBackend {
  final values = <String, String>{};
  var writes = 0;
  var deletes = 0;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    values.remove(key);
  }
}

void main() {
  late FakeTailscale fake;
  late http.Client httpClient;
  var clock = DateTime.utc(2026, 9, 29, 12);

  setUp(() async {
    fake = FakeTailscale();
    await fake.start();
    httpClient = http.Client();
    clock = DateTime.utc(2026, 9, 29, 12);
  });
  tearDown(() async {
    httpClient.close();
    await fake.stop();
  });

  TailscaleCatalogClient client(TailscaleCredential credential) =>
      TailscaleCatalogClient.fixture(
        httpClient,
        fake.origin,
        credential,
        now: () => clock,
      );
  const oauth = OAuthClientCredential(
    clientId: clientId,
    clientSecret: clientSecret,
  );

  void expectNoSecret(Object error) {
    final text = '$error';
    for (final secret in [clientSecret, pastedToken, 'tok-1', 'tok-2']) {
      expect(text, isNot(contains(secret)), reason: text);
    }
  }

  group('TSC01 只访问必要端点、请求 devices:core:read、重定向不泄密', () {
    test('OAuth：先 POST token 端点（表单带 scope），再带 Bearer GET 列设备；没有别的请求', () async {
      final listing = await client(oauth).listDevices();

      expect(fake.requests.map((r) => '${r.method} ${r.path}'), [
        'POST $tokenPath',
        'GET $devicesPath',
      ]);
      final token = fake.requests.first;
      expect(
        token.headers['content-type'],
        startsWith('application/x-www-form-urlencoded'),
      );
      expect(Uri.splitQueryString(token.body), {
        'grant_type': 'client_credentials',
        'client_id': clientId,
        'client_secret': clientSecret,
        'scope': 'devices:core:read',
      });
      expect(token.headers.containsKey('authorization'), isFalse);

      final list = fake.requests.last;
      expect(list.headers['authorization'], 'Bearer tok-1');
      // 默认字段集：不传 fields=all，不多要管理数据；也没有发明分页参数。
      expect(list.uri.query, isEmpty);
      // client secret 只出现在 token 请求体里。
      expect(list.all, isNot(contains(clientSecret)));

      expect(listing.scopeStatus, TokenScopeStatus.deviceReadOnly);
      expect(listing.snapshot.devices, hasLength(2));
    });

    test('tailnet 作为单个路径段；含 / 或空白直接拒绝，一个请求都不发', () async {
      await client(oauth).listDevices(tailnet: 'example.com');
      expect(fake.at('/api/v2/tailnet/example.com/devices'), hasLength(1));
      for (final bad in ['a/b', '../x', 'a b', '', 'x' * 300]) {
        fake.requests.clear();
        await expectLater(
          client(oauth).listDevices(tailnet: bad),
          throwsA(isA<TailscaleInvalidInput>()),
          reason: bad,
        );
        expect(fake.requests, isEmpty, reason: bad);
      }
    });

    test('列设备被 302 到另一个 origin：不跟随，另一台服务器一个请求都没收到', () async {
      final other = FakeTailscale();
      await other.start();
      addTearDown(other.stop);
      fake.scripts[devicesPath] = [
        Reply(302, '', {'location': '${other.origin}/steal'}),
      ];
      final error = await client(oauth)
          .listDevices()
          .then<Object>((_) => fail('应当拒绝'), onError: (Object e) => e);
      expect(error, isA<TailscaleRedirectRefused>());
      expect(other.requests, isEmpty);
      expect(fake.at(devicesPath), hasLength(1));
      expectNoSecret(error);
    });

    test('token 端点 307（会原样重发带 secret 的 POST）：不跟随', () async {
      final other = FakeTailscale();
      await other.start();
      addTearDown(other.stop);
      fake.scripts[tokenPath] = [
        Reply(307, '', {'location': '${other.origin}$tokenPath'}),
      ];
      await expectLater(
        client(oauth).listDevices(),
        throwsA(isA<TailscaleRedirectRefused>()),
      );
      expect(other.requests, isEmpty);
      expect(fake.at(devicesPath), isEmpty);
    });

    test('换来的 token 带写权限：丢弃，不用它读任何东西', () async {
      fake.scripts[tokenPath] = [
        Reply(200,
            FakeTailscale.tokenBody(token: 'tok-w', scope: 'devices:core')),
      ];
      final error = await client(oauth)
          .listDevices()
          .then<Object>((_) => fail('应当拒绝'), onError: (Object e) => e);
      expect(error, isA<TailscaleScopeTooBroad>());
      expect(fake.at(devicesPath), isEmpty);
      expectNoSecret(error);
    });

    test('粘贴的 token：不经 token 端点，范围记为未验证（不冒称只读）', () async {
      final listing =
          await client(const PastedAccessToken(pastedToken)).listDevices();
      expect(fake.at(tokenPath), isEmpty);
      expect(
          fake.requests.single.headers['authorization'], 'Bearer $pastedToken');
      expect(listing.scopeStatus, TokenScopeStatus.unverified);
    });

    test('服务器不回报 scope：未验证；回报 all:read：只读但范围更大', () async {
      fake.scripts[tokenPath] = [
        Reply(200, FakeTailscale.tokenBody(token: 't1', scope: null)),
      ];
      expect(
        (await client(oauth).listDevices()).scopeStatus,
        TokenScopeStatus.unverified,
      );
      fake.scripts[tokenPath] = [
        Reply(200, FakeTailscale.tokenBody(token: 't2', scope: 'all:read')),
      ];
      expect(
        (await client(oauth).listDevices()).scopeStatus,
        TokenScopeStatus.readOnlyBroader,
      );
    });

    test('生产入口固定官方 https origin；测试入口只接受本机回环', () {
      expect(tailscaleApiOrigin.toString(), 'https://api.tailscale.com');
      expect(
        () => TailscaleCatalogClient.fixture(
          httpClient,
          Uri.parse('https://evil.example'),
          oauth,
        ),
        throwsArgumentError,
      );
    });
  });

  group('TSC02 过期、撤销、401/403/429 与短期导入', () {
    test('按实际 expires_in 续期：留余量前复用，进入余量后才换新', () async {
      final c = client(oauth);
      await c.listDevices();
      clock = clock.add(const Duration(seconds: 3200)); // 3600 - 360 余量 = 3240
      await c.listDevices();
      expect(fake.at(tokenPath), hasLength(1));
      clock = clock.add(const Duration(seconds: 60));
      await c.listDevices();
      expect(fake.at(tokenPath), hasLength(2));
      expect(
          fake.at(devicesPath).last.headers['authorization'], 'Bearer tok-2');
    });

    test('token 响应没有 expires_in：按 5 分钟保守处理', () async {
      fake.scripts[tokenPath] = [
        Reply(200, FakeTailscale.tokenBody(token: 'a', expiresIn: null)),
        Reply(200, FakeTailscale.tokenBody(token: 'b', expiresIn: null)),
      ];
      final c = client(oauth);
      await c.listDevices();
      clock = clock.add(const Duration(seconds: 241));
      await c.listDevices();
      expect(fake.at(tokenPath), hasLength(2));
    });

    test('列设备 401：作废 token、重新换一次、重试一次后成功', () async {
      fake.scripts[devicesPath] = [
        const Reply(401, '{"message":"API token invalid"}'),
        Reply(200, sampleDevices),
      ];
      final listing = await client(oauth).listDevices();
      expect(listing.snapshot.devices, hasLength(2));
      expect(fake.at(tokenPath), hasLength(2));
      expect(fake.at(devicesPath).map((r) => r.headers['authorization']), [
        'Bearer tok-1',
        'Bearer tok-2',
      ]);
    });

    test('刷新后仍 401：要求重新授权，只试这一轮，不无限重试', () async {
      fake.scripts[devicesPath] = [
        const Reply(401, '{"message":"API token invalid"}'),
      ];
      final error = await client(oauth)
          .listDevices()
          .then<Object>((_) => fail('应当失败'), onError: (Object e) => e);
      expect(error, isA<TailscaleReauthorizationRequired>());
      expect(fake.at(tokenPath), hasLength(2));
      expect(fake.at(devicesPath), hasLength(2));
      expectNoSecret(error);
    });

    test('client 被撤销（token 端点 401）：一次请求就停，要求重新授权', () async {
      fake.scripts[tokenPath] = [
        const Reply(401, '{"message":"API token invalid"}'),
      ];
      await expectLater(
        client(oauth).listDevices(),
        throwsA(isA<TailscaleReauthorizationRequired>()),
      );
      expect(fake.requests, hasLength(1));
    });

    test('粘贴的 token 401：直接要求重新提供，不去 token 端点', () async {
      fake.scripts[devicesPath] = [const Reply(401, '{"message":"expired"}')];
      await expectLater(
        client(const PastedAccessToken(pastedToken)).listDevices(),
        throwsA(isA<TailscaleReauthorizationRequired>()),
      );
      expect(fake.requests, hasLength(1));
    });

    test('403 / 404 / 5xx：各报各的原因，都不重试', () async {
      for (final (status, type) in [
        (403, isA<TailscaleForbidden>()),
        (404, isA<TailscaleTailnetNotFound>()),
        (500, isA<TailscaleServerError>()),
        (504, isA<TailscaleServerError>()),
      ]) {
        fake.requests.clear();
        fake.scripts[devicesPath] = [Reply(status, '{"message":"nope"}')];
        await expectLater(
          client(oauth).listDevices(),
          throwsA(type),
          reason: '$status',
        );
        expect(fake.at(devicesPath), hasLength(1), reason: '$status');
      }
    });

    test('429：带回 Retry-After（秒或 HTTP 日期），没有就是 null；不自动重试', () async {
      for (final (header, expected) in [
        ({'retry-after': '30'}, const Duration(seconds: 30)),
        (
          {
            'retry-after':
                HttpDate.format(clock.add(const Duration(minutes: 2)))
          },
          const Duration(minutes: 2),
        ),
        (const <String, String>{}, null),
      ]) {
        fake.requests.clear();
        fake.scripts[devicesPath] = [
          Reply(429, '{"message":"slow down"}', header),
        ];
        final error = await client(oauth)
            .listDevices()
            .then<Object>((_) => fail('应当失败'), onError: (Object e) => e);
        expect(error, isA<TailscaleRateLimited>());
        expect((error as TailscaleRateLimited).retryAfter, expected);
        expect(fake.at(devicesPath), hasLength(1));
      }
    });

    test('已保存来源刷新时 401：要求重新授权，但保存的 client 不删', () async {
      final backend = MemoryBackend();
      final access = TailscaleCatalogAccess(
        TailscaleCatalogSecretStore(backend),
        client,
      );
      await access.readWithOAuthClient(
        catalogId: 'cat-1',
        credential: oauth,
        persist: true,
      );
      fake.scripts[devicesPath] = [const Reply(401, '{}')];
      await expectLater(
        access.refreshSaved(catalogId: 'cat-1'),
        throwsA(isA<TailscaleReauthorizationRequired>()),
      );
      expect(backend.deletes, 0);
      expect(backend.values.values, contains(clientSecret));
    });

    test('短期导入模式：读完即丢，存储一次都不写', () async {
      final backend = MemoryBackend();
      final access = TailscaleCatalogAccess(
        TailscaleCatalogSecretStore(backend),
        client,
      );
      await access.readOnceWithToken(pastedToken);
      final result = await access.readWithOAuthClient(
        catalogId: 'cat-1',
        credential: oauth,
        persist: false,
      );
      expect(result.refusal, PersistRefusal.notRequested);
      expect(backend.writes, 0);
    });
  });

  group('TSC09 secret 只在受控存储/内存和官方请求里', () {
    test('要求持续刷新、token 经确认只读设备：只存 client 两项，不存 access token', () async {
      final backend = MemoryBackend();
      final access = TailscaleCatalogAccess(
        TailscaleCatalogSecretStore(backend),
        client,
      );
      final result = await access.readWithOAuthClient(
        catalogId: 'cat-1',
        credential: oauth,
        persist: true,
      );
      expect(result.persisted, isTrue);
      expect(backend.values, {
        'tailscale.catalog.cat-1.oauth.clientId': clientId,
        'tailscale.catalog.cat-1.oauth.clientSecret': clientSecret,
      });

      // 再刷新复用内存里的 token，不重新换，也不写存储。
      await access.refreshSaved(catalogId: 'cat-1');
      expect(fake.at(tokenPath), hasLength(1));
      expect(backend.writes, 2);

      await access.forgetSaved('cat-1');
      expect(backend.values, isEmpty);
    });

    test('要求持续刷新但范围未验证或偏大：不保存', () async {
      for (final (scope, refusal) in [
        (null, PersistRefusal.scopeUnverified),
        ('all:read', PersistRefusal.scopeBroaderThanDevices),
      ]) {
        fake.scripts[tokenPath] = [
          Reply(200, FakeTailscale.tokenBody(token: 't', scope: scope)),
        ];
        final backend = MemoryBackend();
        final result = await TailscaleCatalogAccess(
          TailscaleCatalogSecretStore(backend),
          client,
        ).readWithOAuthClient(
          catalogId: 'cat-1',
          credential: oauth,
          persist: true,
        );
        expect(result.refusal, refusal);
        expect(backend.writes, 0);
      }
    });

    test('错误对象、凭据对象的文本里没有 secret；服务器回显凭据也被抹掉', () async {
      fake.scripts[devicesPath] = [
        const Reply(403, '{"message":"token tok-1 lacks scope"}'),
      ];
      final error = await client(oauth)
          .listDevices()
          .then<Object>((_) => fail('应当失败'), onError: (Object e) => e);
      expect('$error', contains('<redacted>'));
      expectNoSecret(error);

      fake.scripts[devicesPath] = [
        const Reply(403, '{"message":"got $pastedToken"}'),
      ];
      final pasted = await client(const PastedAccessToken(pastedToken))
          .listDevices()
          .then<Object>((_) => fail('应当失败'), onError: (Object e) => e);
      expectNoSecret(pasted);

      expect('$oauth', isNot(contains(clientSecret)));
      expect(
        '${const PastedAccessToken(pastedToken)}',
        isNot(contains(pastedToken)),
      );
    });

    test('网络错误的文本里也没有凭据', () async {
      final unreachable = client(oauth);
      await fake.stop();
      final error = await unreachable
          .listDevices()
          .then<Object>((_) => fail('应当失败'), onError: (Object e) => e);
      expect(error, isA<TailscaleNetworkError>());
      expectNoSecret(error);
      await fake.start(); // 让 tearDown 的 stop 有东西可关
    });
  });

  test('运行时拼出来的报错整句在英文界面下能译完（不残留中文）', () async {
    ShunLocalizations.use('en');
    addTearDown(() => ShunLocalizations.use('zh-CN'));
    final han = RegExp(r'[一-鿿]');
    final replies = <Reply>[
      const Reply(403, '{"message":"nope"}'),
      const Reply(404, '{"message":"nope"}'),
      const Reply(429, '{"message":"nope"}'),
      const Reply(503, '{"message":"nope"}'),
      Reply(302, '', {'location': 'http://127.0.0.1:1/x'}),
      const Reply(200, '{}'),
      const Reply(401, '{}'),
    ];
    for (final reply in replies) {
      fake.scripts[devicesPath] = [reply];
      final error = await client(const PastedAccessToken(pastedToken))
          .listDevices()
          .then<Object>((_) => fail('应当失败'), onError: (Object e) => e);
      final english = ShunLocalizations.text('$error');
      expect(han.hasMatch(english), isFalse, reason: english);
    }
    fake.scripts[tokenPath] = [
      Reply(200, FakeTailscale.tokenBody(token: 't', scope: 'devices:core')),
    ];
    final broad = await client(oauth)
        .listDevices()
        .then<Object>((_) => fail('应当失败'), onError: (Object e) => e);
    final english = ShunLocalizations.text('$broad');
    expect(han.hasMatch(english), isFalse, reason: english);
  });

  group('设备 schema（官方默认字段集）', () {
    test('只留目录要用的字段；非法地址丢弃；零时间和缺字段记为不知道', () {
      final s = TailscaleDeviceSnapshot.parse(sampleDevices);
      expect(s.complete, isTrue);
      final nas = s.devices.first;
      expect(nas.id, '12345');
      expect(nas.addresses, ['100.64.0.7', 'fd7a:115c:a1e0::7']);
      expect(nas.name, 'nas.tail1234.ts.net');
      expect(nas.expires, isNull);
      expect(nas.tags, ['tag:server']);
      final phone = s.devices.last;
      expect(phone.authorized, isNull);
      expect(phone.connectedToControl, isNull);
      expect(phone.os, isNull);
      expect(phone.lastSeen, DateTime.utc(2026, 9, 29, 10));
    });

    test('缺 id、重复 id：快照不完整（R12 据此不推断删除）', () {
      final s = TailscaleDeviceSnapshot.parse(
        jsonEncode({
          'devices': [
            {'id': 'a'},
            {'hostname': 'no-id'},
            'not-an-object',
            {'id': 'a', 'hostname': 'dup'},
          ],
        }),
      );
      expect(s.devices, hasLength(1));
      expect(s.skippedEntries, 2);
      expect(s.duplicateIds, {'a'});
      expect(s.complete, isFalse);
    });

    test('结构不对的响应是错误，不是「没有设备」', () async {
      for (final body in ['{}', '[]', '{"devices":{}}', 'oops']) {
        fake.scripts[devicesPath] = [Reply(200, body)];
        await expectLater(
          client(oauth).listDevices(),
          throwsA(isA<TailscaleMalformedResponse>()),
          reason: body,
        );
      }
    });
  });
}
