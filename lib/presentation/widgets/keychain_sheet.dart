import 'package:flutter/material.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/vault_controller.dart';
import '../../domain/connection_route.dart' show proxyIdentityKey;
import '../../domain/credential_identity.dart';
import '../../domain/models/host.dart';
import '../../domain/security_key.dart';
import 'credential_field.dart';
import 'identity_editor.dart';
import 'security_key_actions.dart';
import 'ssh_key_import.dart';

/// 「凭据」（R26 F25，以前叫「SSH 密钥库」）：多台主机共用的登录方式和 SSH 密钥放在一处管。
///
/// 和桌面端 Netcatty 的「钥匙串」同一套数据：凭据在 `identities`，密钥在 `keys`。
/// 主机在编辑器里选一个凭据（`identityId`），连接时用它的用户名和登录方式（[applyHostIdentity]）。
class KeychainSheet extends ConsumerWidget {
  const KeychainSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultControllerProvider).data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    final identities =
        vault == null ? const <IdentityProfile>[] : vaultIdentities(vault);
    final hosts = vault?.hosts ?? const <HostProfile>[];
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
                'identity' => editAndSaveIdentity(context, ref),
                'security-key' => addSecurityKey(context, ref),
                _ => importSshKey(context, ref),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'identity', child: LText('新建凭据')),
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
            _header(context, '登录凭据'),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: LText(
                '多台主机共用一份登录方式，改一次全跟着变。在主机编辑器里选。',
                style: small,
              ),
            ),
            if (identities.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('keychain-new-identity'),
                  onPressed: () => editAndSaveIdentity(context, ref),
                  icon: const Icon(Icons.person_add_alt),
                  label: const LText('新建凭据'),
                ),
              ),
            for (final identity in identities)
              ListTile(
                key: ValueKey('keychain-identity-${identity.id}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: CircleAvatar(
                  child: Icon(credentialIcon(identity, keys)),
                ),
                title: Text(identity.label),
                subtitle: Text(
                  [
                    credentialDetail(identity, keys),
                    if (identityUsageText(hosts, identity) case final usage?)
                      usage,
                  ].join(' · '),
                  style: small,
                ),
                onTap: () =>
                    editAndSaveIdentity(context, ref, existing: identity),
                trailing: IconButton(
                  key: ValueKey('keychain-delete-identity-${identity.id}'),
                  tooltip: localized('删除凭据'),
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
                  onPressed: () => importSshKey(context, ref),
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

  /// 先问再删，写出哪些主机和代理在用；确认后它们的引用一并去掉（[VaultController.deleteIdentity]）。
  Future<void> _deleteIdentity(
    BuildContext context,
    WidgetRef ref,
    IdentityProfile identity,
  ) async {
    final controller = ref.read(vaultControllerProvider.notifier);
    final vault = await controller.ready();
    final hosts = hostsUsingIdentity(vault.hosts, identity);
    final proxies = [
      for (final profile in vault.proxyProfiles)
        if (profile.data[proxyIdentityKey] == identity.id) profile,
    ];
    final users = [
      ...hosts.map((h) => h.label),
      ...proxies.map((p) => p.label)
    ];
    // 先写影响几台再列名字：主机多了名字一长串，数不过来。
    final impact = [
      if (hosts.isNotEmpty)
        localized('{n} 台主机').replaceAll('{n}', '${hosts.length}'),
      if (proxies.isNotEmpty)
        localized('{n} 个代理').replaceAll('{n}', '${proxies.length}'),
    ].join('、');
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: LText('删除凭据“${identity.label}”？'),
            content: LText(users.isEmpty
                ? '没有主机在用它。删了不能撤销。'
                : '$impact在用它：${users.join('、')}。删了以后，主机用自己的用户名、密码连接时问，代理不再带账号密码；删了不能撤销。'),
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
    await controller.deleteIdentity(identity.id);
  }

  /// 先问再删，并写出哪些主机、哪些凭据在用它。以前点一下就删：选了「私钥」的主机从此连不上，
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
      // 引用它的凭据：删了以后用这些凭据的主机在拨号前就报「引用的私钥不存在」。
      for (final identity in vaultIdentities(vault))
        if (identity.keyId == key.id)
          localized('凭据“{name}”').replaceAll('{name}', identity.label),
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
}
