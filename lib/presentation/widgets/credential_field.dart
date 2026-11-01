import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/vault_controller.dart';
import '../../domain/credential_identity.dart';
import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import 'identity_editor.dart';
import 'keychain_sheet.dart';

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
    final id = choice == _newCredential
        ? await editAndSaveIdentity(context, ref, passwordOnly: passwordOnly)
        : choice;
    if (id != null) onChanged(id);
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
    final items =
        vault == null ? const <IdentityProfile>[] : vaultIdentities(vault);
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: LText(
              '选择凭据',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final item in items)
            if (!passwordOnly ||
                (item.auth == IdentityAuth.password && item.password != null))
              ListTile(
                key: ValueKey('credential-option-${item.id}'),
                leading: Icon(credentialIcon(item, keys)),
                title: Text(item.label),
                subtitle: Text(credentialDetail(item, keys)),
                trailing: item.id == selected ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, item.id),
              ),
          ListTile(
            key: const ValueKey('credential-new'),
            leading: const Icon(Icons.add),
            title: const LText('新建凭据'),
            onTap: () => Navigator.pop(context, _newCredential),
          ),
          ListTile(
            key: const ValueKey('credential-manage'),
            leading: const Icon(Icons.tune),
            title: const LText('管理凭据'),
            onTap: () => Navigator.pop(context, _manageCredentials),
          ),
        ],
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
