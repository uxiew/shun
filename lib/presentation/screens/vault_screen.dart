import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/ai_cli_return.dart';
import '../../application/catalog_overview.dart';
import '../../application/fork_features.dart';
import '../../application/connection_events.dart';
import '../../application/connection_switch.dart';
import '../../application/host_actions.dart';
import '../../application/session_controller.dart';
import '../../application/settings_controller.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../application/vault_controller.dart';
import '../../domain/ai_cli_identity.dart';
import '../../domain/connection_route.dart';
import '../../domain/host_summary.dart';
import '../../domain/models/host.dart';
import '../../domain/ai_cli_work.dart';
import '../../domain/plugins/plugin_host.dart';
import '../../application/home_navigation.dart';
import '../widgets/empty_state.dart';
import '../widgets/host_editor.dart';
import '../widgets/ai_cli_tools_sheet.dart';
import '../../infrastructure/storage/ai_cli_recent_work.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../widgets/catalog_host_sections.dart';
import '../widgets/catalog_import_sheet.dart';
import '../widgets/catalog_text.dart';
import '../widgets/connection_probe_sheet.dart';
import '../widgets/connection_prompts.dart';
import '../widgets/host_actions_sheet.dart';
import '../widgets/host_system_icon.dart';
import '../widgets/port_forward_sheet.dart';
import '../widgets/route_legs_view.dart';
import '../widgets/server_monitor_sheet.dart';
import '../widgets/vault_host_items.dart';
import 'rustdesk_screen.dart';
import 'connection_log_screen.dart';
import 'connection_type_screen.dart';
import 'tailscale_catalog_screen.dart';
import '../../application/rustdesk.dart';
import '../../application/uuremote.dart';
import '../widgets/remote_entry_widgets.dart';
import '../widgets/remote_connections.dart';
import 'uuremote_screen.dart';

class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen(
      {super.key, this.recentWork = const SecureAiCliRecentWork()});
  final AiCliRecentWorkStore recentWork;

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  final _search = TextEditingController();
  String? _group;
  AiCliWorkItem? _recentAi;
  HostProfile? _recentAiHost;
  String? _recentSignature;
  bool _recentLoading = false;

  /// 用户点了「显示已隐藏的主机」。只在这一页记着，重新打开 App 又藏起来。
  bool _showHidden = false;

  Future<void> _loadRecentAi(List<HostProfile> hosts,
      {bool force = false}) async {
    final eligible =
        hosts.where((h) => h.protocol == HostProtocol.ssh).toList();
    final signature = eligible.map(aiCliHostScope).join('|');
    if (_recentLoading || (!force && signature == _recentSignature)) return;
    _recentLoading = true;
    final found = await Future.wait([
      for (final host in eligible)
        widget.recentWork
            .load(aiCliHostScope(host))
            .then((items) => (host: host, item: items.firstOrNull))
            .catchError((Object _) => (host: host, item: null)),
    ]);
    _recentLoading = false;
    if (!mounted) return;
    final latest = found.where((entry) => entry.item != null).toList()
      ..sort((a, b) => b.item!.openedAt.compareTo(a.item!.openedAt));
    setState(() {
      _recentSignature = signature;
      _recentAi = latest.firstOrNull?.item;
      _recentAiHost = latest.firstOrNull?.host;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultControllerProvider);
    final settings = ref.watch(settingsControllerProvider);
    final viewMode = settings.serverViewMode;
    final vault = state.data;
    final recent = _recentAi;
    final recentHost = _recentAiHost;
    // 原普通终端还连着时卡片直接说、点了直接回去。判断不碰网络，和工具列表里的是同一个
    // matchesAiWorkTerminal；tmux 的要先在服务器上核对窗格，不在这里说它还在。
    final recentLive = ref.watch(sessionControllerProvider.select((s) =>
        recent != null &&
        recentHost != null &&
        recent.tmuxRun == null &&
        s.sessions.any(
            (session) => matchesAiWorkTerminal(session, recent, recentHost))));
    if (vault != null) {
      unawaited(_loadRecentAi(vault.hosts));
    }
    ref.listen(homeTabProvider, (_, tab) {
      if (tab == 0) {
        final hosts = ref.read(vaultControllerProvider).data?.hosts;
        if (hosts != null) unawaited(_loadRecentAi(hosts, force: true));
        // 在设置里的目录页增删过来源、读过列表：回到首页重读本机缓存（不发请求）。
        unawaited(ref.read(catalogOverviewProvider.notifier).reload());
      }
    });
    final groups = vault?.customGroups ?? const <String>[];
    final selectedGroup = groups.contains(_group) ? _group : null;
    if (_group != null && selectedGroup == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _group != null && !groups.contains(_group)) {
          setState(() => _group = null);
        }
      });
    }
    final matching = (vault?.hosts ?? const <HostProfile>[]).where((host) {
      final query = _search.text.toLowerCase();
      final matchesQuery = query.isEmpty ||
          host.label.toLowerCase().contains(query) ||
          host.hostname.toLowerCase().contains(query) ||
          host.tags.any((tag) => tag.toLowerCase().contains(query));
      return matchesQuery &&
          (selectedGroup == null || host.group == selectedGroup);
    }).toList();
    final hiddenCount = matching.where((host) => host.hidden).length;
    final visible =
        matching.where((host) => _showHidden || !host.hidden).toList()
          ..sort((a, b) {
            if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
            return a.label.toLowerCase().compareTo(b.label.toLowerCase());
          });
    // 绑定到本机目录来源的主机放进 Tailscale 那一节，不在普通列表里重复。来源不在本机的（被移除过、
    // 从别的手机同步来的）没有组可放，留在普通列表。选了自定义分组时不分节：那一组的主机都在普通列表。
    final catalogSources = ref.watch(catalogOverviewProvider);
    final sectionIds = selectedGroup == null
        ? {for (final source in catalogSources) source.catalogId}
        : const <String>{};
    bool inSection(HostProfile host) =>
        sectionIds.contains(CatalogBinding.of(host)?.catalogId);
    final hosts = visible.where((host) => !inSection(host)).toList();
    final sectionHosts = visible.where(inSection).toList();

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
            child: Row(
              children: [
                // 深浅版本共用乌鸦轮廓，背景和线条明度随当前主题切换。
                Image.asset(
                    Theme.of(context).brightness == Brightness.dark
                        ? 'assets/brand/header_icon.png'
                        : 'assets/brand/header_icon_light.png',
                    width: 28,
                    height: 28),
                const SizedBox(width: 10),
                Text(
                  'shun',
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
                  tooltip: localized('添加连接'),
                  onPressed: () => _editHost(),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
          ),
          if (recent != null && recentHost != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Card(
                child: ListTile(
                  key: const ValueKey('vault-recent-ai-work'),
                  leading: const Icon(Icons.terminal),
                  title: const LText('最近 AI 工作'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LText(
                          '${recentHost.label} · ${recent.name} · ${recent.projectDirectory}'),
                      LText(
                        recentLive
                            ? '原终端仍连接；工具状态请在终端确认'
                            : '会话状态待核对。点开会先查这台主机上的工具，没连着时会连一次',
                        key: const ValueKey('vault-recent-ai-state'),
                      ),
                    ],
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openRecentAi(recent, recentHost),
                ),
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
            child: RefreshIndicator(
              onRefresh: () async {
                await ref.read(vaultControllerProvider.notifier).load();
                // 只重读目录的本机缓存；向 Tailscale 要新列表要点那一组的刷新。
                await ref.read(catalogOverviewProvider.notifier).reload();
                await ref.read(rustDeskProvider.notifier).retryLoad();
                await ref.read(uuRemoteProvider.notifier).retryLoad();
              },
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: RemoteConnections(
                      query: _search.text,
                      visible: selectedGroup == null,
                    ),
                  ),
                  if (state.loading && vault == null)
                    const SliverToBoxAdapter(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (hosts.isEmpty &&
                      hiddenCount == 0 &&
                      sectionIds.isEmpty)
                    SliverToBoxAdapter(
                      child: EmptyState(
                        icon: Icons.dns_outlined,
                        title: '还没有终端连接',
                        subtitle: '添加连接时先选择类型。远控条目仅保存在本机。',
                        action: FilledButton.icon(
                          onPressed: () => _editHost(),
                          icon: const Icon(Icons.add),
                          label: const LText('添加连接'),
                        ),
                      ),
                    )
                  else if (viewMode == 'grid')
                    SliverPadding(
                      padding: const EdgeInsets.all(12),
                      sliver: _hostCardRows(hosts),
                    )
                  else if (viewMode == 'tree')
                    SliverToBoxAdapter(
                      child: VaultHostTree(
                        hosts: hosts,
                        onConnect: _showHostDetails,
                        onMenu: _showHostMenu,
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.all(12),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (_, index) => VaultHostTile(
                            host: hosts[index],
                            onConnect: () => _showHostDetails(hosts[index]),
                            onMenu: () => _showHostMenu(hosts[index]),
                          ),
                          childCount: hosts.length,
                        ),
                      ),
                    ),
                  if (sectionIds.isNotEmpty)
                    SliverToBoxAdapter(
                      child: CatalogHostSections(
                        sources: catalogSources,
                        allHosts: vault?.hosts ?? const [],
                        hosts: sectionHosts,
                        query: _search.text,
                        onConnect: _showHostDetails,
                        onMenu: _showHostMenu,
                        onImport: _importDevice,
                        onRefresh: _refreshSource,
                        onSettings: _openSource,
                      ),
                    ),
                  if (hiddenCount > 0)
                    SliverToBoxAdapter(
                      child: Center(
                        child: TextButton.icon(
                          key: const ValueKey('vault-show-hidden'),
                          onPressed: () =>
                              setState(() => _showHidden = !_showHidden),
                          icon: Icon(_showHidden
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
                          label: _showHidden
                              ? const LText('不显示已隐藏的主机')
                              : catalogLine('显示已隐藏的主机：', '$hiddenCount'),
                        ),
                      ),
                    ),
                ],
              ),
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

  /// 网格视图：一行几张卡片和以前的 SliverGrid 算法一样（每张最宽 230，间距 10），但行高跟着这一行里最高的
  /// 卡片走，最少 148。以前写死 148：系统字体 2 倍时地址那行超出 13 px（R25 模拟器）。卡片内容的高度和
  /// 字体倍数不成正比（1、1.3、2 倍时是 99、115、184），按公式算一换字体就对不上，所以按内容量。
  Widget _hostCardRows(List<HostProfile> hosts) => SliverLayoutBuilder(
        builder: (context, constraints) {
          const maxWidth = 230.0;
          const spacing = 10.0;
          final columns = math.max(
            1,
            (constraints.crossAxisExtent / (maxWidth + spacing)).ceil(),
          );
          final rows = (hosts.length / columns).ceil();
          return SliverList.builder(
            itemCount: rows,
            itemBuilder: (_, row) => Padding(
              padding: EdgeInsets.only(bottom: row == rows - 1 ? 0 : spacing),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var column = 0; column < columns; column++) ...[
                      if (column > 0) const SizedBox(width: spacing),
                      Expanded(
                        child: row * columns + column < hosts.length
                            ? ConstrainedBox(
                                constraints:
                                    const BoxConstraints(minHeight: 148),
                                child: VaultHostCard(
                                  host: hosts[row * columns + column],
                                  onConnect: () => _showHostDetails(
                                      hosts[row * columns + column]),
                                  onMenu: () => _showHostMenu(
                                      hosts[row * columns + column]),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      );

  Future<void> _showHostDetails(HostProfile host) async {
    final vault = await ref.read(vaultControllerProvider.notifier).ready();
    host = vault.hosts.firstWhere(
      (value) => value.id == host.id,
      orElse: () => host,
    );
    if (!mounted) return;
    if (host.protocol == HostProtocol.unknown) {
      await _editHost(host);
      return;
    }
    final key = vault.keys.cast<SshKeyProfile?>().firstWhere(
          (value) => value?.id == host.identityFileId,
          orElse: () => null,
        );
    final login = describeLogin(host, key);
    final route = host.protocol == HostProtocol.plugin
        ? null
        : hostRouteStatus(host,
            hosts: vault.hosts,
            proxyProfiles: vault.proxyProfiles,
            keys: vault.keys);
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
                value: switch (host.protocol) {
                  HostProtocol.plugin => pluginHostEndpoint(host),
                  // Telnet 不填用户名，拼上去就成了「@host」。
                  HostProtocol.telnet =>
                    'TELNET  ${host.hostname}:${host.port}',
                  _ =>
                    '${host.protocol.name.toUpperCase()}  ${host.username}@${host.hostname}:${host.port}',
                },
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
              if (login != null)
                _DetailRow(
                  key: const ValueKey('host-detail-login'),
                  icon: Icons.key_outlined,
                  label: '认证',
                  value: login,
                ),
              // 和编辑器预览、测试连接、失败页是同一份路线；算不出来就显示连接时会报的那句，
              // 不写「直连」：引用的代理、跳板被删了，连接不会退回直连。
              if (route != null)
                _DetailRow(
                  key: const ValueKey('host-detail-route'),
                  icon: Icons.alt_route,
                  label: '路线',
                  value: route.error ?? (_isDirect(route.plan!) ? '直连' : ''),
                  error: route.error != null,
                  child: route.error == null && !_isDirect(route.plan!)
                      ? RouteLegsView(plan: route.plan!, dense: true)
                      : null,
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
          // 和 ⋮ 菜单同一个条件：路线算不出来时工具列表只会报同一句错。
          if (host.protocol == HostProtocol.ssh && route?.error == null)
            TextButton.icon(
              key: const ValueKey('host-ai-cli'),
              onPressed: () => Navigator.pop(context, _HostAction.aiCli),
              icon: const Icon(Icons.terminal),
              label: const LText('AI 工具'),
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
    } else if (action == _HostAction.aiCli) {
      await _showAiCli(host);
    }
  }

  /// ⋮ 菜单（R43）。菜单里列什么在打开的这一刻算：保险库现在的配置、开着的标签、Mosh 插件能不能用。
  Future<void> _showHostMenu(HostProfile host) async {
    final vault = await ref.read(vaultControllerProvider.notifier).ready();
    host = vault.hosts.firstWhere((h) => h.id == host.id, orElse: () => host);
    final other = await ref
        .read(sessionControllerProvider.notifier)
        .otherTransportFor(host);
    if (!mounted) return;
    final sessions = ref.read(sessionControllerProvider);
    final menu = HostMenu(
      host: host,
      otherTransport: other,
      sshSession: connectedSshSessionOf(host, sessions.sessions,
          active: sessions.active),
      probePlan: probePlanOf(host, vault),
      hasConnectionLog: ref
          .read(connectionEventLogProvider)
          .any((event) => event.hostId == host.id),
    );
    final action = await showModalBottomSheet<HostMenuAction>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => HostActionsSheet(menu: menu),
    );
    if (action == null || !mounted) return;
    final session = menu.sshSession;
    // 菜单开着的时候标签可能断了：断了就说清楚，不拿断掉的连接去开转发。
    if (session != null &&
        !session.connected &&
        const {
          HostMenuAction.portForward,
          HostMenuAction.files,
          HostMenuAction.monitor,
        }.contains(action)) {
      _message('这台主机的 SSH 标签刚刚断开了，先重新连接。');
      return;
    }
    switch (action) {
      case HostMenuAction.connectOther:
        await _connectWith(host, menu.otherTransport!);
      case HostMenuAction.portForward:
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => PortForwardSheet(session: session!),
        );
      case HostMenuAction.files:
        ref.read(sftpNavigationRequestProvider.notifier).state =
            SftpNavigationRequest(sessionId: session!.id);
        ref.read(homeTabProvider.notifier).state = 2;
      case HostMenuAction.monitor:
        await showModalBottomSheet<void>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          builder: (_) => ServerMonitorSheet(session: session!),
        );
      case HostMenuAction.testConnection:
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => ConnectionProbeSheet(
            host: host,
            plan: menu.probePlan!,
            verifyHostKey: _verifyHostKey,
            keyboardInteractive: _promptKeyboardInteractive,
          ),
        );
      case HostMenuAction.aiCli:
        await _showAiCli(host);
      case HostMenuAction.connectionLog:
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ConnectionLogScreen(hostId: host.id),
        ));
      case HostMenuAction.edit:
        await _editHost(host);
      case HostMenuAction.hide:
        await _setHidden(host, true);
      case HostMenuAction.unhide:
        await _setHidden(host, false);
    }
  }

  /// 没导入的目录设备：只走导入页（先成为一台主机），不连接。
  Future<void> _importDevice(CatalogCache cache, String deviceId) async {
    final added = await showCatalogImportSheet(
      context,
      cache: cache,
      deviceIds: [deviceId],
    );
    if (added == null || !mounted) return;
    final head = localized('已导入主机：');
    final tail = localized('。还没有连接过：第一次连接时照常核对服务器指纹。');
    _plainMessage('$head$added$tail');
  }

  /// 组头的刷新。本机没存凭据就读不了，打开来源页让用户粘 token 或填 OAuth client。
  Future<void> _refreshSource(CatalogSourceView source) async {
    if (!source.hasSavedCredentials) {
      await _openSource(source.catalogId);
      return;
    }
    try {
      final outcome = await ref
          .read(catalogOverviewProvider.notifier)
          .refresh(source.catalogId);
      if (outcome != null) _plainMessage(catalogRefreshReport(outcome));
    } on Object catch (error) {
      _message('$error');
    }
  }

  Future<void> _openSource(String catalogId) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CatalogSourceScreen(catalogId: catalogId),
    ));
    // 来源页里可能读过列表、删了凭据、移除了来源。
    if (mounted) await ref.read(catalogOverviewProvider.notifier).reload();
  }

  Future<void> _connectWith(HostProfile host, TabTransport to) async {
    ref.read(homeTabProvider.notifier).state = 1;
    try {
      await ref.read(sessionControllerProvider.notifier).connectWithTransport(
            host,
            to,
            _verifyHostKey,
            keyboardInteractive: _promptKeyboardInteractive,
          );
    } catch (error) {
      _message('连接失败：$error');
    }
  }

  /// 只改「隐藏」这一个字段。藏起来时给一个撤销，免得点错了找不到在哪里恢复。
  Future<void> _setHidden(HostProfile host, bool hidden) async {
    final vault = ref.read(vaultControllerProvider.notifier);
    await vault.updateHost(host.id, (current) => withHidden(current, hidden));
    if (!mounted || !hidden) return;
    final head = localized('已隐藏：');
    final tail = localized('。照常能连，列表底部能找回来。');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$head${host.label}$tail'),
      action: SnackBarAction(
        label: localized('撤销'),
        onPressed: () => unawaited(
            vault.updateHost(host.id, (current) => withHidden(current, false))),
      ),
    ));
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: LText(text)));
  }

  /// 已经翻译好、拼上了数据的提示，不再过一遍翻译。
  void _plainMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// 首页「最近 AI 工作」：原终端还连着就直接回去（不拨号、不开工具列表），不然打开这台的工具列表，
  /// 那里核对 tmux、给原生继续。卡片是之前读的，先按保险库现在的样子重核主机：改了地址、用户就不直接回去，
  /// 交给工具列表如实报「身份已改变」。
  Future<void> _openRecentAi(AiCliWorkItem item, HostProfile host) async {
    final current = ref
        .read(vaultControllerProvider)
        .data
        ?.hosts
        .where((value) => value.id == host.id)
        .firstOrNull;
    // tmux 的不在这里直接回：卡片没说它还在，点了就该去工具列表里核对。
    if (item.tmuxRun == null &&
        current != null &&
        aiCliHostScope(current) == aiCliHostScope(host) &&
        returnToLiveAiTerminal(ref,
            store: widget.recentWork, host: current, item: item)) {
      return;
    }
    await _showAiCli(current ?? host);
  }

  Future<void> _showAiCli(HostProfile host) async {
    await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => AiCliToolsSheet(
            host: host,
            verifyHostKey: _verifyHostKey,
            keyboardInteractive: _promptKeyboardInteractive));
    if (mounted) {
      final hosts = ref.read(vaultControllerProvider).data?.hosts;
      if (hosts != null) unawaited(_loadRecentAi(hosts, force: true));
    }
  }

  /// 规则在 application/host_trust.dart；弹窗和保存在 widgets/connection_prompts.dart。
  Future<bool> _verifyHostKey(
    HostProfile host,
    String algorithm,
    String fingerprint,
  ) =>
      hostKeyVerifier(context)(host, algorithm, fingerprint);

  Future<List<String>?> _promptKeyboardInteractive(
    String name,
    String instruction,
    List<({bool echo, String text})> prompts,
  ) =>
      keyboardInteractivePrompt(context)(name, instruction, prompts);

  Future<void> _editHost([HostProfile? host]) async {
    ConnectionTypeChoice? choice;
    if (host == null) {
      choice = await Navigator.of(context).push<ConnectionTypeChoice>(
        MaterialPageRoute(builder: (_) => const ConnectionTypeScreen()),
      );
      if (!mounted || choice == null) return;
      if (choice.remote != null) {
        final name = await remoteEntryName(context);
        if (!mounted || name == null) return;
        try {
          final rustdesk = choice.remote == RemoteConnectionType.rustdesk;
          final id = rustdesk
              ? await ref.read(rustDeskProvider.notifier).createEntry(name)
              : await ref.read(uuRemoteProvider.notifier).createEntry(name);
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => rustdesk
                  ? RustDeskHostScreen(hostId: id)
                  : UuRemoteHostScreen(hostId: id),
            ),
          );
        } on Object catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: LText('$e')));
          }
        }
        return;
      }
    }
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
      // 下滑关闭会直接 pop，绕过编辑器「有没保存的改动」的确认（R41）；关闭走 ×、取消或返回键。
      enableDrag: false,
      builder: (_) => HostEditor(
        host: resolvedHost,
        initialProtocol: choice?.protocol ?? HostProtocol.ssh,
        initialPluginId: choice?.pluginId,
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
            // 云同步默认关着（ForkFeatures）：关着时不说「会传到其他设备」，那句是上游留下的。
            content: LText(ref.read(forkFeaturesProvider).cloudSync
                ? '将从保险库中删除“${host.label}”，此操作可通过云同步传播到其他设备。'
                : '将从保险库中删除“${host.label}”，删了不能撤销。'),
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

enum _HostAction { connect, edit, aiCli }

/// 没经代理、没有跳板：路线就是「手机 → 目标」，和上面的连接地址重复，只写「直连」。
bool _isDirect(RoutePlan plan) =>
    plan.entry is DirectEntry && plan.jumps.isEmpty;

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.error = false,
    this.child,
  });

  final IconData icon;
  final String label;
  final String value;

  /// [value] 是连接时会报的错，用错误色。
  final bool error;

  /// 有就显示它，不显示 [value]。
  final Widget? child;

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
            Expanded(
              child: child ??
                  LSelectableText(
                    value,
                    style: error
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
            ),
          ],
        ),
      );
}
