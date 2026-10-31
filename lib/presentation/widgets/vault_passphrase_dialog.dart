import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../domain/models/vault.dart';
import '../../infrastructure/storage/encrypted_vault_file.dart';
import '../../infrastructure/sync/vault_crypto.dart';
import '../localization/localized_widgets.dart';
import 'form_gap.dart';
import 'secret_content.dart';

typedef BackupEncoder = Future<Uint8List> Function(
  VaultData vault,
  String passphrase,
  String appVersion,
);
typedef BackupDecoder = Future<VaultData> Function(
  SyncedVaultFile file,
  String passphrase,
);

Future<Uint8List> _encode(
  VaultData vault,
  String passphrase,
  String appVersion,
) =>
    EncryptedVaultFile.encode(
      vault: vault,
      passphrase: passphrase,
      appVersion: appVersion,
    );

/// 问口令、加密。返回 null 表示取消。
Future<Uint8List?> askAndEncodeBackup(
  BuildContext context,
  VaultData vault,
  String appVersion, {
  BackupEncoder encode = _encode,
}) async {
  final passphrase = await askNewBackupPassphrase(context);
  if (passphrase == null || !context.mounted) return null;
  return _whileWorking(context, encode(vault, passphrase, appVersion));
}

/// 问口令、解密，错了在框里说原因再问，直到对了或者取消（返回 null）。
///
/// 派生次数不对是文件的问题，换口令也没用，直接抛给调用方。
Future<VaultData?> askAndDecodeBackup(
  BuildContext context,
  SyncedVaultFile file, {
  BackupDecoder decode = EncryptedVaultFile.decrypt,
}) async {
  String? problem;
  while (context.mounted) {
    final passphrase = await askBackupPassphrase(context, problem: problem);
    if (passphrase == null || !context.mounted) return null;
    try {
      return await _whileWorking(context, decode(file, passphrase));
    } on FormatException catch (error) {
      if (error.message == EncryptedVaultFile.iterationsRejected) rethrow;
      problem = error.message;
    }
  }
  return null;
}

Future<T> _whileWorking<T>(BuildContext context, Future<T> work) async {
  final navigator = Navigator.of(context);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Expanded(child: LText('正在计算…')),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    return await work;
  } finally {
    navigator.pop();
  }
}

/// 备份到文件前定口令：输两遍，短了不让过。返回 null 表示取消。口令不存。
Future<String?> askNewBackupPassphrase(BuildContext context) =>
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _NewPassphraseDialog(),
    );

/// 从文件恢复时问口令。[problem] 是上一次为什么没成功。返回 null 表示取消。
Future<String?> askBackupPassphrase(BuildContext context, {String? problem}) =>
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PassphraseDialog(problem: problem),
    );

InputDecoration _decoration(String label, {String? error}) =>
    LInputDecoration(labelText: label, errorText: error);

class _NewPassphraseDialog extends StatefulWidget {
  const _NewPassphraseDialog();

  @override
  State<_NewPassphraseDialog> createState() => _NewPassphraseDialogState();
}

class _NewPassphraseDialogState extends State<_NewPassphraseDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final String? problem;
    if (_first.text.length < EncryptedVaultFile.minPassphraseLength) {
      problem = EncryptedVaultFile.passphraseTooShort;
    } else if (_first.text != _second.text) {
      problem = '两次输入不一样';
    } else {
      problem = null;
    }
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.pop(context, _first.text);
  }

  @override
  Widget build(BuildContext context) => SecretContent(
        child: AlertDialog(
          title: const LText('备份口令'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LText('备份里有密码和私钥，靠这个口令保护。忘了就解不开，App 不存它。'),
              const FormGap(),
              TextField(
                key: const ValueKey('backup-passphrase'),
                controller: _first,
                autofocus: true,
                obscureText: true,
                enableIMEPersonalizedLearning: false,
                enableSuggestions: false,
                autocorrect: false,
                decoration: _decoration('口令'),
              ),
              const FormGap(),
              TextField(
                key: const ValueKey('backup-passphrase-again'),
                controller: _second,
                obscureText: true,
                enableIMEPersonalizedLearning: false,
                enableSuggestions: false,
                autocorrect: false,
                onSubmitted: (_) => _submit(),
                decoration: _decoration('再输一遍', error: _problem),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const LText('取消'),
            ),
            FilledButton(
              key: const ValueKey('backup-passphrase-confirm'),
              onPressed: _submit,
              child: const LText('备份'),
            ),
          ],
        ),
      );
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({this.problem});

  final String? problem;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _passphrase = TextEditingController();

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  void _submit() {
    if (_passphrase.text.isEmpty) return;
    Navigator.pop(context, _passphrase.text);
  }

  @override
  Widget build(BuildContext context) => SecretContent(
        child: AlertDialog(
          title: const LText('备份口令'),
          content: TextField(
            key: const ValueKey('backup-passphrase'),
            controller: _passphrase,
            autofocus: true,
            obscureText: true,
            enableIMEPersonalizedLearning: false,
            enableSuggestions: false,
            autocorrect: false,
            onSubmitted: (_) => _submit(),
            decoration: _decoration('口令', error: widget.problem),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const LText('取消'),
            ),
            FilledButton(
              key: const ValueKey('backup-passphrase-confirm'),
              onPressed: _submit,
              child: const LText('解密'),
            ),
          ],
        ),
      );
}
