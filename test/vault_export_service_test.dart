import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/storage/vault_export_service.dart';

void main() {
  final cipher = Uint8List.fromList([1, 2, 3]);

  test('手机上把密文交给文档选择器，文件名写明是加密备份', () async {
    Uint8List? savedBytes;
    FileType? savedType;
    List<String>? savedExtensions;
    String? savedName;
    final service = VaultExportService(
      pickerWritesBytes: true,
      saveFile: ({
        dialogTitle,
        fileName,
        type = FileType.any,
        allowedExtensions,
        bytes,
      }) async {
        savedBytes = bytes;
        savedType = type;
        savedExtensions = allowedExtensions;
        savedName = fileName;
        return '/document/shun-backup-encrypted.json';
      },
    );

    expect(await service.exportEncrypted(cipher), VaultExportResult.saved);
    expect(savedType, FileType.custom);
    expect(savedExtensions, ['json']);
    expect(savedName, 'shun-backup-encrypted.json');
    expect(savedBytes, cipher);
  });

  test('桌面上选择器只给路径，文件自己写', () async {
    final directory = await Directory.systemTemp.createTemp('vault-export-');
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/backup.json');
    Uint8List? pickerBytes;
    final service = VaultExportService(
      pickerWritesBytes: false,
      saveFile: ({
        dialogTitle,
        fileName,
        type = FileType.any,
        allowedExtensions,
        bytes,
      }) async {
        pickerBytes = bytes;
        return destination.path;
      },
    );

    expect(await service.exportEncrypted(cipher), VaultExportResult.saved);
    expect(pickerBytes, isNull);
    expect(await destination.readAsBytes(), cipher);
  });

  test('选择器里取消：不算成功', () async {
    final service = VaultExportService(
      pickerWritesBytes: true,
      saveFile: ({
        dialogTitle,
        fileName,
        type = FileType.any,
        allowedExtensions,
        bytes,
      }) async =>
          null,
    );

    expect(
      await service.exportEncrypted(cipher),
      VaultExportResult.cancelled,
    );
  });
}
