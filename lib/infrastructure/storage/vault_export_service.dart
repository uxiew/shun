import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../domain/models/vault.dart';
import '../../domain/vault_secrets.dart';

enum VaultExportResult { saved, cancelled }

typedef SaveVaultFile = Future<String?> Function({
  String? dialogTitle,
  String? fileName,
  FileType type,
  List<String>? allowedExtensions,
  Uint8List? bytes,
});

class VaultExportService {
  VaultExportService({
    SaveVaultFile? saveFile,
    bool? pickerWritesBytes,
  })  : _saveFile = saveFile ?? FilePicker.platform.saveFile,
        _pickerWritesBytes =
            pickerWritesBytes ?? (Platform.isAndroid || Platform.isIOS);

  final SaveVaultFile _saveFile;
  final bool _pickerWritesBytes;

  /// 导出保险库，**不含**密码、私钥和代理口令（REG03）。
  ///
  /// 以前导出的是解锁后的完整保险库，JSON 文件里是明文密码和私钥，存到哪、同步到哪都跟着走。
  /// 在同一台设备上再导入时，[keepLocalSecrets] 会沿用本机已有的凭据；换设备要重新填。
  Future<VaultExportResult> export(VaultData vault) async {
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ')
          .convert(vaultWithoutSecrets(vault).toJson())),
    );
    final path = await _saveFile(
      dialogTitle: '导出 shun 保险库',
      fileName: 'shun-export.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      // Android and iOS document pickers own the selected URI. file_picker
      // must receive the payload so its native implementation can write it.
      bytes: _pickerWritesBytes ? bytes : null,
    );
    if (path == null) return VaultExportResult.cancelled;

    // Desktop implementations return a normal filesystem destination and do
    // not write the provided bytes on the application's behalf.
    if (!_pickerWritesBytes) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return VaultExportResult.saved;
  }
}
