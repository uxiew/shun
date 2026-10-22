import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../domain/ssh_key_type.dart';
import 'secret_content.dart';

class KeychainSheet extends ConsumerWidget {
  const KeychainSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultControllerProvider).data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
          title: const LText('SSH 密钥'),
          actions: [
            IconButton(
              tooltip: localized('导入私钥'),
              onPressed: () => _import(context, ref),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        body: keys.isEmpty
            ? Center(
                child: FilledButton.icon(
                  onPressed: () => _import(context, ref),
                  icon: const Icon(Icons.key),
                  label: const LText('导入私钥'),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: keys.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, index) {
                  final key = keys[index];
                  return ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.key)),
                    title: LText(key.label),
                    subtitle: LText(
                      key.data['type']?.toString() ?? 'OpenSSH / PEM',
                    ),
                    trailing: IconButton(
                      key: ValueKey('keychain-delete-${key.id}'),
                      tooltip: localized('删除私钥'),
                      onPressed: () => _delete(context, ref, key),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  );
                },
              ),
      ),
    );
  }

  /// 先问再删，并写出哪些主机在用它。以前点一下就删：选了「私钥」的主机从此连不上，
  /// 下次打开编辑器时旧引用又被悄悄清掉，用户不知道发生了什么。
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    SshKeyProfile key,
  ) async {
    final controller = ref.read(vaultControllerProvider.notifier);
    final vault = await controller.ready();
    final users = vault.hosts
        .where((host) => host.identityFileId == key.id)
        .map((host) => host.label)
        .toList();
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: LText('删除私钥“${key.label}”？'),
            content: LText(users.isEmpty
                ? '没有主机在用它。删了不能撤销。'
                : '这些主机在用它：${users.join('、')}。删了以后，其中认证方式选「私钥」的会连不上，要到编辑器里重新选一把；删了不能撤销。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                key: const ValueKey('keychain-confirm-delete'),
                onPressed: () => Navigator.pop(context, true),
                child: const LText('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final current = await controller.ready();
    await controller.replace(
      current.copyWith(
        keys: current.keys.where((value) => value.id != key.id).toList(),
      ),
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null) return;
    final file = result.files.single;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    final privateKey = utf8.decode(bytes);
    if (!privateKey.contains('PRIVATE KEY')) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: LText('所选文件不是受支持的私钥')));
      }
      return;
    }
    final type = sshKeyTypeOf(privateKey);
    final label = TextEditingController(text: file.name);
    final passphrase = TextEditingController();
    if (!context.mounted) return;
    // 列表只有名字和类型，不防截屏；填口令的这个对话框防（R44）。私钥只从文件读，不在界面上显示。
    final key = await showDialog<SshKeyProfile>(
      context: context,
      builder: (context) => SecretContent(
          child: AlertDialog(
        title: const LText('导入 SSH 私钥'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: label,
              decoration: LInputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passphrase,
              obscureText: true,
              enableIMEPersonalizedLearning: false,
              enableSuggestions: false,
              autocorrect: false,
              decoration: LInputDecoration(labelText: '口令（可选）'),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              SshKeyProfile({
                'id': const Uuid().v4(),
                'label': label.text.trim(),
                // 认不出就不写，列表里显示「OpenSSH / PEM」；以前一律写 ED25519。
                if (type != null) 'type': type,
                'privateKey': privateKey,
                'passphrase': passphrase.text,
                'savePassphrase': true,
                'source': 'imported',
                'category': 'key',
                'created': DateTime.now().millisecondsSinceEpoch,
              }),
            ),
            child: const LText('导入'),
          ),
        ],
      )),
    );
    if (key != null) {
      final controller = ref.read(vaultControllerProvider.notifier);
      final vault = await controller.ready();
      await controller.replace(vault.copyWith(keys: [...vault.keys, key]));
    }
  }
}
