import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';

import '../../../application/session_controller.dart';
import '../../../domain/models/host.dart';
import '../../../domain/tmux/tmux_target.dart';
import '../../../infrastructure/ssh/ssh_service.dart';
import '../../../infrastructure/ssh/system_management_service.dart';
import 'caddy_manager_panel.dart';
import 'docker_manager_panel.dart';
import 'process_manager_panel.dart';
import 'service_manager_panel.dart';
import 'tmux_manager_panel.dart';

class SystemManagementSheet extends ConsumerStatefulWidget {
  const SystemManagementSheet({
    super.key,
    required this.session,
    required this.snippets,
    required this.onOpenTerminal,
    required this.onOpenSftp,
  });

  final ActiveTerminalSession session;
  final List<CommandSnippet> snippets;
  final Future<void> Function(String label, String command) onOpenTerminal;
  final ValueChanged<String> onOpenSftp;

  @override
  ConsumerState<SystemManagementSheet> createState() =>
      _SystemManagementSheetState();
}

class _SystemManagementSheetState extends ConsumerState<SystemManagementSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _service = SystemManagementService();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _runInteractive(String label, String command) async {
    Navigator.of(context).pop();
    await widget.onOpenTerminal(label, command);
  }

  /// 在新标签里附着 tmux 目标。先关面板；附着失败时（目标已经不在了之类）等待卡片会写明原因，这里再提示一句。
  Future<void> _attachTmux(TmuxTarget target) async {
    final controller = ref.read(sessionControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    try {
      await controller.openTmuxTerminal(widget.session, target);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: LText('$error')));
    }
  }

  void _openSftp(String filePath) {
    Navigator.of(context).pop();
    widget.onOpenSftp(filePath);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 面板开着时标签可能断线、恢复成新连接：跟着重画。这个面板只管打开时的那一代连接，
    // 它断了整页禁用（R24）：不留点了只会报错的按钮，也不替用户把操作搬到新连接上。
    ref.watch(sessionControllerProvider);
    final client = widget.session.sshClient;
    final live = widget.session.connected && client != null && !client.isClosed;
    return FractionallySizedBox(
      heightFactor: .94,
      child: Material(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: colors.onSurfaceVariant.withValues(alpha: .35),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: const Icon(Icons.admin_panel_settings_outlined),
              ),
              title: const LText('系统管理'),
              subtitle: LText(
                '${widget.session.host.username}@${widget.session.host.hostname}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: localized('关闭'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.center,
              tabs: const [
                Tab(icon: Icon(Icons.account_tree_outlined), text: '进程'),
                Tab(icon: Icon(Icons.view_in_ar_outlined), text: 'Docker'),
                Tab(
                  icon: Icon(Icons.miscellaneous_services_outlined),
                  text: '服务',
                ),
                Tab(icon: Icon(Icons.language_outlined), text: 'Caddy'),
                Tab(icon: Icon(Icons.terminal_outlined), text: 'tmux'),
              ],
            ),
            const Divider(height: 1),
            if (!live)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: LText(
                  key: const ValueKey('system-management-disconnected'),
                  '这个标签的 SSH 连接已断开：这里的操作都不会执行。重新连接后，从新连接打开系统管理。',
                  style: TextStyle(color: colors.error),
                ),
              ),
            Expanded(
              child: AbsorbPointer(
                absorbing: !live,
                child: Opacity(
                  opacity: live ? 1 : .4,
                  child: _panels(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panels() => TabBarView(
        controller: _tabs,
        children: [
          ProcessManagerPanel(
            session: widget.session,
            service: _service,
          ),
          DockerManagerPanel(
            session: widget.session,
            service: _service,
            onOpenTerminal: _runInteractive,
            onOpenConfig: _openSftp,
          ),
          ServiceManagerPanel(
            session: widget.session,
            service: _service,
          ),
          CaddyManagerPanel(
            session: widget.session,
            service: _service,
          ),
          TmuxManagerPanel(
            session: widget.session,
            snippets: widget.snippets,
            onAttach: _attachTmux,
          ),
        ],
      );
}
