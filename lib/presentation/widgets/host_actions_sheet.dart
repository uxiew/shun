import 'package:flutter/material.dart';

import '../../application/connection_switch.dart';
import '../../application/host_actions.dart';
import '../localization/localized_widgets.dart';
import 'host_address_line.dart';
import 'host_type_icon.dart';

/// 主机列表里点 ⋮ 弹出来的菜单（R43）。列哪些项由 [HostMenu] 定，这里只管长什么样；
/// 点了哪一项就把它返回给调用方，由调用方去做。
class HostActionsSheet extends StatelessWidget {
  const HostActionsSheet({super.key, required this.menu, this.catalogOs});

  final HostMenu menu;

  /// 见 [HostSystemIcon.catalogOs]。
  final String? catalogOs;

  @override
  Widget build(BuildContext context) {
    final host = menu.host;
    final small = Theme.of(context).textTheme.bodySmall;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  HostLeadingIcon(host: host, size: 40, catalogOs: catalogOs),
              title: LText(host.label,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: HostAddressLine(host,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            for (final action in menu.actions)
              ListTile(
                key: ValueKey('host-menu-${action.name}'),
                leading: Icon(_icon(action)),
                title: LText(_title(action)),
                subtitle: switch (_subtitle(action)) {
                  final text? => LText(text, style: small),
                  null => null,
                },
                onTap: () => Navigator.pop(context, action),
              ),
          ],
        ),
      ),
    );
  }

  IconData _icon(HostMenuAction action) => switch (action) {
        HostMenuAction.connectOther => menu.otherTransport == TabTransport.mosh
            ? Icons.wifi_tethering
            : Icons.lock_outline,
        HostMenuAction.portForward => Icons.swap_horiz,
        HostMenuAction.files => Icons.folder_outlined,
        HostMenuAction.monitor => Icons.monitor_heart_outlined,
        HostMenuAction.aiCli => Icons.terminal,
        HostMenuAction.testConnection => Icons.network_check,
        HostMenuAction.connectionLog => Icons.history,
        HostMenuAction.edit => Icons.edit_outlined,
        HostMenuAction.hide => Icons.visibility_off_outlined,
        HostMenuAction.unhide => Icons.visibility_outlined,
      };

  String _title(HostMenuAction action) => switch (action) {
        HostMenuAction.connectOther =>
          menu.otherTransport == TabTransport.mosh ? '用 Mosh 连接' : '用 SSH 连接',
        HostMenuAction.portForward => '端口转发',
        HostMenuAction.files => '文件',
        HostMenuAction.monitor => '性能监控',
        HostMenuAction.aiCli => 'AI 工具',
        HostMenuAction.testConnection => '测试连接',
        HostMenuAction.connectionLog => '连接日志',
        HostMenuAction.edit => '编辑',
        HostMenuAction.hide => '在列表里隐藏',
        HostMenuAction.unhide => '取消隐藏',
      };

  /// 只留会让人误会的那一项：「用 Mosh 连接」听着像改了这台的默认方式。其余的标题就够了，
  /// 各项做什么写在使用手册第 2 节「主机列表」；隐藏之后的提示条里有撤销（docs/dev/ui-text.md）。
  String? _subtitle(HostMenuAction action) => switch (action) {
        HostMenuAction.connectOther => '另开标签，不改默认方式',
        _ => null,
      };
}
