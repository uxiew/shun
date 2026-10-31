import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../domain/security_key.dart';
import '../../infrastructure/ssh/security_key_channel.dart';
import '../localization/localized_widgets.dart';
import 'security_key_prompt.dart';

/// ssh-keygen 默认的 rpId。按它生成，密钥和电脑上 `ssh-keygen -K` 读到的是同一类。
const _application = 'ssh:';

/// 「添加安全密钥」：在钥匙上生成新的，或者读钥匙里已有的。文件导入走原来的「导入 SSH 私钥」，不重复一个入口。
Future<void> addSecurityKey(BuildContext context, WidgetRef ref) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const LText('添加安全密钥'),
      children: [
        SimpleDialogOption(
          key: const ValueKey('security-key-create'),
          onPressed: () => Navigator.pop(context, 'create'),
          child: const LText('在钥匙上生成新密钥'),
        ),
        SimpleDialogOption(
          key: const ValueKey('security-key-read'),
          onPressed: () => Navigator.pop(context, 'read'),
          child: const LText('读取钥匙里已有的密钥'),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  final channel = ref.read(securityKeyChannelProvider);
  try {
    if (choice == 'create') {
      await _create(context, ref, channel);
    } else {
      await _readResident(context, ref, channel);
    }
  } on SecurityKeyException catch (error) {
    if (error.failure == SecurityKeyFailure.cancelled || !context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$error')),
    );
  }
}

class _CreateOptions {
  const _CreateOptions(this.label, this.resident, this.requirePin);

  final String label;
  final bool resident;
  final bool requirePin;
}

Future<void> _create(
  BuildContext context,
  WidgetRef ref,
  SecurityKeyChannel channel,
) async {
  final options = await showDialog<_CreateOptions>(
    context: context,
    builder: (context) => const _CreateDialog(),
  );
  if (options == null || !context.mounted) return;
  final created = await showSecurityKeyPrompt<SecurityKeyCreated>(
    context,
    channel,
    title: '在钥匙上生成密钥',
    pinFirst: options.requirePin,
    run: (pin) => channel.create(
      application: _application,
      resident: options.resident,
      requirePin: options.requirePin,
      pin: pin,
    ),
  );
  final parsed = CoseKey.fromAttestedData(created.attestedData);
  final stub = SecurityKeyStub.fromCredential(
    key: parsed.key,
    application: _application,
    flags: skFlagUserPresence |
        (options.requirePin ? skFlagUserVerification : 0) |
        (options.resident ? skFlagResident : 0),
    keyHandle: parsed.credentialId,
    comment: options.label,
  );
  await _save(ref, [securityKeyProfile(stub, options.label)]);
  if (context.mounted) {
    await showSecurityKeyPublicKey(context, stub.publicKeyLine);
  }
}

Future<void> _readResident(
  BuildContext context,
  WidgetRef ref,
  SecurityKeyChannel channel,
) async {
  final found = await showSecurityKeyPrompt<List<SecurityKeyResident>>(
    context,
    channel,
    title: '读取钥匙里的密钥',
    pinFirst: true,
    run: (pin) => channel.listResident(pin: pin!),
  );
  final vault = await ref.read(vaultControllerProvider.notifier).ready();
  final known = {
    for (final key in vault.keys)
      SecurityKeyStub.publicKeyLineOf(key.privateKey),
  };
  final fresh = <SshKeyProfile>[];
  for (final resident in found) {
    final stub = SecurityKeyStub.fromCredential(
      key: resident.coseKey,
      application: resident.application,
      flags: skFlagUserPresence | skFlagResident,
      keyHandle: resident.credentialId,
    );
    final line = SecurityKeyStub.publicKeyLineOf(stub.toPem());
    if (known.add(line)) {
      final index = vault.keys.length + fresh.length + 1;
      fresh.add(securityKeyProfile(stub, '安全密钥 $index'));
    }
  }
  await _save(ref, fresh);
  if (!context.mounted) return;
  final total = found.length;
  final added = fresh.length;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: LText('找到 $total 把，新增 $added 把')),
  );
}

/// 存进保险库的样子，字段和桌面端一样。句柄文件放在 `privateKey`，和普通私钥走同一条安全存储的路。
SshKeyProfile securityKeyProfile(SecurityKeyStub stub, String label) =>
    SshKeyProfile({
      'id': const Uuid().v4(),
      'label': label,
      'type': securityKeyVaultType(stub.type),
      'privateKey': stub.toPem(),
      'publicKey': stub.publicKeyLine,
      'passphrase': '',
      'savePassphrase': true,
      'source': 'generated',
      'category': 'key',
      'created': DateTime.now().millisecondsSinceEpoch,
    });

Future<void> _save(WidgetRef ref, List<SshKeyProfile> keys) async {
  if (keys.isEmpty) return;
  final controller = ref.read(vaultControllerProvider.notifier);
  final vault = await controller.ready();
  await controller.replace(vault.copyWith(keys: [...vault.keys, ...keys]));
}

/// 把公钥给用户贴到服务器上。公钥本来就是公开的，不防截屏。
Future<void> showSecurityKeyPublicKey(BuildContext context, String line) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('公钥'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LText('把这一行加到服务器的 ~/.ssh/authorized_keys'),
            const SizedBox(height: 8),
            SelectableText(
              line,
              key: const ValueKey('security-key-public-key'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('关闭'),
          ),
          FilledButton(
            key: const ValueKey('security-key-copy-public-key'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: line));
              if (context.mounted) Navigator.pop(context);
            },
            child: const LText('复制'),
          ),
        ],
      ),
    );

class _CreateDialog extends StatefulWidget {
  const _CreateDialog();

  @override
  State<_CreateDialog> createState() => _CreateDialogState();
}

class _CreateDialogState extends State<_CreateDialog> {
  final _label = TextEditingController(text: localized('安全密钥'));
  var _resident = false;
  var _requirePin = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const LText('在钥匙上生成密钥'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('security-key-label'),
              controller: _label,
              decoration: LInputDecoration(labelText: '名称'),
            ),
            SwitchListTile(
              key: const ValueKey('security-key-resident'),
              contentPadding: EdgeInsets.zero,
              title: const LText('存进钥匙里'),
              subtitle: const LText('换手机后能从钥匙读回来'),
              value: _resident,
              onChanged: (value) => setState(() => _resident = value),
            ),
            SwitchListTile(
              key: const ValueKey('security-key-require-pin'),
              contentPadding: EdgeInsets.zero,
              title: const LText('每次登录都要 PIN'),
              value: _requirePin,
              onChanged: (value) => setState(() => _requirePin = value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            key: const ValueKey('security-key-create-confirm'),
            onPressed: () {
              final label = _label.text.trim();
              Navigator.pop(
                context,
                _CreateOptions(
                  label.isEmpty ? localized('安全密钥') : label,
                  _resident,
                  _requirePin,
                ),
              );
            },
            child: const LText('生成'),
          ),
        ],
      );
}
