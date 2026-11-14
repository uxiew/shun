import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../domain/security_key.dart';
import '../../infrastructure/ssh/security_key_channel.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'no_intrinsics.dart';
import 'security_key_prompt.dart';

/// ssh-keygen 默认的 rpId。按它生成，密钥和电脑上 `ssh-keygen -K` 读到的是同一类。
const _application = 'ssh:';

/// 「添加安全密钥」：在钥匙上生成新的，或者读钥匙里已有的。文件导入走原来的「导入 SSH 私钥」，不重复一个入口。
/// 返回这次新存的几把：凭据编辑框要把刚加的选上（F31）。
Future<List<SshKeyProfile>> addSecurityKey(
  BuildContext context,
  WidgetRef ref,
) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const LText('添加安全密钥'),
      // 两个选项是 Prism 分组里的按钮行：读屏念「按钮」，不再是只有「可点」的裸文字。
      // 无标题的分组只画间距，不需要测量宿主。
      children: [
        NoIntrinsics(
          child: ShunSection(
            children: [
              ShunListRow(
                key: const ValueKey('security-key-create'),
                title: '在钥匙上生成新密钥',
                onTap: () => Navigator.pop(context, 'create'),
              ),
              ShunListRow(
                key: const ValueKey('security-key-read'),
                title: '读取钥匙里已有的密钥',
                onTap: () => Navigator.pop(context, 'read'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return const [];
  final channel = ref.read(securityKeyChannelProvider);
  try {
    return choice == 'create'
        ? await _create(context, ref, channel)
        : await _readResident(context, ref, channel);
  } on SecurityKeyException catch (error) {
    if (error.failure == SecurityKeyFailure.cancelled || !context.mounted) {
      return const [];
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$error')),
    );
    return const [];
  }
}

class _CreateOptions {
  const _CreateOptions(this.label, this.resident, this.requirePin);

  final String label;
  final bool resident;
  final bool requirePin;
}

Future<List<SshKeyProfile>> _create(
  BuildContext context,
  WidgetRef ref,
  SecurityKeyChannel channel,
) async {
  final options = await showDialog<_CreateOptions>(
    context: context,
    builder: (context) => const _CreateDialog(),
  );
  if (options == null || !context.mounted) return const [];
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
  final saved = [securityKeyProfile(stub, options.label)];
  await _save(ref, saved);
  if (context.mounted) {
    await showSecurityKeyPublicKey(context, stub.publicKeyLine);
  }
  return saved;
}

Future<List<SshKeyProfile>> _readResident(
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
  if (!context.mounted) return fresh;
  final total = found.length;
  final added = fresh.length;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: LText('找到 $total 把，新增 $added 把')),
  );
  return fresh;
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
          ShunButton(
            key: const ValueKey('security-key-close-public-key'),
            kind: ShunButtonKind.text,
            onPressed: () => Navigator.pop(context),
            label: '关闭',
          ),
          ShunButton(
            key: const ValueKey('security-key-copy-public-key'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: line));
              if (context.mounted) Navigator.pop(context);
            },
            label: '复制',
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
            NoIntrinsics(
              child: ShunSection(
                children: [
                  ShunSwitchRow(
                    key: const ValueKey('security-key-resident'),
                    title: '存进钥匙里',
                    subtitle: '换手机后能从钥匙读回来',
                    value: _resident,
                    onChanged: (value) => setState(() => _resident = value),
                  ),
                  ShunSwitchRow(
                    key: const ValueKey('security-key-require-pin'),
                    title: '每次登录都要 PIN',
                    value: _requirePin,
                    onChanged: (value) => setState(() => _requirePin = value),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          ShunButton(
            key: const ValueKey('security-key-create-cancel'),
            kind: ShunButtonKind.text,
            onPressed: () => Navigator.pop(context),
            label: '取消',
          ),
          ShunButton(
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
            label: '生成',
          ),
        ],
      );
}
