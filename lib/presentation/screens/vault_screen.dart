import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/session_controller.dart';
import '../../application/settings_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../domain/plugins/plugin_host.dart';
import '../../domain/tailscale_ssh.dart';
import '../../application/home_navigation.dart';
import '../widgets/empty_state.dart';
import '../widgets/host_address_line.dart';
import '../widgets/host_editor.dart';
import '../widgets/connection_prompts.dart';
import '../widgets/host_system_icon.dart';
import 'rustdesk_screen.dart';
import 'uuremote_screen.dart';

class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  final _search = TextEditingController();
  String? _group;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultControllerProvider);
    final settings = ref.watch(settingsControllerProvider);
    final viewMode = settings.serverViewMode;
    final vault = state.data;
    final groups = vault?.customGroups ?? const <String>[];
    final selectedGroup = groups.contains(_group) ? _group : null;
    if (_group != null && selectedGroup == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _group != null && !groups.contains(_group)) {
          setState(() => _group = null);
        }
      });
    }
    final hosts = (vault?.hosts ?? const <HostProfile>[]).where((host) {
      final query = _search.text.toLowerCase();
      final matchesQuery = query.isEmpty ||
          host.label.toLowerCase().contains(query) ||
          host.hostname.toLowerCase().contains(query) ||
          host.tags.any((tag) => tag.toLowerCase().contains(query));
      return matchesQuery &&
          (selectedGroup == null || host.group == selectedGroup);
    }).toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
            child: Row(
              children: [
                Icon(Icons.pets, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                LText(
                  'Netcatty',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  tooltip: localized('服务器视图'),
                  initialValue: viewMode,
                  onSelected: (value) => ref
                      .read(settingsControllerProvider.notifier)
                      .update(settings.copyWith(serverViewMode: value)),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'grid',
                      child: ListTile(
                        leading: Icon(Icons.grid_view_outlined),
                        title: LText('网格视图'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'list',
                      child: ListTile(
                        leading: Icon(Icons.view_list_outlined),
                        title: LText('列表视图'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'tree',
                      child: ListTile(
                        leading: Icon(Icons.account_tree_outlined),
                        title: LText('树形视图'),
                      ),
                    ),
                  ],
                  icon: Icon(switch (viewMode) {
                    'list' => Icons.view_list_outlined,
                    'tree' => Icons.account_tree_outlined,
                    _ => Icons.grid_view_outlined,
                  }),
                ),
                IconButton(
                  tooltip: localized('添加主机'),
                  onPressed: () => _editHost(),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: LInputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索主机、地址或标签',
                isDense: true,
              ),
            ),
          ),
          if (state.unreadableSecrets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Card(
                key: const ValueKey('vault-unreadable-secrets'),
                margin: EdgeInsets.zero,
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: Icon(
                    Icons.key_off_outlined,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  title: LText(
                    '保存的凭据中有 ${state.unreadableSecrets.length} 条无法解密',
                  ),
                  subtitle: const LText(
                    '设备密钥可能已失效，或数据被改动过。主机配置都还在；用到这些凭据的连接会被拒绝，'
                    '在编辑器里重新填写对应的密码或私钥即可恢复。',
                  ),
                ),
              ),
            ),
          if (groups.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                scrollDirection: Axis.horizontal,
                children: [
                  _VaultGroupChip(
                    key: const ValueKey('vault-group-chip-all'),
                    label: '全部',
                    selected: selectedGroup == null,
                    onSelected: () => setState(() => _group = null),
                  ),
                  const SizedBox(width: 8),
                  for (final group in groups) ...[
                    _VaultGroupChip(
                      key: ValueKey('vault-group-chip-$group'),
                      label: group,
                      selected: selectedGroup == group,
                      onSelected: () => setState(() => _group = group),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          Expanded(
            child: state.loading && vault == null
                ? const Center(child: CircularProgressIndicator())
                : hosts.isEmpty
                    ? EmptyState(
                        icon: Icons.dns_outlined,
                        title: '还没有服务器',
                        subtitle: '添加 SSH 或 Telnet 连接，云同步后也会出现在这里。',
                        action: FilledButton.icon(
                          onPressed: () => _editHost(),
                          icon: const Icon(Icons.add),
                          label: const LText('添加主机'),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () =>
                            ref.read(vaultControllerProvider.notifier).load(),
                        child: switch (viewMode) {
                          'grid' => GridView.builder(
                              padding: const EdgeInsets.all(12),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 230,
                                mainAxisExtent: 148,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                              ),
                              itemCount: hosts.length,
                              itemBuilder: (_, index) => _HostCard(
                                host: hosts[index],
                                onConnect: () => _showHostDetails(hosts[index]),
                                onEdit: () => _editHost(hosts[index]),
                              ),
                            ),
                          'tree' => _HostTree(
                              hosts: hosts,
                              onConnect: _showHostDetails,
                              onEdit: _editHost,
                            ),
                          _ => ListView.separated(
                              padding: const EdgeInsets.all(12),
                              itemCount: hosts.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (_, index) => _HostTile(
                                host: hosts[index],
                                onConnect: () => _showHostDetails(hosts[index]),
                                onEdit: () => _editHost(hosts[index]),
                              ),
                            ),
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _connect(HostProfile host) async {
    ref.read(homeTabProvider.notifier).state = 1;
    try {
      final connected =
          await ref.read(sessionControllerProvider.notifier).connect(
                host,
                _verifyHostKey,
                keyboardInteractive: _promptKeyboardInteractive,
              );
      // 用户点了「终止连接」时 connect 正常返回 false，这时不能说已连接。
      if (connected && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: LText('${host.label} 已连接')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: LText('连接失败：$error')));
      }
    }
  }

  Future<void> _showHostDetails(HostProfile host) async {
    final vault = await ref.read(vaultControllerProvider.notifier).ready();
    host = vault.hosts.firstWhere(
      (value) => value.id == host.id,
      orElse: () => host,
    );
    if (!mounted) return;
    final key = vault.keys.cast<SshKeyProfile?>().firstWhere(
          (value) => value?.id == host.identityFileId,
          orElse: () => null,
        );
    final jumps = host.hostChainIds
        .map((id) => vault.hosts.cast<HostProfile?>().firstWhere(
              (value) => value?.id == id,
              orElse: () => null,
            ))
        .whereType<HostProfile>()
        .toList();
    final profile = vault.proxyProfiles.cast<ProxyProfile?>().firstWhere(
          (value) => value?.id == host.proxyProfileId,
          orElse: () => null,
        );
    final proxy = profile?.config ?? host.proxyConfig;
    final action = await showDialog<_HostAction>(
      context: context,
      builder: (context) => AlertDialog(
        icon: HostSystemIcon(host: host, size: 52),
        title: LText(host.label),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DetailRow(
                icon: Icons.link,
                label: '连接地址',
                value: host.protocol == HostProtocol.plugin
                    ? pluginHostEndpoint(host)
                    : '${host.protocol.name.toUpperCase()}  ${host.username}@${host.hostname}:${host.port}',
              ),
              if (host.systemInfo != null)
                _DetailRow(
                  icon: Icons.memory_outlined,
                  label: '系统',
                  value: [
                    host.systemInfo!.prettyName,
                    if (host.systemInfo!.kernel.isNotEmpty)
                      host.systemInfo!.kernel,
                    if (host.systemInfo!.cores > 0)
                      '${host.systemInfo!.cores} 核',
                  ].join(' · '),
                ),
              if (host.protocol != HostProtocol.plugin)
                _DetailRow(
                  icon: Icons.key_outlined,
                  label: '认证',
                  value: sshLoginModeOf(host) == SshLoginMode.tailscale
                      ? 'Tailscale SSH（不发密码和私钥）'
                      : key == null
                          ? (host.password?.isNotEmpty == true
                              ? '密码'
                              : '自动 / 交互式')
                          : '私钥 · ${key.label}',
                ),
              if (jumps.isNotEmpty)
                _DetailRow(
                  icon: Icons.alt_route,
                  label: '跳板机',
                  value: jumps.map((value) => value.label).join(' → '),
                ),
              if (proxy != null)
                _DetailRow(
                  icon: Icons.public,
                  label: '代理',
                  value:
                      '${_proxyTypeLabel(proxy)} · ${proxy.host}:${proxy.port}',
                ),
              if (host.group?.isNotEmpty == true)
                _DetailRow(
                  icon: Icons.folder_outlined,
                  label: '分组',
                  value: host.group!,
                ),
              if (host.tags.isNotEmpty)
                _DetailRow(
                  icon: Icons.sell_outlined,
                  label: '标签',
                  value: host.tags.join('、'),
                ),
            ],
          ),
        ),
        actions: [
          // UU 远程只做了 Android（X06）；远控在 UU 里进行，和 SSH 是并列的两件事。
          if (defaultTargetPlatform == TargetPlatform.android)
            TextButton.icon(
              key: const ValueKey('host-uuremote'),
              onPressed: () => Navigator.pop(context, _HostAction.uuRemote),
              icon: const Icon(Icons.desktop_windows_outlined),
              label: const LText('UU 远程'),
            ),
          // RustDesk 同样只做了 Android（X07）：把主机的 RustDesk ID 交给手机上的 RustDesk 去连。
          if (defaultTargetPlatform == TargetPlatform.android)
            TextButton.icon(
              key: const ValueKey('host-rustdesk'),
              onPressed: () => Navigator.pop(context, _HostAction.rustDesk),
              icon: const Icon(Icons.connected_tv_outlined),
              label: const Text('RustDesk'),
            ),
          TextButton.icon(
            onPressed: () => Navigator.pop(context, _HostAction.edit),
            icon: const Icon(Icons.edit_outlined),
            label: const LText('编辑'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, _HostAction.connect),
            icon: const Icon(Icons.terminal),
            label: const LText('连接'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == _HostAction.edit) {
      await _editHost(host);
    } else if (action == _HostAction.connect) {
      await _connect(host);
    } else if (action == _HostAction.uuRemote) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => UuRemoteHostScreen(hostId: host.id),
      ));
    } else if (action == _HostAction.rustDesk) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => RustDeskHostScreen(hostId: host.id),
      ));
    }
  }

  /// 规则在 application/host_trust.dart；弹窗和保存在 widgets/connection_prompts.dart。
  Future<bool> _verifyHostKey(
    HostProfile host,
    String algorithm,
    String fingerprint,
  ) =>
      hostKeyVerifier(context, ref)(host, algorithm, fingerprint);

  Future<List<String>?> _promptKeyboardInteractive(
    String name,
    String instruction,
    List<({bool echo, String text})> prompts,
  ) =>
      keyboardInteractivePrompt(context)(name, instruction, prompts);

  Future<void> _editHost([HostProfile? host]) async {
    final vault = await ref.read(vaultControllerProvider.notifier).ready();
    var resolvedHost = host;
    if (host != null) {
      resolvedHost = vault.hosts.firstWhere(
        (value) => value.id == host.id,
        orElse: () => host,
      );
    }
    if (!mounted) return;
    final result = await showModalBottomSheet<HostProfile>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => HostEditor(
        host: resolvedHost,
        onDelete: resolvedHost == null
            ? null
            : () => _confirmDeleteHost(resolvedHost!),
        // 测试连接和正式连接用同一套指纹核对与交互式登录。
        verifyHostKey: _verifyHostKey,
        keyboardInteractive: _promptKeyboardInteractive,
      ),
    );
    if (result != null) {
      await ref.read(vaultControllerProvider.notifier).upsertHost(result);
    }
  }

  Future<bool> _confirmDeleteHost(HostProfile host) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.delete_outline),
            title: const LText('删除服务器？'),
            content: LText('将从保险库中删除“${host.label}”，此操作可通过云同步传播到其他设备。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const LText('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return false;
    await ref.read(vaultControllerProvider.notifier).deleteHost(host.id);
    return true;
  }
}

class _VaultGroupChip extends StatelessWidget {
  const _VaultGroupChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 36,
        child: ChoiceChip(
          selected: selected,
          showCheckmark: false,
          onSelected: (_) => onSelected(),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
          padding: EdgeInsets.zero,
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          label: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 52, minHeight: 28),
            child: Center(
              child: LText(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      );
}

class _HostTree extends StatelessWidget {
  const _HostTree({
    required this.hosts,
    required this.onConnect,
    required this.onEdit,
  });

  final List<HostProfile> hosts;
  final ValueChanged<HostProfile> onConnect;
  final ValueChanged<HostProfile> onEdit;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<HostProfile>>{};
    for (final host in hosts) {
      grouped
          .putIfAbsent(
              host.group?.trim().isNotEmpty == true
                  ? host.group!.trim()
                  : '未分组',
              () => <HostProfile>[])
          .add(host);
    }
    final groups = grouped.keys.toList()
      ..sort((a, b) {
        if (a == '未分组') return 1;
        if (b == '未分组') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        final children = grouped[group]!;
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            initiallyExpanded: true,
            leading: Icon(
              group == '未分组'
                  ? Icons.folder_off_outlined
                  : Icons.folder_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: LText(group),
            subtitle: LText('${children.length} 台服务器'),
            children: [
              for (final host in children)
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 28, right: 8),
                  onTap: () => onConnect(host),
                  leading: HostSystemIcon(host: host, size: 38),
                  title: LText(host.label),
                  subtitle: HostAddressLine(host),
                  trailing: IconButton(
                    tooltip: localized('编辑'),
                    onPressed: () => onEdit(host),
                    icon: const Icon(Icons.more_vert),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.onConnect,
    required this.onEdit,
  });
  final HostProfile host;
  final VoidCallback onConnect;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onConnect,
          onLongPress: onEdit,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    HostSystemIcon(host: host, size: 40),
                    const Spacer(),
                    if (host.pinned) const Icon(Icons.push_pin, size: 16),
                    IconButton(
                      onPressed: onEdit,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ],
                ),
                const Spacer(),
                LText(
                  host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 16),
                ),
                const SizedBox(height: 4),
                HostAddressLine(
                  host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (host.group?.isNotEmpty == true)
                  LText(
                    host.group!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}

class _HostTile extends StatelessWidget {
  const _HostTile({
    required this.host,
    required this.onConnect,
    required this.onEdit,
  });
  final HostProfile host;
  final VoidCallback onConnect;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          onTap: onConnect,
          leading: HostSystemIcon(host: host, size: 42),
          title: LText(host.label),
          subtitle: HostAddressLine(host),
          trailing: IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.more_vert),
          ),
        ),
      );
}

enum _HostAction { connect, edit, uuRemote, rustDesk }

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            SizedBox(
              width: 62,
              child: LText(
                label,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(child: LSelectableText(value)),
          ],
        ),
      );
}

/// 未识别的代理类型也要如实显示，而不是显示成 HTTP。
String _proxyTypeLabel(ProxyConfig proxy) =>
    (proxy.type?.name ?? proxy.rawType ?? '未知').toUpperCase();
