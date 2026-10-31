import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/auto_sync_controller.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/sync/cloud_sync_service.dart';
import 'package:shun/infrastructure/sync/vault_crypto.dart';
import 'package:shun/infrastructure/sync/sync_safety.dart';

// SYN02（R61）：两台手机经本机的假服务器同步。请求真的走 TLS 和本机网络，加密、合并、写安全存储都是真的代码；
// 假的是服务器的实现（只有 GET、PUT、MOVE、DELETE）和安全存储的底层（真的安全存储见 tool/r60-backup.py）。
// 这是补 R28 的：R28 审查时身份密码、TOTP 还没搬进安全存储（e75bc98），要确认它们照样往返、不落明文。
// 没有真 WebDAV、S3 账号，不算真服务通过。
const _master = 'R61-MASTER-long-enough';
const _secrets = <String>[
  'R61-HOST-PW',
  'R61-TELNET-PW',
  'R61-TOTP-SEED',
  'R61-PROXY-PW',
  'R61-PRIVATE-KEY',
  'R61-KEY-PASS',
  'R61-IDENTITY-PW',
];

VaultData _vault() => VaultData.fromJson({
      'hosts': [
        {
          'id': 'web',
          'label': 'web',
          'hostname': 'r61-host.example',
          'username': 'ops',
          'port': 22,
          'protocol': 'ssh',
          'authMethod': 'password',
          'password': 'R61-HOST-PW',
          'telnetPassword': 'R61-TELNET-PW',
          'totp': {'uri': 'otpauth://totp/x?secret=R61-TOTP-SEED'},
          'proxyConfig': {
            'type': 'socks5',
            'host': 'proxy.example',
            'port': 1080,
            'password': 'R61-PROXY-PW',
          },
        },
      ],
      'keys': [
        {
          'id': 'k1',
          'label': 'laptop',
          'privateKey': 'R61-PRIVATE-KEY',
          'passphrase': 'R61-KEY-PASS',
        },
      ],
      'snippets': const [],
      'customGroups': const [],
      'identities': [
        {
          'id': 'pw',
          'label': 'pw',
          'username': 'ops',
          'authMethod': 'password',
          'password': 'R61-IDENTITY-PW',
        },
      ],
      'knownHosts': [
        {
          'hostname': 'r61-host.example',
          'port': 22,
          'keyType': 'ssh-ed25519',
          'fingerprint': 'SHA256:R61-THIS-PHONE-ONLY',
        },
      ],
    });

/// 本机的 HTTPS 服务器：WebDAV 和路径式 S3 在这几个动作上语义一样。
class _FakeServer {
  _FakeServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<_FakeServer> start(SecurityContext context) async =>
      _FakeServer._(
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context),
      );

  final HttpServer _server;
  final files = <String, List<int>>{};
  final requests = <String>[];
  var _revision = 0;

  String get origin => 'https://localhost:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = <int>[];
    await request.forEach(body.addAll);
    final path = request.uri.path;
    final headers = StringBuffer();
    request.headers.forEach((name, values) => headers.write('$name=$values;'));
    requests.add(
      '${request.method} $path\n$headers\n'
      '${utf8.decode(body, allowMalformed: true)}',
    );
    final response = request.response;
    response.headers.set('etag', '"r$_revision"');
    switch (request.method) {
      case 'GET':
      case 'HEAD':
        final stored = files[path];
        if (stored == null) {
          response.statusCode = 404;
        } else if (request.method == 'GET') {
          response.add(stored);
        }
      case 'PUT':
        files[path] = body;
        _revision++;
        response.statusCode = 201;
        response.headers.set('etag', '"r$_revision"');
      case 'MOVE':
        final to = Uri.parse(request.headers.value('destination')!).path;
        final moved = files.remove(path);
        if (moved == null) {
          response.statusCode = 404;
        } else {
          files[to] = moved;
          _revision++;
          response.statusCode = 201;
        }
      case 'DELETE':
        files.remove(path);
        response.statusCode = 204;
      default:
        response.statusCode = 405;
    }
    await response.close();
  }
}

/// 真的 HTTP 客户端，除了这张测试证书不信别的。记下每个请求发往哪里，确认没有别的去处。
class _RecordingClient extends http.BaseClient {
  _RecordingClient(String certificatePem)
      : _inner = IOClient(
          // macOS 的证书校验不认这张临时证书当根（报 application verification failure），
          // 所以只放过内容完全相同的这一张。
          HttpClient()
            ..badCertificateCallback = (certificate, _, __) =>
                certificate.pem.trim() == certificatePem,
        );

  final http.Client _inner;
  final urls = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    urls.add(request.url);
    return _inner.send(request);
  }
}

/// 一台手机的本地数据。每次 [use] 都是一次冷启动：仓库重新打开，凭据从安全存储重新读。
class _Phone {
  var prefs = <String, Object>{};
  final secure = <String, String>{};

  static _Phone? _current;

  Future<T> use<T>(Future<T> Function(VaultRepository) body) async {
    _current = this;
    SharedPreferences.setMockInitialValues(prefs);
    final repository = await VaultRepository.open();
    final result = await body(repository);
    final saved = await SharedPreferences.getInstance();
    prefs = {for (final key in saved.getKeys()) key: saved.get(key)!};
    return result;
  }

  String get plainPrefs => prefs.values.join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Directory certificates;
  late SecurityContext serverContext;
  late String certificatePem;

  setUpAll(() async {
    // 测试绑定默认把所有真实 HTTP 都拦成 400。
    HttpOverrides.global = null;
    certificates = await Directory.systemTemp.createTemp('shun-r61-');
    final made = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
      '-addext',
      'subjectAltName=DNS:localhost',
      '-keyout',
      '${certificates.path}/key.pem',
      '-out',
      '${certificates.path}/cert.pem',
    ]);
    if (made.exitCode != 0) throw StateError('${made.stderr}');
    serverContext = SecurityContext()
      ..useCertificateChain('${certificates.path}/cert.pem')
      ..usePrivateKey('${certificates.path}/key.pem');
    certificatePem =
        File('${certificates.path}/cert.pem').readAsStringSync().trim();
  });

  tearDownAll(() => certificates.delete(recursive: true));

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final secure = _Phone._current!.secure;
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final key = args['key']?.toString();
      switch (call.method) {
        case 'write':
          secure[key!] = '${args['value']}';
        case 'read':
          return secure[key];
        case 'delete':
          secure.remove(key);
        case 'readAll':
          return Map<String, String>.from(secure);
        case 'containsKey':
          return secure.containsKey(key);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 走和 App 一样的路：同步前读出带凭据的保险库，结果经仓库写回去。
  Future<void> syncNow(
    VaultRepository repository,
    http.Client client, {
    bool confirmShrink = false,
  }) async {
    final service = CloudSyncService(
      repository,
      client: client,
      deviceId: 'r61-device',
      appVersion: '0.0.0',
      githubEnabled: false,
    );
    final controller = AutoSyncController(
      localChanges: repository.localChanges,
      loadVault: repository.loadVault,
      synchronize: service.synchronize,
      synchronizeConfirmed: (vault) =>
          service.synchronize(vault, overrideShrink: true),
      applyVault: (vault) => repository.saveVault(vault, remote: true),
      retryDelays: const [],
    );
    try {
      await controller.synchronizeNow(confirmShrink: confirmShrink);
    } finally {
      controller.dispose();
    }
  }

  Future<void> configure(VaultRepository repository, SyncConnection c) async {
    await repository.saveSyncConnection(c);
    await repository.saveMasterPassword(_master);
  }

  final connections = <String, SyncConnection Function(String)>{
    'WebDAV': (origin) => SyncConnection(
          type: SyncProviderType.webdav,
          endpoint: '$origin/r61',
          username: 'r61',
          secret: 'R61-DAV-SECRET',
        ),
    'S3': (origin) => SyncConnection(
          type: SyncProviderType.s3,
          endpoint: origin,
          region: 'us-east-1',
          bucket: 'r61',
          accessKeyId: 'R61AK',
          secret: 'R61-S3-SECRET',
          prefix: 'shun',
          forcePathStyle: true,
        ),
  };

  connections.forEach((name, connectionFor) {
    test('$name：凭据加密上传，另一台手机拉下来进安全存储；改了再往返一次', () async {
      final server = await _FakeServer.start(serverContext);
      addTearDown(server.close);
      final client = _RecordingClient(certificatePem);
      final connection = connectionFor(server.origin);
      final phoneA = _Phone();
      final phoneB = _Phone();

      await phoneA.use((repository) async {
        await configure(repository, connection);
        await repository.saveVault(_vault());
        await syncNow(repository, client);
      });

      // 对照：搜法本身能搜到标记。
      expect(jsonEncode(_vault().toJson()), contains(_secrets.first));
      expect(server.requests.where((r) => r.startsWith('PUT')), isNotEmpty);
      final wire = server.requests.join('\n');
      for (final secret in [..._secrets, _master, 'r61-host.example']) {
        expect(wire, isNot(contains(secret)), reason: secret);
      }
      expect(client.urls, isNotEmpty);
      for (final url in client.urls) {
        expect('${url.scheme}://${url.host}:${url.port}', server.origin);
      }

      final stored =
          server.files.values.singleWhere((bytes) => bytes.isNotEmpty);
      final onServer = await VaultCrypto.decrypt(
        SyncedVaultFile.fromJson(
          jsonDecode(utf8.decode(stored)) as Map<String, dynamic>,
        ),
        _master,
      );
      expect(onServer.extras.containsKey('knownHosts'), isFalse,
          reason: '指纹不上传');

      await phoneB.use((repository) async {
        await configure(repository, connection);
        await syncNow(repository, client);
      });

      // 冷启动读回来：全部在，且来自安全存储。
      await phoneB.use((repository) async {
        final loaded = await repository.loadVault();
        expect(repository.unreadableSecrets, isEmpty);
        final host = loaded.hosts.single;
        expect(host.password, 'R61-HOST-PW');
        expect(host.data['telnetPassword'], 'R61-TELNET-PW');
        expect((host.data['totp'] as Map)['uri'], contains('R61-TOTP-SEED'));
        expect((host.data['proxyConfig'] as Map)['password'], 'R61-PROXY-PW');
        expect(loaded.keys.single.privateKey, 'R61-PRIVATE-KEY');
        expect(loaded.keys.single.passphrase, 'R61-KEY-PASS');
        expect(
          (loaded.extras['identities'] as List).single['password'],
          'R61-IDENTITY-PW',
        );
        expect(loaded.extras.containsKey('knownHosts'), isFalse);
      });
      for (final secret in _secrets) {
        expect(phoneB.plainPrefs, isNot(contains(secret)),
            reason: '$secret 不进普通偏好');
        expect(
          phoneB.secure.values.where((value) => value.contains(secret)),
          isNotEmpty,
          reason: '$secret 进安全存储',
        );
      }

      // B 改身份密码和 TOTP，A 同步后拿到新值，自己的指纹还在。
      await phoneB.use((repository) async {
        final loaded = await repository.loadVault();
        final json =
            jsonDecode(jsonEncode(loaded.toJson())) as Map<String, dynamic>;
        ((json['identities'] as List).single as Map)['password'] =
            'R61-NEW-IDENTITY-PW';
        ((json['hosts'] as List).single as Map)['totp'] = {
          'uri': 'otpauth://totp/x?secret=R61-NEW-TOTP',
        };
        await repository.saveVault(VaultData.fromJson(json));
        await syncNow(repository, client);
      });
      await phoneA.use((repository) async {
        await syncNow(repository, client);
      });
      await phoneA.use((repository) async {
        final loaded = await repository.loadVault();
        expect(
          (loaded.extras['identities'] as List).single['password'],
          'R61-NEW-IDENTITY-PW',
        );
        expect(
          (loaded.hosts.single.data['totp'] as Map)['uri'],
          contains('R61-NEW-TOTP'),
        );
        expect(
          (loaded.extras['knownHosts'] as List).single['fingerprint'],
          'SHA256:R61-THIS-PHONE-ONLY',
        );
      });
      expect(phoneA.plainPrefs, isNot(contains('R61-NEW-IDENTITY-PW')));
      expect(phoneA.plainPrefs, isNot(contains('R61-NEW-TOTP')));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  test('防误删：一次删 11 条主机被拦下，云端不动；确认后才写', () async {
    final server = await _FakeServer.start(serverContext);
    addTearDown(server.close);
    final client = _RecordingClient(certificatePem);
    final phone = _Phone();
    VaultData withHosts(int count) => VaultData.fromJson({
          ..._vault().toJson(),
          'hosts': [
            for (var i = 0; i < count; i++)
              {
                'id': 'h$i',
                'label': 'h$i',
                'hostname': 'h$i.example',
                'username': 'ops',
                'port': 22,
                'protocol': 'ssh',
                'authMethod': 'password',
              },
          ],
        });
    Map<String, String> onServer() => {
          for (final entry in server.files.entries)
            entry.key: base64Encode(entry.value),
        };

    await phone.use((repository) async {
      await configure(repository, connections['WebDAV']!(server.origin));
      await repository.saveVault(withHosts(12));
      await syncNow(repository, client);
    });
    final before = onServer();
    expect(before, isNotEmpty);

    await phone.use((repository) async {
      await repository.saveVault(withHosts(1));
      await expectLater(
        syncNow(repository, client),
        throwsA(isA<SyncShrinkException>()),
      );
    });
    expect(onServer(), before, reason: '拦下以后云端不该变');

    await phone.use((repository) async {
      await syncNow(repository, client, confirmShrink: true);
    });
    expect(onServer(), isNot(before), reason: '用户确认后才写');
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('没发出去就拒绝', () {
    Future<void> expectRefused(SyncConnection connection, String why) async {
      final client = _RecordingClient(certificatePem);
      await _Phone().use((repository) async {
        await configure(repository, connection);
        await repository.saveVault(_vault());
        final service = CloudSyncService(
          repository,
          client: client,
          githubEnabled: false,
        );
        await expectLater(
          service.synchronize(await repository.loadVault()),
          throwsA(predicate((Object error) => '$error'.contains(why))),
        );
      });
      expect(client.urls, isEmpty, reason: '一个请求都不该有');
    }

    test(
        '非 https 的 WebDAV',
        () => expectRefused(
              const SyncConnection(
                type: SyncProviderType.webdav,
                endpoint: 'http://dav.example.com/r61',
                username: 'r61',
                secret: 'secret',
              ),
              'WebDAV 必须使用 HTTPS',
            ));

    test(
        'GitHub：存着配置也不连 api.github.com',
        () => expectRefused(
              const SyncConnection(
                type: SyncProviderType.githubGist,
                endpoint: '',
                secret: 'token',
                resourceId: 'gist',
              ),
              '不支持同步到 GitHub',
            ));

    test('没配置：不发请求', () async {
      final client = _RecordingClient(certificatePem);
      await _Phone().use((repository) async {
        final service = CloudSyncService(repository, client: client);
        await expectLater(
          service.synchronize(VaultData.empty()),
          throwsA(isA<StateError>()),
        );
      });
      expect(client.urls, isEmpty);
    });
  });
}
