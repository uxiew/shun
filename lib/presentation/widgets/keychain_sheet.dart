import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/credential_identity.dart';
import '../../domain/models/host.dart';
import '../../domain/security_key.dart';
import '../../domain/ssh_key_type.dart';
import '../../domain/vault_secrets.dart';
import '../../infrastructure/storage/picked_files.dart';
import 'form_gap.dart';
import 'identity_editor.dart';
import 'secret_content.dart';
import 'security_key_actions.dart';

/// 「凭据」（R26 F25，以前叫「SSH 密钥库」）：登录身份和 SSH 密钥放在一处管。
///
/// 和桌面端 Netcatty 的「钥匙串」同一套数据：身份在 `identities`，密钥在 `keys`。
/// 主机在编辑器里选一个身份（`identityId`），连接时用它的用户名和登录方式（[applyHostIdentity]）。
class KeychainSheet extends ConsumerWidget {
  const KeychainSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultControllerProvider).data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    final identities =
        vault == null ? const <IdentityProfile>[] : vaultIdentities(vault);
    final hosts = vault?.hosts ?? const <HostProfile>[];
    final keyLabels = {for (final key in keys) key.id: key.label};
    final small = Theme.of(context).textTheme.bodySmall;
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
          title: const LText('凭据'),
          actions: [
            PopupMenuButton<String>(
              key: const ValueKey('keychain-add'),
              tooltip: localized('添加'),
              icon: const Icon(Icons.add),
              onSelected: (value) => switch (value) {
                'identity' => _editIdentity(context, ref, null),
                'security-key' => addSecurityKey(context, ref),
                _ => _import(context, ref),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'identity', child: LText('新建登录身份')),
                PopupMenuItem(value: 'key', child: LText('导入 SSH 私钥')),
                PopupMenuItem(
                  value: 'security-key',
                  child: LText('添加安全密钥'),
                ),
              ],
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          children: [
            _header(context, '登录身份'),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: LText(
                '用户名 + 登录方式，多台主机共用一份：改一次密码，所有用它的主机都跟着变。在主机编辑器的「认证」里选。',
                style: small,
              ),
            ),
            if (identities.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('keychain-new-identity'),
                  onPressed: () => _editIdentity(context, ref, null),
                  icon: const Icon(Icons.person_add_alt),
                  label: const LText('新建登录身份'),
                ),
              ),
            for (final identity in identities)
              ListTile(
                key: ValueKey('keychain-identity-${identity.id}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: CircleAvatar(
                  child: Icon(switch (identity.auth) {
                    IdentityAuth.password => Icons.password,
                    IdentityAuth.key => Icons.key,
                    IdentityAuth.keyAndPassword => Icons.enhanced_encryption,
                  }),
                ),
                title: Text(identity.label),
                subtitle: Text(
                  [
                    identity.username,
                    localized(identityAuthText(identity, keyLabels)),
                    if (_hostsUsing(hosts, identity).isNotEmpty)
                      localized('{n} 台主机在用').replaceAll(
                          '{n}', '${_hostsUsing(hosts, identity).length}'),
                  ].join(' · '),
                  style: small,
                ),
                onTap: () => _editIdentity(context, ref, identity),
                trailing: IconButton(
                  key: ValueKey('keychain-delete-identity-${identity.id}'),
                  tooltip: localized('删除登录身份'),
                  onPressed: () => _deleteIdentity(context, ref, identity),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            const SizedBox(height: 12),
            _header(context, 'SSH 密钥'),
            if (keys.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _import(context, ref),
                  icon: const Icon(Icons.key),
                  label: const LText('导入私钥'),
                ),
              ),
            for (final key in keys)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: const CircleAvatar(child: Icon(Icons.key)),
                title: LText(key.label),
                subtitle: LText(
                  key.data['type']?.toString() ?? 'OpenSSH / PEM',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (SecurityKeyStub.publicKeyLineOf(key.privateKey)
                        case final line?)
                      IconButton(
                        key: ValueKey('keychain-public-key-${key.id}'),
                        tooltip: localized('公钥'),
                        onPressed: () =>
                            showSecurityKeyPublicKey(context, line),
                        icon: const Icon(Icons.content_copy_outlined),
                      ),
                    IconButton(
                      key: ValueKey('keychain-delete-${key.id}'),
                      tooltip: localized('删除私钥'),
                      onPressed: () => _delete(context, ref, key),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: LText(
          text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );

  static List<HostProfile> _hostsUsing(
    List<HostProfile> hosts,
    IdentityProfile identity,
  ) =>
      hosts.where((host) => host.data['identityId'] == identity.id).toList();

  Future<void> _editIdentity(
    BuildContext context,
    WidgetRef ref,
    IdentityProfile? existing,
  ) async {
    final controller = ref.read(vaultControllerProvider.notifier);
    final vault = await controller.ready();
    if (!context.mounted) return;
    final data =
        await editIdentity(context, existing: existing, keys: vault.keys);
    if (data == null) return;
    final current = await controller.ready();
    final list = [
      for (final item in vaultIdentityMaps(current))
        if (item['id'] != data['id']) item,
    ];
    // 编辑的留在原位置，新建的接在最后。
    final index = vaultIdentityMaps(current)
        .indexWhere((item) => item['id'] == data['id']);
    list.insert(index < 0 ? list.length : index, data);
    await controller.replace(
      current.copyWith(extras: {...current.extras, 'identities': list}),
    );
  }

  /// 先问再删，写出哪些主机在用。确认后这些主机的引用一并去掉，改回用它们自己的用户名和认证设置；
  /// 不去掉的话编辑器里会挂着一个找不到的身份。
  Future<void> _deleteIdentity(
    BuildContext context,
    WidgetRef ref,
    IdentityProfile identity,
  ) async {
    final controller = ref.read(vaultControllerProvider.notifier);
    final vault = await controller.ready();
    final users = _hostsUsing(vault.hosts, identity).map((h) => h.label);
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: LText('删除登录身份“${identity.label}”？'),
            content: LText(users.isEmpty
                ? '没有主机在用它。删了不能撤销。'
                : '这些主机在用它：${users.join('、')}。删了以后它们改回用自己的用户名和认证设置；删了不能撤销。'),
            actions: [
              FilledButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              TextButton(
                key: const ValueKey('keychain-confirm-delete-identity'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
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
        hosts: [
          for (final host in current.hosts)
            if (host.data['identityId'] == identity.id)
              HostProfile(
                  Map<String, dynamic>.from(host.data)..remove('identityId'))
            else
              host,
        ],
        extras: {
          ...current.extras,
          'identities': [
            for (final item in vaultIdentityMaps(current))
              if (item['id'] != identity.id) item,
          ],
        },
      ),
    );
  }

  /// 先问再删，并写出哪些主机、哪些登录身份在用它。以前点一下就删：选了「私钥」的主机从此连不上，
  /// 下次打开编辑器时旧引用又被悄悄清掉，用户不知道发生了什么。
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    SshKeyProfile key,
  ) async {
    final controller = ref.read(vaultControllerProvider.notifier);
    final vault = await controller.ready();
    final users = [
      ...vault.hosts
          .where((host) => host.identityFileId == key.id)
          .map((host) => host.label),
      // 引用它的身份：删了以后用这些身份的主机在拨号前就报「引用的私钥不存在」。
      for (final identity in vaultIdentities(vault))
        if (identity.keyId == key.id)
          localized('登录身份“{name}”').replaceAll('{name}', identity.label),
    ];
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: LText('删除私钥“${key.label}”？'),
            content: LText(users.isEmpty
                ? '没有主机在用它。删了不能撤销。'
                : '这些在用它：${users.join('、')}。删了以后，其中用私钥登录的会连不上，要重新选一把；删了不能撤销。'),
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
      return;
    }
    final type = sshKeyTypeOf(privateKey);
    final publicKey = SecurityKeyStub.publicKeyLineOf(privateKey);
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
            const FormGap(),
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
                if (publicKey != null) 'publicKey': publicKey,
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
