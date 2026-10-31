import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/vault_import.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/encrypted_vault_file.dart';
import 'package:shun/infrastructure/storage/vault_export_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/vault_passphrase_dialog.dart';

// SYN01 的设备部分：真的系统文件选择器、真的安全存储、后台 isolate。
// 文件选择器是系统界面，Flutter 点不到：测试打 `R60 ACTION=<动作>`，tool/r60-backup.py 在电脑上照做。
// 单独跑会卡在文件选择器上，要通过那个脚本跑。
void r60(String key, Object? value) => debugPrint('R60 $key=$value');

const _passphrase = 'correct horse battery';

VaultData _vault({required String tag, int filler = 0}) => VaultData.fromJson({
      'hosts': [
        {
          'id': 'web',
          'label': 'web',
          'hostname': '192.0.2.10',
          'username': 'ops',
          'port': 22,
          'protocol': 'ssh',
          'authMethod': 'password',
          'password': 'HOST-$tag',
          'totp': {'uri': 'otpauth://totp/x?secret=TOTP-$tag'},
        },
      ],
      'keys': [
        {
          'id': 'k1',
          'label': 'laptop',
          'privateKey': 'PRIVATE-$tag',
          'passphrase': 'KEYPASS-$tag',
        },
      ],
      'snippets': [
        for (var i = 0; i < filler; i++)
          {'id': 's$i', 'label': 'snippet $i', 'command': 'echo ${'x' * 200}'},
      ],
      'customGroups': const [],
      'identities': [
        {
          'id': 'pw',
          'label': 'pw',
          'username': 'ops',
          'authMethod': 'password',
          'password': 'IDENTITY-$tag',
        },
      ],
      'knownHosts': [
        {
          'hostname': '192.0.2.10',
          'port': 22,
          'keyType': 'ssh-ed25519',
          'fingerprint': 'SHA256:FROM-THE-OLD-PHONE',
        },
      ],
    });

Future<Uint8List> _pickBack() async {
  r60('ACTION', 'pick');
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['json'],
    withData: true,
  );
  final file = result!.files.single;
  return file.bytes ?? await File(file.path!).readAsBytes();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('存进系统文件选择器、选回来、解开、写进安全存储；短文件覆盖长文件', (tester) async {
    await tester.runAsync(() async {
      final service = VaultExportService();
      final watch = Stopwatch()..start();
      final long = await encodeBackupInBackground(
        _vault(tag: 'LONG', filler: 2000),
        _passphrase,
        'r60',
      );
      r60('encodeMs', watch.elapsedMilliseconds);
      r60('longBytes', long.length);

      r60('ACTION', 'save-new');
      expect(await service.exportEncrypted(long), VaultExportResult.saved);
      final back = await _pickBack();
      expect(back, long, reason: '存进去和读回来的字节要一样');

      watch.reset();
      final decoded = await decodeBackupInBackground(
        EncryptedVaultFile.tryParse(back)!,
        _passphrase,
      );
      r60('decodeMs', watch.elapsedMilliseconds);
      expect(decoded.hosts.single.password, 'HOST-LONG');

      await expectLater(
        decodeBackupInBackground(
          EncryptedVaultFile.tryParse(back)!,
          'not the passphrase',
        ),
        throwsA(isA<FormatException>()),
      );

      final short = await encodeBackupInBackground(
        _vault(tag: 'SHORT'),
        _passphrase,
        'r60',
      );
      r60('ACTION', 'save-overwrite');
      expect(await service.exportEncrypted(short), VaultExportResult.saved);
      final over = await _pickBack();
      r60(
        'overwrite',
        'wrote=${short.length} read=${over.length} '
            'truncated=${over.length == short.length}',
      );
      expect(over, short, reason: '覆盖后不能留旧文件的尾巴');
      final restored = await decodeBackupInBackground(
        EncryptedVaultFile.tryParse(over)!,
        _passphrase,
      );
      expect(restored.hosts.single.password, 'HOST-SHORT');
      expect(restored.extras.containsKey('knownHosts'), isFalse);

      // 导入：凭据进真的安全存储，重新打开仓库读得回来，普通偏好里搜不到。
      final repository = await VaultRepository.open();
      final plan = planVaultImport(restored, await repository.loadVault());
      await repository.saveVault(plan.result(VaultImportMode.merge));
      final again = await VaultRepository.open();
      final loaded = await again.loadVault();
      expect(loaded.hosts.single.password, 'HOST-SHORT');
      expect((loaded.hosts.single.data['totp'] as Map)['uri'],
          contains('TOTP-SHORT'));
      expect(loaded.keys.single.privateKey, 'PRIVATE-SHORT');
      expect(loaded.keys.single.passphrase, 'KEYPASS-SHORT');
      expect(
        (loaded.extras['identities'] as List).single['password'],
        'IDENTITY-SHORT',
      );
      expect(again.unreadableSecrets, isEmpty);

      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      final plain = preferences
          .getKeys()
          .map((key) => '${preferences.get(key)}')
          .join('\n');
      for (final secret in [
        'HOST-SHORT',
        'TOTP-SHORT',
        'PRIVATE-SHORT',
        'KEYPASS-SHORT',
        'IDENTITY-SHORT',
      ]) {
        expect(plain, isNot(contains(secret)), reason: secret);
      }
      r60('done', true);
    });
  }, timeout: const Timeout(Duration(minutes: 6)));
}
