import 'package:flutter/material.dart';
import 'package:prism_ui/icons/icons.dart' as glyphs;
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'host_address_line.dart';
import 'host_type_icon.dart';

/// 三种视图共用的 ⋮ 按钮：弹出这台主机的操作菜单。
/// 一律 48dp：网格卡片以前用紧凑密度，真机上只有 40dp（UX02）。
Widget vaultHostMenuButton(
        HostProfile host, VoidCallback onMenu, IconData icon) =>
    IconButton(
      key: ValueKey('vault-host-menu-${host.id}'),
      tooltip: localized('更多操作'),
      onPressed: onMenu,
      icon: Icon(icon),
    );

/// 树形视图（R87 换成 Prism 分组）：每个分组一组卡片，组头点了收起 / 展开，默认展开。
/// 收起只在这一页记着，切走再回来、重开 App 都是展开的（和以前的 ExpansionTile 一样）。
class VaultHostTree extends StatefulWidget {
  const VaultHostTree({
    super.key,
    required this.hosts,
    required this.onConnect,
    required this.onMenu,
    this.catalogOsOf,
  });

  final List<HostProfile> hosts;
  final ValueChanged<HostProfile> onConnect;
  final ValueChanged<HostProfile> onMenu;

  /// 主机关联的 Tailscale 设备报的系统，见 [HostSystemIcon.catalogOs]。
  final String? Function(HostProfile host)? catalogOsOf;

  @override
  State<VaultHostTree> createState() => _VaultHostTreeState();
}

class _VaultHostTreeState extends State<VaultHostTree> {
  final _collapsed = <String>{};

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<HostProfile>>{};
    for (final host in widget.hosts) {
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final group in groups)
            ShunSection(
              children: [
                _groupHeader(group, grouped[group]!.length),
                if (!_collapsed.contains(group))
                  for (final host in grouped[group]!)
                    VaultHostTile(
                      host: host,
                      onConnect: () => widget.onConnect(host),
                      onMenu: () => widget.onMenu(host),
                      catalogOs: widget.catalogOsOf?.call(host),
                    ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _groupHeader(String group, int count) {
    final open = !_collapsed.contains(group);
    return ShunListRow(
      key: ValueKey('vault-tree-group-$group'),
      title: group,
      subtitle: '$count 台服务器',
      leading: Icon(
        group == '未分组' ? Icons.folder_off_outlined : Icons.folder_outlined,
      ),
      trailing: ExcludeSemantics(
        child: Icon(open ? Icons.expand_less : Icons.expand_more),
      ),
      expanded: open,
      onTap: () => setState(
        () => open ? _collapsed.add(group) : _collapsed.remove(group),
      ),
    );
  }
}

/// 网格视图的一张卡片（R87 换成 Prism 卡片，FlClash 代理页的卡片同款）。
///
/// 读屏：整张卡片是一个按钮节点（Prism 卡片自带），系统、协议角标、名字、地址、分组都念在里面，
/// 带「长按」动作；⋮ 是里面独立的按钮节点。
class VaultHostCard extends StatelessWidget {
  const VaultHostCard({
    super.key,
    required this.host,
    required this.onConnect,
    required this.onMenu,
    this.catalogOs,
  });
  final HostProfile host;
  final VoidCallback onConnect;
  final VoidCallback onMenu;
  final String? catalogOs;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return prism.Card(
      radius: prism.AppCorner.lg,
      onPressed: onConnect,
      // 长按手势放在卡片里面：它的「长按」动作才会并进卡片那个节点。只挂长按，Prism 卡片
      // 照样自己收点按（它只在里面有带 onTap 的部件时才让出去）。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: onMenu,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 4, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  HostLeadingIcon(host: host, size: 40, catalogOs: catalogOs),
                  const Spacer(),
                  if (host.pinned)
                    glyphs.GlyphIcon(
                      glyphs.Glyphs.pin,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                  vaultHostMenuButton(host, onMenu, Icons.more_horiz),
                ],
              ),
              const Spacer(),
              const SizedBox(height: 10),
              LText(
                host.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: prism.AppTextStyle.headline
                    .of(context)
                    .copyWith(color: colors.onSurface),
              ),
              const SizedBox(height: 2),
              HostAddressLine(
                host,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // 细节行用 footnote（FlClash 代理卡片同款）：地址长，大一号就被截掉一截。
                style: prism.AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: colors.onSurfaceVariant),
              ),
              if (host.group?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                // 分组是中性的小胶囊（FlClash 状态卡的标签同款）：颜色留给状态，不再用主色字。
                ShunPill(host.group!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 列表视图（和树形视图、Tailscale 分节）里的一行。要放在 Prism 分组里（外面有
/// ItemPositionProvider），画成 FlClash 设置页那种连在一起的分组卡片。
class VaultHostTile extends StatelessWidget {
  const VaultHostTile({
    super.key,
    required this.host,
    required this.onConnect,
    required this.onMenu,
    this.catalogOs,
  });
  final HostProfile host;
  final VoidCallback onConnect;
  final VoidCallback onMenu;
  final String? catalogOs;
  @override
  Widget build(BuildContext context) => ShunListRow(
        title: host.label,
        leading: HostLeadingIcon(host: host, size: 40, catalogOs: catalogOs),
        describeLeading: true,
        details: HostAddressLine(host),
        trailing: vaultHostMenuButton(host, onMenu, Icons.more_vert),
        onTap: onConnect,
        onLongPress: onMenu,
      );
}
