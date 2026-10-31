import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

enum VaultExportResult { saved, cancelled }

typedef SaveVaultFile = Future<String?> Function({
  String? dialogTitle,
  String? fileName,
  FileType type,
  List<String>? allowedExtensions,
  Uint8List? bytes,
});

/// Android 上不用 file_picker 存：它写文件不截断，原因见 DocumentTreeChannel.saveDocument。
Future<String?> _saveDocumentOnAndroid({
  String? dialogTitle,
  String? fileName,
  FileType type = FileType.any,
  List<String>? allowedExtensions,
  Uint8List? bytes,
}) =>
    const MethodChannel('top.xdwa.shun/storage').invokeMethod<String>(
      'saveDocument',
      {'fileName': fileName, 'bytes': bytes},
    );

class VaultExportService {
  VaultExportService({
    SaveVaultFile? saveFile,
    bool? pickerWritesBytes,
  })  : _saveFile = saveFile ??
            (Platform.isAndroid
                ? _saveDocumentOnAndroid
                : FilePicker.platform.saveFile),
        _pickerWritesBytes =
            pickerWritesBytes ?? (Platform.isAndroid || Platform.isIOS);

  final SaveVaultFile _saveFile;
  final bool _pickerWritesBytes;

  /// 存带凭据的加密备份（R60）。[bytes] 是 [EncryptedVaultFile.encode] 算好的密文。
  Future<VaultExportResult> exportEncrypted(Uint8List bytes) => _save(
        bytes,
        dialogTitle: '备份到文件',
        fileName: 'shun-backup-encrypted.json',
      );

  Future<VaultExportResult> _save(
    Uint8List bytes, {
    required String dialogTitle,
    required String fileName,
  }) async {
    final path = await _saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
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
