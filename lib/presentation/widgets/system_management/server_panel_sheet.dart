import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';

import '../../../application/home_navigation.dart';
import '../../../application/session_controller.dart';
import '../../../application/vault_controller.dart';
import '../../../domain/models/host.dart';
import '../../../domain/tmux/tmux_target.dart';
import '../../../infrastructure/ssh/server_monitor_service.dart';
import '../../../infrastructure/ssh/ssh_service.dart';
import '../../../infrastructure/ssh/system_management_service.dart';
import '../host_system_icon.dart';
import 'caddy_manager_panel.dart';
import 'docker_manager_panel.dart';
import 'process_manager_panel.dart';
import 'server_overview_panel.dart';
import 'service_manager_panel.dart';
import 'tmux_manager_panel.dart';

/// 打开性能监控面板。终端右上角、快捷栏「更多」、主机 ⋮ 菜单都走这里（R68），打开的是同一个面板。
Future<void> showServerPanel(
  BuildContext context,
  WidgetRef ref,
  ActiveTerminalSession session,
) {
  final messenger = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ServerPanelSheet(
      session: session,
      snippets: ref.read(vaultControllerProvider).data?.snippets ?? const [],
      onOpenTerminal: (label, command) async {
        try {
          await ref
              .read(sessionControllerProvider.notifier)
              .openManagedTerminal(session, label: label, command: command);
        } catch (error) {
          messenger.showSnackBar(
            SnackBar(content: LText('无法打开 $label：$error')),
          );
        }
      },
      onOpenSftp: (filePath) {
        ref.read(sftpNavigationRequestProvider.notifier).state =
            SftpNavigationRequest(sessionId: session.id, filePath: filePath);
        ref.read(homeTabProvider.notifier).state = 2;
      },
    ),
  );
}

/// 一台机器的性能监控面板（R68，所有者 11-01）：顶部 tab 能点也能左右滑。
/// 以前分成「性能监控」和「系统管理」两个面板、两个入口，看同一台机器要来回开。
class ServerPanelSheet extends ConsumerStatefulWidget {
  const ServerPanelSheet({
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
  ConsumerState<ServerPanelSheet> createState() => _ServerPanelSheetState();
}

class _ServerPanelSheetState extends ConsumerState<ServerPanelSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final SessionMonitor _monitor;
  final _service = SystemManagementService();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 6, vsync: this);
    _monitor = widget.session.monitor ??= SessionMonitor(widget.session);
    _monitor.start();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _runInteractive(String label, String command) async {
    Navigator.of(context).pop();
    // 从「连接」页的主机菜单打开时人不在终端页，新标签要看得到。
    ref.read(homeTabProvider.notifier).state = 1;
    await widget.onOpenTerminal(label, command);
  }

  /// 在新标签里附着 tmux 目标。先关面板；附着失败时（目标已经不在了之类）等待卡片会写明原因，这里再提示一句。
  Future<void> _attachTmux(TmuxTarget target) async {
    final controller = ref.read(sessionControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    ref.read(homeTabProvider.notifier).state = 1;
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
    // 它断了管理页整页禁用（R24）：不留点了只会报错的按钮，也不替用户把操作搬到新连接上。
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
            AnimatedBuilder(
              animation: Listenable.merge([_monitor, _tabs]),
              builder: (context, _) => _header(context),
            ),
            TabBar(
              key: const ValueKey('server-panel-tabs'),
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(
                  icon: const Icon(Icons.monitor_heart_outlined),
                  text: localized('概览'),
                ),
                Tab(
                  icon: const Icon(Icons.account_tree_outlined),
                  text: localized('进程'),
                ),
                const Tab(icon: Icon(Icons.terminal_outlined), text: 'tmux'),
                const Tab(
                    icon: Icon(Icons.view_in_ar_outlined), text: 'Docker'),
                Tab(
                  icon: const Icon(Icons.miscellaneous_services_outlined),
                  text: localized('服务'),
                ),
                const Tab(icon: Icon(Icons.language_outlined), text: 'Caddy'),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  // 概览断线后还留着断开前的数，有它自己的提示，不变灰。
                  ServerOverviewPanel(session: widget.session),
                  _managed(
                    live,
                    ProcessManagerPanel(
                      session: widget.session,
                      service: _service,
                    ),
                  ),
                  _managed(
                    live,
                    TmuxManagerPanel(
                      session: widget.session,
                      snippets: widget.snippets,
                      onAttach: _attachTmux,
                    ),
                  ),
                  _managed(
                    live,
                    DockerManagerPanel(
                      session: widget.session,
                      service: _service,
                      onOpenTerminal: _runInteractive,
                      onOpenConfig: _openSftp,
                    ),
                  ),
                  _managed(
                    live,
                    ServiceManagerPanel(
                      session: widget.session,
                      service: _service,
                    ),
                  ),
                  _managed(
                    live,
                    CaddyManagerPanel(
                      session: widget.session,
                      service: _service,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 机器名和系统一行。刷新键只对概览有用：别的页有自己的刷新。
  Widget _header(BuildContext context) {
    final system = _monitor.stats?.system ?? widget.session.systemInfo;
    final live = widget.session.connected && !_monitor.stopped;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          HostSystemIcon(
            host: widget.session.host,
            systemInfo: system,
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LText(
                  system?.hostname.isNotEmpty == true
                      ? system!.hostname
                      : widget.session.host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                LText(
                  system == null
                      ? '正在读取系统信息…'
                      : '${system.prettyName} · ${system.kernel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (_tabs.index == 0)
            IconButton(
              key: const ValueKey('server-panel-refresh'),
              tooltip: localized('刷新'),
              onPressed: _monitor.polling || !live
                  ? null
                  : () => unawaited(_monitor.refresh()),
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            tooltip: localized('关闭'),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  /// 进程、tmux 这些管理页：连接断了写明原因，整页变灰、点不动（R24）。
  Widget _managed(bool live, Widget panel) => Column(
        children: [
          if (!live)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: LText(
                key: const ValueKey('system-management-disconnected'),
                '连接已断开，这里的操作都不会执行。重新连接后再从新连接打开。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: AbsorbPointer(
              absorbing: !live,
              child: Opacity(opacity: live ? 1 : .4, child: panel),
            ),
          ),
        ],
      );
}
