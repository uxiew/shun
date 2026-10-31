import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/vault_import.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/encrypted_vault_file.dart';
import 'package:shun/infrastructure/storage/vault_export_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/sync/vault_crypto.dart';
import 'package:shun/presentation/widgets/vault_passphrase_dialog.dart';

// SYN01：加密备份导出再导入。PBKDF2 60 万次，每次加解密都要算一会，文件复用一份。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const passphrase = 'correct horse battery';

  VaultData vault() => VaultData.fromJson({
        'hosts': [
          {
            'id': 'web',
            'label': 'web',
            'hostname': '192.0.2.10',
            'username': 'ops',
            'port': 22,
            'protocol': 'ssh',
            'authMethod': 'password',
            'password': 'HOST-PASSWORD',
            'telnetPassword': 'TELNET-PASSWORD',
            'totp': {'uri': 'otpauth://totp/x?secret=TOTP-SEED'},
            'proxyConfig': {
              'type': 'socks5',
              'host': 'proxy.example',
              'port': 1080,
              'password': 'PROXY-PASSWORD',
            },
            'lastConnectedAt': 1234,
          },
        ],
        'keys': [
          {
            'id': 'k1',
            'label': 'laptop',
            'privateKey': 'PRIVATE-KEY-BODY',
            'passphrase': 'KEY-PASSPHRASE',
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
            'password': 'IDENTITY-PASSWORD',
          },
        ],
        'knownHosts': [
          {
            'hostname': '192.0.2.10',
            'port': 22,
            'keyType': 'ssh-ed25519',
            'fingerprint': 'SHA256:THIS-PHONE-ONLY',
          },
        ],
        'convergentSync': {'schemaVersion': 2},
      });

  late Uint8List bytes;
  late String text;
  setUpAll(() async {
    bytes = await EncryptedVaultFile.encode(
      vault: vault(),
      passphrase: passphrase,
      appVersion: 'test',
    );
    text = utf8.decode(bytes);
  });

  group('导出', () {
    test('文件里搜不到任何凭据、主机地址、指纹或设备 ID', () {
      for (final secret in [
        'HOST-PASSWORD',
        'TELNET-PASSWORD',
        'TOTP-SEED',
        'PROXY-PASSWORD',
        'PRIVATE-KEY-BODY',
        'KEY-PASSPHRASE',
        'IDENTITY-PASSWORD',
        '192.0.2.10',
        'THIS-PHONE-ONLY',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      final meta = (jsonDecode(text) as Map)['meta'] as Map;
      expect(meta['deviceId'], 'file-export');
      expect(meta['kdfIterations'], 600000);
      expect(meta['algorithm'], 'AES-256-GCM');
    });

    test('解开后凭据都在；指纹、同步元数据不在', () async {
      final file = EncryptedVaultFile.tryParse(bytes)!;
      final back = await EncryptedVaultFile.decrypt(file, passphrase);
      expect(back.hosts.single.password, 'HOST-PASSWORD');
      expect(back.hosts.single.data['telnetPassword'], 'TELNET-PASSWORD');
      expect((back.hosts.single.data['totp'] as Map)['uri'],
          contains('TOTP-SEED'));
      expect(
        (back.hosts.single.data['proxyConfig'] as Map)['password'],
        'PROXY-PASSWORD',
      );
      expect(back.keys.single.privateKey, 'PRIVATE-KEY-BODY');
      expect(back.keys.single.passphrase, 'KEY-PASSPHRASE');
      expect(
        (back.extras['identities'] as List).single['password'],
        'IDENTITY-PASSWORD',
      );
      expect(back.extras.containsKey('knownHosts'), isFalse);
      expect(back.extras.containsKey('convergentSync'), isFalse);
    });

    test('存文件走同一条路：文件名写明是加密备份', () async {
      String? name;
      List<int>? saved;
      final service = VaultExportService(
        pickerWritesBytes: true,
        saveFile: ({
          dialogTitle,
          fileName,
          type = FileType.any,
          allowedExtensions,
          bytes,
        }) async {
          name = fileName;
          saved = bytes;
          return 'content://saved';
        },
      );
      final result = await service.exportEncrypted(bytes);
      expect(result, VaultExportResult.saved);
      expect(name, 'shun-backup-encrypted.json');
      expect(saved, bytes);
    });
  });

  group('导入', () {
    test('明文导出的 JSON 不当成加密备份', () {
      final plain = utf8.encode(jsonEncode(vault().toJson()));
      expect(EncryptedVaultFile.tryParse(plain), isNull);
      expect(EncryptedVaultFile.tryParse(utf8.encode('not json')), isNull);
      expect(EncryptedVaultFile.tryParse(utf8.encode('[1,2]')), isNull);
      expect(
        EncryptedVaultFile.tryParse(utf8.encode('{"meta":{},"payload":1}')),
        isNull,
      );
      expect(EncryptedVaultFile.tryParse(const []), isNull);
    });

    test('错口令、改过一个字节、截断：都报一句人话，不带内容', () async {
      final file = EncryptedVaultFile.tryParse(bytes)!;
      Future<void> rejects(SyncedVaultFile target, String password) =>
          expectLater(
            EncryptedVaultFile.decrypt(target, password),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                EncryptedVaultFile.wrongPassphraseOrDamaged,
              ),
            ),
          );

      await rejects(file, 'wrong passphrase!');

      final body = base64.decode(file.payload);
      body[10] ^= 0x01;
      await rejects(
        SyncedVaultFile(meta: file.meta, payload: base64.encode(body)),
        passphrase,
      );
      await rejects(
        SyncedVaultFile(meta: file.meta, payload: base64.encode([1, 2, 3])),
        passphrase,
      );
      await rejects(
        SyncedVaultFile(meta: const {'algorithm': 'AES-256-GCM'}, payload: ''),
        passphrase,
      );
    });

    test('派生次数被改成天文数字：不算，直接拒绝', () async {
      final file = EncryptedVaultFile.tryParse(bytes)!;
      await expectLater(
        EncryptedVaultFile.decrypt(
          SyncedVaultFile(
            meta: {...file.meta, 'kdfIterations': 1 << 40},
            payload: file.payload,
          ),
          passphrase,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            EncryptedVaultFile.iterationsRejected,
          ),
        ),
      );
    });

    test('不是保险库的文件：报一句人话', () {
      for (final bad in ['not json', '[1,2]', '{"meta":{},"payload":"x']) {
        expect(
          () => EncryptedVaultFile.parsePlain(utf8.encode(bad)),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              EncryptedVaultFile.notAVaultFile,
            ),
          ),
          reason: bad,
        );
      }
    });

    test('明文 JSON 被覆盖后留尾巴：也能读', () {
      final plain = [
        ...utf8.encode(
            '{"hosts":[],"keys":[],"snippets":[],"customGroups":["a}"]}'),
        ...utf8.encode(' "old tail"}]'),
        0xE4,
      ];
      expect(EncryptedVaultFile.parsePlain(plain).customGroups, ['a}']);
    });

    test('加解密在后台 isolate：错误能传回来', () async {
      final encoded = await EncryptedVaultFile.encode(
          vault: vault(), passphrase: passphrase, appVersion: 'test');
      final back = await EncryptedVaultFile.decrypt(
        EncryptedVaultFile.tryParse(encoded)!,
        passphrase,
      );
      expect(back.hosts.single.password, 'HOST-PASSWORD');
      await expectLater(
        EncryptedVaultFile.decrypt(
          EncryptedVaultFile.tryParse(encoded)!,
          'wrong passphrase!',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('短文件覆盖长文件留下尾巴：照样能解开', () async {
      // 有的存储服务 openOutputStream 默认不截断，文件尾部是旧内容。
      final withTail = Uint8List.fromList([
        ...bytes,
        ...utf8.encode('"old tail"}], "x": {"meta": 1}'),
        0xFF,
        0xFE,
      ]);
      final file = EncryptedVaultFile.tryParse(withTail)!;
      final back = await EncryptedVaultFile.decrypt(file, passphrase);
      expect(back.hosts.single.password, 'HOST-PASSWORD');
    });

    test('导入计划：凭据跟着来，指纹还是本机的；写盘进安全存储', () async {
      final secrets = <String, String>{};
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map?) ?? const {};
        final key = args['key'] as String?;
        switch (call.method) {
          case 'write':
            secrets[key!] = args['value'] as String;
          case 'read':
            return secrets[key];
          case 'delete':
            secrets.remove(key);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      SharedPreferences.setMockInitialValues({});

      final file = EncryptedVaultFile.tryParse(bytes)!;
      final incoming = await EncryptedVaultFile.decrypt(file, passphrase);
      final local = VaultData.fromJson({
        'hosts': const [],
        'keys': const [],
        'snippets': const [],
        'customGroups': const [],
        'knownHosts': [
          {
            'hostname': 'mine.example',
            'port': 22,
            'keyType': 'ssh-ed25519',
            'fingerprint': 'SHA256:MINE',
          },
        ],
      });
      final plan = planVaultImport(incoming, local);
      expect(plan.addedHosts.single.id, 'web');
      expect(plan.credentialsNotCarried, isEmpty);
      final merged = plan.result(VaultImportMode.merge);
      expect(merged.hosts.single.password, 'HOST-PASSWORD');
      expect(
        (merged.extras['knownHosts'] as List).single['fingerprint'],
        'SHA256:MINE',
      );

      final repository = await VaultRepository.open();
      await repository.saveVault(merged);
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('shun_vault_v1')!;
      for (final secret in [
        'HOST-PASSWORD',
        'TELNET-PASSWORD',
        'TOTP-SEED',
        'PROXY-PASSWORD',
        'PRIVATE-KEY-BODY',
        'KEY-PASSPHRASE',
        'IDENTITY-PASSWORD',
      ]) {
        expect(stored, isNot(contains(secret)), reason: '$secret 不进普通偏好');
        expect(
          secrets.values.where((value) => value.contains(secret)),
          isNotEmpty,
          reason: '$secret 进安全存储',
        );
      }
    });
  });

  group('口令框', () {
    Future<List<String?>> open(
      WidgetTester tester,
      Future<String?> Function(BuildContext) ask,
    ) async {
      final result = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result.add(await ask(context)),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('短了、两次不一样都不让过；对了才返回', (tester) async {
      final result = await open(tester, askNewBackupPassphrase);
      Future<void> submit(String first, String second) async {
        await tester.enterText(
          find.byKey(const ValueKey('backup-passphrase')),
          first,
        );
        await tester.enterText(
          find.byKey(const ValueKey('backup-passphrase-again')),
          second,
        );
        await tester
            .tap(find.byKey(const ValueKey('backup-passphrase-confirm')));
        await tester.pumpAndSettle();
      }

      await submit('short', 'short');
      expect(find.text(EncryptedVaultFile.passphraseTooShort), findsOneWidget);
      expect(result, isEmpty);
      await submit('long enough one', 'long enough two');
      expect(find.text('两次输入不一样'), findsOneWidget);
      expect(result, isEmpty);
      await submit('long enough one', 'long enough one');
      expect(result, ['long enough one']);
    });

    testWidgets('取消返回 null', (tester) async {
      final result = await open(tester, askNewBackupPassphrase);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, [null]);
    });

    testWidgets('导入：口令错了再问，对了返回；文件的问题不再问', (tester) async {
      final tried = <String>[];
      final file = EncryptedVaultFile.tryParse(bytes)!;
      final decoded = <VaultData?>[];
      Object? thrown;
      final good = VaultData.fromJson(const {
        'hosts': [],
        'keys': [],
        'snippets': [],
        'customGroups': [],
      });
      await open(tester, (context) async {
        try {
          decoded.add(
            await askAndDecodeBackup(
              context,
              file,
              decode: (_, passphrase) async {
                tried.add(passphrase);
                if (passphrase == 'right') return good;
                if (passphrase == 'rounds') {
                  throw const FormatException(
                    EncryptedVaultFile.iterationsRejected,
                  );
                }
                throw const FormatException(
                  EncryptedVaultFile.wrongPassphraseOrDamaged,
                );
              },
            ),
          );
        } on FormatException catch (error) {
          thrown = error;
        }
        return null;
      });
      Future<void> submit(String value) async {
        await tester.enterText(
          find.byKey(const ValueKey('backup-passphrase')),
          value,
        );
        await tester
            .tap(find.byKey(const ValueKey('backup-passphrase-confirm')));
        await tester.pumpAndSettle();
      }

      await submit('bad');
      expect(
        find.text(EncryptedVaultFile.wrongPassphraseOrDamaged),
        findsOneWidget,
      );
      await submit('right');
      expect(tried, ['bad', 'right']);
      expect(decoded.single, same(good));
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await submit('rounds');
      expect(thrown, isA<FormatException>());
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('导入时：上次的问题写在框下；空的不提交', (tester) async {
      final result = await open(
        tester,
        (context) => askBackupPassphrase(
          context,
          problem: EncryptedVaultFile.wrongPassphraseOrDamaged,
        ),
      );
      expect(
        find.text(EncryptedVaultFile.wrongPassphraseOrDamaged),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('backup-passphrase-confirm')));
      await tester.pumpAndSettle();
      expect(result, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('backup-passphrase')),
        'anything',
      );
      await tester.tap(find.byKey(const ValueKey('backup-passphrase-confirm')));
      await tester.pumpAndSettle();
      expect(result, ['anything']);
    });
  });
}
