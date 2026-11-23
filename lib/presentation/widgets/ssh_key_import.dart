import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../domain/security_key.dart';
import '../../domain/ssh_key_type.dart';
import '../../infrastructure/storage/picked_files.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'credential_field.dart' show CredentialFields;
import 'form_gap.dart';
import 'secret_content.dart';

/// 从文件导入一把 SSH 私钥存进保险库，返回它。没选、文件不对、取消都返回 null。
/// 凭据列表和凭据编辑框共用：建凭据的时候不用退出去先导密钥（F31）。
Future<SshKeyProfile?> importSshKey(BuildContext context, WidgetRef ref) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.any,
    withData: true,
  );
  if (result == null) return null;
  final file = result.files.single;
  final List<int> bytes;
  try {
    bytes = file.bytes ?? await File(file.path!).readAsBytes();
  } finally {
    // 选择器在 App 缓存里复制了一份私钥明文，读完就删；用户后面取消导入也不留。
    await discardPickedCopy(file);
  }
  final privateKey = utf8.decode(bytes);
  if (!privateKey.contains('PRIVATE KEY')) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: LText('所选文件不是受支持的私钥')));
    }
    return null;
  }
  final type = sshKeyTypeOf(privateKey);
  final publicKey = SecurityKeyStub.publicKeyLineOf(privateKey);
  final label = TextEditingController(text: file.name);
  final passphrase = TextEditingController();
  if (!context.mounted) return null;
  // 列表只有名字和类型，不防截屏；填口令的这个对话框防（R44）。私钥只从文件读，不在界面上显示。
  final key = await showDialog<SshKeyProfile>(
    context: context,
    builder: (context) => SecretContent(
        child: AlertDialog(
      title: const LText('导入 SSH 私钥'),
      scrollable: true,
      content: CredentialFields(
          inDialog: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('ssh-key-import-label'),
                controller: label,
                decoration: LInputDecoration(labelText: '名称'),
              ),
              const FormGap(),
              TextField(
                key: const ValueKey('ssh-key-import-passphrase'),
                controller: passphrase,
                obscureText: true,
                enableIMEPersonalizedLearning: false,
                enableSuggestions: false,
                autocorrect: false,
                decoration: LInputDecoration(labelText: '口令（可选）'),
              ),
            ],
          )),
      actions: [
        ShunButton(
          key: const ValueKey('ssh-key-import-cancel'),
          kind: ShunButtonKind.text,
          onPressed: () => Navigator.pop(context),
          label: '取消',
        ),
        ShunButton(
          key: const ValueKey('ssh-key-import-confirm'),
          onPressed: () => Navigator.pop(
            context,
            SshKeyProfile({
              'id': const Uuid().v4(),
              'label': label.text.trim(),
              // 认不出就不写，列表里显示「OpenSSH / PEM」；以前一律写 ED25519。
              if (type != null) 'type': type,
              'privateKey': privateKey,
              if (publicKey != null) 'publicKey': publicKey,
              'passphrase': passphrase.text,
              'savePassphrase': true,
              'source': 'imported',
              'category': 'key',
              'created': DateTime.now().millisecondsSinceEpoch,
            }),
          ),
          label: '导入',
        ),
      ],
    )),
  );
  if (key == null) return null;
  final controller = ref.read(vaultControllerProvider.notifier);
  final vault = await controller.ready();
  await controller.replace(vault.copyWith(keys: [...vault.keys, key]));
  return key;
}
