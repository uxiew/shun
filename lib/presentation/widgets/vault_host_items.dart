import 'package:flutter/material.dart';
import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import 'host_address_line.dart';
import 'host_type_icon.dart';

/// 隐藏的主机只在用户点了「显示已隐藏的主机」后才出现，淡一点，和平时的分开（R43）。
Widget dimIfHidden(HostProfile host, Widget child) => host.hidden
    ? Opacity(
        key: ValueKey('vault-hidden-host-${host.id}'),
        opacity: 0.55,
        child: child,
      )
    : child;

/// 三种视图共用的 ⋮ 按钮：弹出这台主机的操作菜单。
Widget vaultHostMenuButton(HostProfile host, VoidCallback onMenu, IconData icon,
        {VisualDensity? density}) =>
    IconButton(
      key: ValueKey('vault-host-menu-${host.id}'),
      tooltip: localized('更多操作'),
      visualDensity: density,
      onPressed: onMenu,
      icon: Icon(icon),
    );

class VaultHostTree extends StatelessWidget {
  const VaultHostTree({
    super.key,
    required this.hosts,
    required this.onConnect,
    required this.onMenu,
  });

  final List<HostProfile> hosts;
  final ValueChanged<HostProfile> onConnect;
  final ValueChanged<HostProfile> onMenu;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<HostProfile>>{};
    for (final host in hosts) {
      grouped
          .putIfAbsent(
            host.group?.trim().isNotEmpty == true ? host.group!.trim() : '未分组',
            () => <HostProfile>[],
          )
          .add(host);
    }
    final groups = grouped.keys.toList()
      ..sort((a, b) {
        if (a == '未分组') return 1;
        if (b == '未分组') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
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
                dimIfHidden(
                  host,
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 28, right: 8),
                    onTap: () => onConnect(host),
                    onLongPress: () => onMenu(host),
                    leading: HostLeadingIcon(host: host, size: 38),
                    title: LText(host.label),
                    subtitle: HostAddressLine(host),
                    trailing: vaultHostMenuButton(
                        host, () => onMenu(host), Icons.more_vert),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class VaultHostCard extends StatelessWidget {
  const VaultHostCard({
    super.key,
    required this.host,
    required this.onConnect,
    required this.onMenu,
  });
  final HostProfile host;
  final VoidCallback onConnect;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) => dimIfHidden(host, _card(context));

  Widget _card(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onConnect,
          onLongPress: onMenu,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    HostLeadingIcon(host: host, size: 40),
                    const Spacer(),
                    if (host.pinned) const Icon(Icons.push_pin, size: 16),
                    vaultHostMenuButton(host, onMenu, Icons.more_horiz,
                        density: VisualDensity.compact),
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

class VaultHostTile extends StatelessWidget {
  const VaultHostTile({
    super.key,
    required this.host,
    required this.onConnect,
    required this.onMenu,
  });
  final HostProfile host;
  final VoidCallback onConnect;
  final VoidCallback onMenu;
  @override
  Widget build(BuildContext context) => dimIfHidden(
        host,
        Card(
          child: ListTile(
            onTap: onConnect,
            onLongPress: onMenu,
            leading: HostLeadingIcon(host: host, size: 42),
            title: LText(host.label),
            subtitle: HostAddressLine(host),
            trailing: vaultHostMenuButton(host, onMenu, Icons.more_vert),
          ),
        ),
      );
}
