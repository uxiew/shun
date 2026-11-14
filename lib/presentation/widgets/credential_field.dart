import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/vault_controller.dart';
import '../../domain/credential_identity.dart';
import '../../domain/models/host.dart';
import '../../domain/security_key.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'identity_editor.dart';
import 'keychain_sheet.dart';
import 'security_key_actions.dart';
import 'ssh_key_import.dart';

/// 一个连接怎么登录（F31）：直接填用户名和密码，或者用「凭据」里的一个。
enum LoginChoice { simple, credential, tailscale }

/// 「认证方式」下拉框，主机编辑器、首次登录、Tailscale 设置、代理共用。
class LoginChoiceField extends StatelessWidget {
  const LoginChoiceField({
    super.key,
    required this.value,
    required this.onChanged,
    this.withTailscale = false,
  });

  final LoginChoice value;
  final ValueChanged<LoginChoice> onChanged;
  final bool withTailscale;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
        // initialValue 只认第一次。「存为凭据」会从外面改选中项，换 key 才跟得上。
        key: ValueKey(value),
        child: DropdownButtonFormField<LoginChoice>(
          initialValue: value,
          isExpanded: true,
          decoration: LInputDecoration(labelText: '认证方式'),
          items: [
            const DropdownMenuItem(
              value: LoginChoice.simple,
              child: LText('用户名 / 密码'),
            ),
            const DropdownMenuItem(
              value: LoginChoice.credential,
              child: LText('凭据'),
            ),
            if (withTailscale)
              const DropdownMenuItem(
                value: LoginChoice.tailscale,
                child: LText('Tailscale SSH'),
              ),
          ],
          onChanged: (choice) {
            if (choice != null) onChanged(choice);
          },
        ),
      );
}

/// 在用这个凭据的主机。选凭据的列表、凭据页、删除前的确认都按这个数。
List<HostProfile> hostsUsingIdentity(
  List<HostProfile> hosts,
  IdentityProfile identity,
) =>
    hosts.where((host) => host.data['identityId'] == identity.id).toList();

/// 「3 台主机在用」，没人用是 null。
String? identityUsageText(List<HostProfile> hosts, IdentityProfile identity) {
  final count = hostsUsingIdentity(hosts, identity).length;
  return count == 0 ? null : localized('{n} 台主机在用').replaceAll('{n}', '$count');
}

/// 凭据的用户名和登录方式，一行。
String credentialDetail(IdentityProfile identity, List<SshKeyProfile> keys) => [
      if (identity.username.isNotEmpty) identity.username,
      localized(identityAuthText(identity, keys)),
    ].join(' · ');

IconData credentialIcon(IdentityProfile identity, List<SshKeyProfile> keys) {
  if (identityUsesSecurityKey(identity, keys)) return Icons.usb;
  return switch (identity.auth) {
    IdentityAuth.password => Icons.password,
    IdentityAuth.key => Icons.key,
    IdentityAuth.keyAndPassword => Icons.enhanced_encryption,
  };
}

const _newCredential = '__new__';
const _manageCredentials = '__manage__';

/// 选「凭据」里的一个：点开列出全部，没有合适的能当场新建；选完显示名称、用户名和方式。
class CredentialField extends ConsumerWidget {
  const CredentialField({
    super.key,
    required this.value,
    required this.onChanged,
    this.errorText,
    this.passwordOnly = false,
  });

  final String? value;
  final ValueChanged<String> onChanged;
  final String? errorText;

  /// 代理只认用户名和存好的密码：只列这种，新建也只能建这种。
  final bool passwordOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultControllerProvider).data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    final selected = vault == null
        ? null
        : vaultIdentities(vault).where((item) => item.id == value).firstOrNull;
    // 一个都没有：下拉里也只有「新建」，不如直接摆按钮，少点一下。
    if (vault != null &&
        !vaultIdentities(vault).any((item) => _listed(item))) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShunButton(
            key: const ValueKey('credential-new-direct'),
            label: '新建凭据',
            icon: Icons.add,
            kind: ShunButtonKind.outlined,
            onPressed: () => _create(context, ref),
          ),
          if (errorText case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: LText(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      );
    }
    return InkWell(
      onTap: () => _pick(context, ref),
      child: InputDecorator(
        isEmpty: selected == null,
        decoration: LInputDecoration(
          labelText: '凭据',
          errorText: errorText,
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: selected == null
            ? null
            : Column(
                key: const ValueKey('credential-summary'),
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    selected.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    credentialDetail(selected, keys),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
      ),
    );
  }

  bool _listed(IdentityProfile item) =>
      !passwordOnly ||
      (item.auth == IdentityAuth.password && item.password != null);

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final id =
        await editAndSaveIdentity(context, ref, passwordOnly: passwordOnly);
    if (id != null) onChanged(id);
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _CredentialSheet(
        selected: value,
        passwordOnly: passwordOnly,
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == _manageCredentials) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const KeychainSheet(),
      );
      return;
    }
    if (choice == _newCredential) {
      await _create(context, ref);
    } else {
      onChanged(choice);
    }
  }
}

class _CredentialSheet extends ConsumerWidget {
  const _CredentialSheet({required this.selected, required this.passwordOnly});

  final String? selected;
  final bool passwordOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultControllerProvider).data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    final hosts = vault?.hosts ?? const <HostProfile>[];
    final items =
        vault == null ? const <IdentityProfile>[] : vaultIdentities(vault);
    // R88：分组卡片，当前那项打勾、读屏报「已选中」。
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: ShunSection(
          title: '选择凭据',
          children: [
            for (final item in items)
              if (!passwordOnly ||
                  (item.auth == IdentityAuth.password && item.password != null))
                ShunListRow(
                  key: ValueKey('credential-option-${item.id}'),
                  leading: Icon(credentialIcon(item, keys)),
                  title: item.label,
                  subtitle: [
                    credentialDetail(item, keys),
                    if (identityUsageText(hosts, item) case final usage?) usage,
                  ].join(' · '),
                  selected: item.id == selected,
                  onTap: () => Navigator.pop(context, item.id),
                ),
            ShunListRow(
              key: const ValueKey('credential-new'),
              leading: const Icon(Icons.add),
              title: '新建凭据',
              onTap: () => Navigator.pop(context, _newCredential),
            ),
            ShunListRow(
              key: const ValueKey('credential-manage'),
              leading: const Icon(Icons.tune),
              title: '管理凭据',
              chevron: true,
              onTap: () => Navigator.pop(context, _manageCredentials),
            ),
          ],
        ),
      ),
    );
  }
}

/// 连接自带的私钥（凭据出现之前选的）：照常能用，不迁移，给一个「不用了」（F31）。
class OwnKeyRow extends StatelessWidget {
  const OwnKeyRow({super.key, required this.sshKey, required this.onDrop});

  final SshKeyProfile sshKey;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Icon(Icons.key_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: LText(
              '私钥“${sshKey.label}”',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            key: const ValueKey('own-key-drop'),
            onPressed: onDrop,
            child: const LText('不用了'),
          ),
        ],
      );
}

const _importKey = '__import__';
const _addSecurityKey = '__security__';

/// 选这台用哪把密钥：列出已有的，没有合适的当场导入，不用退出表单。
class SshKeyField extends ConsumerWidget {
  const SshKeyField({
    super.key,
    required this.value,
    required this.onChanged,
    this.errorText,
  });

  final String? value;
  final ValueChanged<String> onChanged;
  final String? errorText;

  static String _detail(SshKeyProfile key) =>
      SecurityKeyStub.isStubPem(key.privateKey)
          ? localized('安全密钥')
          : key.data['type']?.toString() ?? 'OpenSSH / PEM';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(vaultControllerProvider).data?.keys ??
        const <SshKeyProfile>[];
    final selected = keys.where((key) => key.id == value).firstOrNull;
    return InkWell(
      onTap: () => _pick(context, ref, keys),
      child: InputDecorator(
        isEmpty: selected == null,
        decoration: LInputDecoration(
          labelText: '密钥',
          errorText: errorText,
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: selected == null
            ? null
            : Column(
                key: const ValueKey('ssh-key-summary'),
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    selected.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _detail(selected),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    List<SshKeyProfile> keys,
  ) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      // R88：分组卡片，当前那把打勾、读屏报「已选中」。
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: ShunSection(
          children: [
            for (final key in keys)
              ShunListRow(
                key: ValueKey('ssh-key-option-${key.id}'),
                leading: Icon(
                  SecurityKeyStub.isStubPem(key.privateKey)
                      ? Icons.usb
                      : Icons.key,
                ),
                title: key.label,
                subtitle: _detail(key),
                selected: key.id == value,
                onTap: () => Navigator.pop(context, key.id),
              ),
            ShunListRow(
              key: const ValueKey('ssh-key-import'),
              leading: const Icon(Icons.file_open_outlined),
              title: '导入 SSH 私钥',
              onTap: () => Navigator.pop(context, _importKey),
            ),
            ShunListRow(
              key: const ValueKey('ssh-key-add-security'),
              leading: const Icon(Icons.usb),
              title: '添加安全密钥',
              onTap: () => Navigator.pop(context, _addSecurityKey),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == _importKey) {
      final added = await importSshKey(context, ref);
      if (added != null) onChanged(added.id);
    } else if (choice == _addSecurityKey) {
      final added = await addSecurityKey(context, ref);
      if (added.isNotEmpty) onChanged(added.first.id);
    } else {
      onChanged(choice);
    }
  }
}
