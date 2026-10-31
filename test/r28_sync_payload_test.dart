import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/sync/cloud_sync_service.dart';
import 'package:shun/infrastructure/sync/vault_crypto.dart';

// R28 / REG03：云同步在本 fork 里是关着的（fork_features.dart），但代码还在，将来打开时
// 上传的就是这里抓到的字节。看两件事：发出去的任何字节（包括请求头以外的 URL、正文）
// 里没有主机密码、私钥、主密码的明文；用主密码解开后字段和不认识的字段都还在。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secure = <String, String>{};
  setUp(() {
    secure.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
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

  test('REG03 同步上传：正文和 URL 里没有主机密码 / 私钥 / 主密码明文，解开后字段不丢', () async {
    SharedPreferences.setMockInitialValues({});
    const hostPassword = 'R28-HOST-PW-7d1c';
    const privateKey = 'R28-PRIVATE-KEY-9e4b';
    const master = 'R28-MASTER-3a0f';
    const davSecret = 'R28-DAV-SECRET-51c2';
    final repository = await VaultRepository.open();
    await repository.saveSyncConnection(const SyncConnection(
      type: SyncProviderType.webdav,
      endpoint: 'dav.example.com/r28',
      username: 'r28',
      secret: davSecret,
    ));
    await repository.saveMasterPassword(master);

    final sent = <http.Request>[];
    List<int>? stored;
    final client = MockClient((request) async {
      sent.add(request);
      if (request.method == 'GET') {
        return stored == null
            ? http.Response('', 404)
            : http.Response.bytes(stored!, 200,
                headers: {'content-type': 'application/json'});
      }
      if (request.method == 'PUT') {
        stored = List<int>.from(request.bodyBytes);
        return http.Response('', 201);
      }
      if (request.method == 'MOVE') return http.Response('', 201);
      return http.Response('', 405);
    });
    final local = VaultData.empty().copyWith(
      hosts: [
        HostProfile({
          'id': 'r28-host',
          'label': 'r28',
          'hostname': 'r28.example.com',
          'port': 22,
          'username': 'root',
          'password': hostPassword,
          'authMethod': 'password',
          'protocol': 'ssh',
          'r28UnknownField': {'kept': true},
        }),
      ],
      keys: [
        SshKeyProfile({
          'id': 'r28-key',
          'label': 'r28',
          'privateKey': privateKey,
          'r28UnknownField': 'kept',
        }),
      ],
    );

    final result = await CloudSyncService(
      repository,
      client: client,
      deviceId: 'r28-device',
      appVersion: '0.0.0',
    ).push(local);
    expect(result.vault.hosts.single.id, 'r28-host');

    // 对照：搜法本身能搜到标记——本地 JSON 里确实有。
    final plain = jsonEncode(local.toJson());
    expect(plain, allOf(contains(hostPassword), contains(privateKey)));
    expect(sent.where((r) => r.method == 'PUT'), isNotEmpty);
    for (final request in sent) {
      final wire = '${request.url}\n${utf8.decode(request.bodyBytes, allowMalformed: true)}';
      for (final marker in [hostPassword, privateKey, master, davSecret]) {
        expect(wire, isNot(contains(marker)),
            reason: '${request.method} ${request.url} 带了明文 $marker');
      }
      // WebDAV 密码只该在发往用户填的那个端点的认证头里。
      expect(request.url.host, 'dav.example.com');
      expect(request.headers.toString(), isNot(contains(hostPassword)));
    }

    final file = SyncedVaultFile.fromJson(
        jsonDecode(utf8.decode(stored!)) as Map<String, dynamic>);
    await expectLater(VaultCrypto.decrypt(file, 'wrong-$master'),
        throwsA(anything));
    final back = await VaultCrypto.decrypt(file, master);
    expect(back.hosts.single.data['password'], hostPassword);
    expect(back.hosts.single.data['r28UnknownField'], {'kept': true});
    expect(back.keys.single.data['privateKey'], privateKey);
    expect(back.keys.single.data['r28UnknownField'], 'kept');
  });
}
