import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/http_client_provider.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/sync/vault_crypto.dart';
import 'package:shun/presentation/screens/cloud_backup_screen.dart';

// 云端备份页：恢复走真的解密和确认框（服务器是假的，真 WebDAV、S3 没试过），离开页面时表单不丢。
const _master = 'long-enough-master';
const _cloudPassword = 'cloud-host-password';

VaultData _cloudVault() => VaultData.fromJson({
      'hosts': [
        {
          'id': 'from-cloud',
          'label': 'from-cloud',
          'hostname': 'cloud.example',
          'username': 'ops',
          'port': 22,
          'protocol': 'ssh',
          'authMethod': 'password',
          'password': _cloudPassword,
        },
      ],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> secure;
  late VaultRepository repository;
  late List<http.BaseRequest> requests;
  // PBKDF2 一次约 3 秒，整个文件只加密这一份。
  late String cloudFile;

  setUpAll(() async {
    final file = await VaultCrypto.encrypt(
      vault: _cloudVault(),
      password: _master,
      deviceId: 'other-phone',
      deviceName: 'shun',
      appVersion: 'test',
    );
    cloudFile = jsonEncode(file.toJson());
  });

  setUp(() async {
    secure = {};
    requests = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          secure[key!] = args['value'] as String;
        case 'read':
          return secure[key];
        case 'delete':
          secure.remove(key);
        case 'readAll':
          return secure;
        case 'containsKey':
          return secure.containsKey(key);
      }
      return null;
    });
    SharedPreferences.setMockInitialValues({});
    repository = await VaultRepository.open();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> configure({String password = _master}) async {
    await repository.saveSyncConnection(const SyncConnection(
      type: SyncProviderType.webdav,
      endpoint: 'https://dav.example.com/shun',
      username: 'me',
      secret: 'dav-secret',
    ));
    await repository.saveMasterPassword(password);
  }

  /// 首页一个按钮，点了进云端备份页：要验证返回回到哪、会不会多关一页。
  Future<void> open(
    WidgetTester tester, {
    String? remote,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET' && remote != null) {
        return http.Response(remote, 200, headers: {
          'content-type': 'application/json; charset=utf-8',
        });
      }
      return http.Response('', 404);
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        httpClientProvider.overrideWithValue(client),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CloudBackupScreen(),
                ),
              ),
              child: const Text('launcher'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('launcher'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  /// 解密在别的 isolate 里真算，假时钟等不到它，要让真时间走起来。
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 300; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等不到 $finder');
  }

  Future<VaultData> freshVault() async {
    final reopened = await VaultRepository.open();
    return reopened.loadVault();
  }

  group('从云端恢复', () {
    testWidgets('先问再写，写进来带凭据；只读云端，不往上写', (tester) async {
      await configure();
      await open(tester, remote: cloudFile);

      await tester.tap(find.byKey(const ValueKey('cloud-restore')));
      await waitFor(tester, find.text('恢复备份'));
      expect(find.textContaining('备份里有 1 台主机'), findsOneWidget);
      expect((await freshVault()).hosts, isEmpty, reason: '没确认前不写');

      await tester.tap(find.byKey(const ValueKey('vault-import-merge')));
      await waitFor(tester, find.textContaining('恢复完成'));

      final hosts = (await freshVault()).hosts;
      expect(hosts.map((host) => host.id), ['from-cloud']);
      expect(hosts.single.password, _cloudPassword);
      expect(requests.map((request) => request.method).toSet(), {'GET'});
      expect(
        requests.single.url.toString(),
        'https://dav.example.com/shun/shun-vault.json',
      );
    });

    testWidgets('确认框点取消：本机不动', (tester) async {
      await configure();
      await open(tester, remote: cloudFile);

      await tester.tap(find.byKey(const ValueKey('cloud-restore')));
      await waitFor(tester, find.text('恢复备份'));
      await tester.tap(find.byKey(const ValueKey('vault-import-cancel')));
      await tester.pump(const Duration(seconds: 1));

      expect((await freshVault()).hosts, isEmpty);
    });

    testWidgets('主密码不对：说清楚，本机不动', (tester) async {
      await configure(password: 'wrong-but-long-enough');
      await open(tester, remote: cloudFile);

      await tester.tap(find.byKey(const ValueKey('cloud-restore')));
      await waitFor(tester, find.text('主密码不对，或者云端文件已损坏'));

      expect(find.text('恢复备份'), findsNothing);
      expect((await freshVault()).hosts, isEmpty);
    });

    testWidgets('云端还没有备份：说清楚，不算解密失败', (tester) async {
      await configure();
      await open(tester);

      await tester.tap(find.byKey(const ValueKey('cloud-restore')));
      await waitFor(tester, find.textContaining('云端还没有备份'));
    });

    testWidgets('主密码不到 12 位：拦住，不发请求', (tester) async {
      await configure(password: 'short');
      await open(tester, remote: cloudFile);

      await tester.tap(find.byKey(const ValueKey('cloud-restore')));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('主密码至少 12 位'), findsOneWidget);
      expect(requests, isEmpty);
    });
  });

  group('离开这页', () {
    Finder field(String label) => find.widgetWithText(TextField, label);

    Future<void> leave(WidgetTester tester) async {
      await tester.tap(find.byType(BackButton));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('填了没点按钮：存下来，再进来还在', (tester) async {
      await open(tester);
      await tester.enterText(field('WebDAV 地址'), 'https://dav.example.com/x');
      await tester.enterText(field('用户名'), 'me');
      await tester.enterText(field('主密码'), _master);
      await leave(tester);

      expect(find.text('launcher'), findsOneWidget);
      final saved = await repository.loadSyncConnection();
      expect(saved?.endpoint, 'https://dav.example.com/x');
      expect(saved?.username, 'me');
      expect(await repository.readMasterPassword(), _master);
      expect(requests, isEmpty, reason: '存配置不外连');

      await tester.tap(find.text('launcher'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('https://dav.example.com/x'), findsOneWidget);
    });

    testWidgets('主密码不到 12 位：地址存下，主密码留原来的，并且告诉用户', (tester) async {
      await configure();
      await open(tester);
      await tester.enterText(field('WebDAV 地址'), 'https://dav.example.com/y');
      await tester.enterText(field('主密码'), 'short');
      await leave(tester);

      expect(
        (await repository.loadSyncConnection())?.endpoint,
        'https://dav.example.com/y',
      );
      expect(await repository.readMasterPassword(), _master);
      expect(find.text('主密码不到 12 位，没有保存'), findsOneWidget);
    });

    testWidgets('存着 WebDAV，切到 S3 看一眼就返回：配置不动，并且告诉用户', (tester) async {
      await configure();
      await open(tester);
      await tester.tap(find.text('S3'));
      await tester.pump(const Duration(seconds: 1));
      await leave(tester);

      final saved = await repository.loadSyncConnection();
      expect(saved?.type, SyncProviderType.webdav);
      expect(saved?.username, 'me');
      expect(find.text('存储方式没换，点「立即备份」才算'), findsOneWidget);
    });

    testWidgets('第一次配就选 S3：填了返回也存下', (tester) async {
      await open(tester);
      await tester.tap(find.text('S3'));
      await tester.pump(const Duration(seconds: 1));
      await tester.enterText(field('S3 Endpoint'), 'https://s3.example.com');
      await tester.enterText(field('Bucket'), 'b');
      await leave(tester);

      final saved = await repository.loadSyncConnection();
      expect(saved?.type, SyncProviderType.s3);
      expect(saved?.bucket, 'b');
    });

    testWidgets('没改过：配置原样，口令还在', (tester) async {
      await configure();
      await open(tester);
      await leave(tester);

      final saved = await repository.loadSyncConnection();
      expect(saved?.endpoint, 'https://dav.example.com/shun');
      expect(saved?.secret, 'dav-secret');
      expect(await repository.readMasterPassword(), _master);
    });

    testWidgets('连按两次返回：只关这一页，不把首页也关掉', (tester) async {
      await open(tester);
      await tester.enterText(field('用户名'), 'me');
      final back = find.byType(BackButton);
      await tester.tap(back);
      await tester.tap(back, warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('launcher'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
