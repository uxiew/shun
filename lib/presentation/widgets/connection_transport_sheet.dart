import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';

import '../../application/connection_switch.dart';
import '../../application/port_forward_controller.dart';
import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/host_identity.dart';
import '../../domain/models/host.dart';
import '../../domain/plugins/mosh_bootstrap.dart';
import '../../domain/plugins/mosh_install_hint.dart';
import '../../domain/plugins/mosh_route.dart';
import '../../domain/tmux/tmux_target.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../../infrastructure/tmux/tmux_protocol.dart';
import '../../infrastructure/tmux/tmux_service.dart';
import 'connection_prompts.dart';

/// 标签条右侧的连接方式徽标（R42）：当前标签走 SSH 还是 Mosh，点开是「连接方式」菜单。
/// Telnet、第三方插件标签不显示。
class TransportBadge extends ConsumerWidget {
  const TransportBadge({super.key, required this.session});

  final ActiveTerminalSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transport = transportOf(session);
    if (transport == null) return const SizedBox.shrink();
    final switching =
        ref.watch(sessionControllerProvider).switching.containsKey(session.id);
    final scheme = Theme.of(context).colorScheme;
    final mosh = transport == TabTransport.mosh;
    return Tooltip(
      message: localized('连接方式'),
      child: InkWell(
        key: const ValueKey('terminal-transport-badge'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => showTransportSheet(context, session),
        // 看着小，能点的是 48dp（UX02）。
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color:
                    mosh ? scheme.tertiaryContainer : scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (switching) ...[
                    const SizedBox.square(
                      dimension: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    transport.label.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: .6,
                          color: mosh
                              ? scheme.onTertiaryContainer
                              : scheme.onSecondaryContainer,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showTransportSheet(
  BuildContext context,
  ActiveTerminalSession session,
) =>
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => TransportSheet(sessionId: session.id),
    );

/// 「连接方式」菜单：这个标签连的是哪台、里面是普通 shell 还是哪个 tmux 会话、现在什么状态；
/// 切换、设为默认、选 tmux 会话。做不了的项灰掉并写原因，不藏。
class TransportSheet extends ConsumerStatefulWidget {
  const TransportSheet({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<TransportSheet> createState() => _TransportSheetState();
}

class _TransportSheetState extends ConsumerState<TransportSheet> {
  Future<TransportMenu?>? _menu;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _menu = ref
        .read(sessionControllerProvider.notifier)
        .transportMenu(widget.sessionId);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionControllerProvider);
    final session = state.sessions
        .where((value) => value.id == widget.sessionId)
        .firstOrNull;
    if (session == null) {
      // 标签已经关了（或换成了新的）：菜单跟着收起来。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }
    final progress = state.switching[session.id];
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            LText('连接方式', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _Facts(session: session, state: state),
            const Divider(height: 24),
            FutureBuilder<TransportMenu?>(
              future: _menu,
              builder: (context, snapshot) {
                final menu = snapshot.data;
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (menu == null) {
                  return const LText('这个标签不是 SSH 或 Mosh，没有可切换的方式。');
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _switchTile(session, menu, progress),
                    if (menu.setDefault case final option?)
                      _defaultTile(session, option),
                    _tmuxTile(session, state),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchTile(
    ActiveTerminalSession session,
    TransportMenu menu,
    TransportSwitchProgress? progress,
  ) {
    final option = menu.switchTo;
    final to = option.to.label;
    final tmux = session.tmux?.target;
    final how = progress != null
        ? progress.describe()
        : option.blocked ??
            (option.inPlace
                ? option.to == TabTransport.mosh
                    ? '在这条 SSH 上起 mosh-server，附着同一个 tmux 会话 ${tmux!.displayName}（${tmux.sessionId}），'
                        '核对过才换过去，然后关掉这条 SSH。不重发任何输入。'
                    : '重新登录 SSH，附着同一个 tmux 会话 ${tmux!.displayName}（${tmux.sessionId}），'
                        '核对过才换过去，然后关掉 Mosh。不重发任何输入。'
                : '另开一个 $to 标签（新的 shell），这个标签和里面的 shell 不动。');
    return ListTile(
      key: const ValueKey('transport-switch'),
      contentPadding: EdgeInsets.zero,
      enabled: option.blocked == null && progress == null,
      leading: Icon(
        option.to == TabTransport.mosh
            ? Icons.bolt_outlined
            : Icons.lan_outlined,
      ),
      title: LText(option.inPlace ? '切换到 $to（同一个 tmux 会话）' : '用 $to 另开一个'),
      subtitle: LText(how),
      trailing: progress == null
          ? null
          : TextButton(
              key: const ValueKey('transport-switch-cancel'),
              onPressed: () => ref
                  .read(sessionControllerProvider.notifier)
                  .cancelSwitch(session.id),
              child: const LText('取消'),
            ),
      onTap: () => unawaited(_switch(session, option)),
    );
  }

  Widget _defaultTile(
    ActiveTerminalSession session,
    DefaultTransportOption option,
  ) =>
      ListTile(
        key: const ValueKey('transport-set-default'),
        contentPadding: EdgeInsets.zero,
        enabled: option.blocked == null,
        leading: const Icon(Icons.push_pin_outlined),
        title: LText('把 ${option.transport.label} 设为这台主机的默认'),
        subtitle: LText(
          option.blocked ??
              '以后从主机列表连这台都用 ${option.transport.label}。开着的标签不变，Mosh 的端口、路径设置照旧留着。',
        ),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          final navigator = Navigator.of(context);
          try {
            await ref
                .read(sessionControllerProvider.notifier)
                .setDefaultTransport(session.id);
            navigator.pop();
            messenger.showSnackBar(SnackBar(
              content: LText('已把 ${option.transport.label} 设为这台主机的默认'),
            ));
          } catch (error) {
            messenger.showSnackBar(SnackBar(content: LText('$error')));
          }
        },
      );

  /// 「选 tmux 会话」：用这台主机上一个连着的 SSH 标签只读地列出会话，选了在新标签里附着（R21 规则）。
  /// Mosh 标签自己查不了（它没有 SSH 通道），有同主机的 SSH 标签就借它的。
  Widget _tmuxTile(ActiveTerminalSession session, SessionState state) {
    final via = _sshTabOnSameHost(state, session);
    return ListTile(
      key: const ValueKey('transport-pick-tmux'),
      contentPadding: EdgeInsets.zero,
      enabled: via != null,
      leading: const Icon(Icons.view_quilt_outlined),
      title: const LText('选 tmux 会话…'),
      subtitle: LText(
        via == null
            ? '要先有一个连着的 SSH 标签才能列出这台主机上的 tmux 会话（Mosh 标签自己查不了）。'
            : '只读列出会话，选了在新标签里附着；按完整身份核对，不按名字、不新建。',
      ),
      onTap: via == null
          ? null
          : () {
              final navigator = Navigator.of(context);
              navigator.pop();
              unawaited(showModalBottomSheet<void>(
                context: navigator.context,
                useSafeArea: true,
                isScrollControlled: true,
                builder: (_) => TmuxPickerSheet(session: via),
              ));
            },
    );
  }

  Future<void> _switch(
    ActiveTerminalSession session,
    TransportSwitchOption option,
  ) async {
    final controller = ref.read(sessionControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // 菜单关掉以后还要弹安装提示、指纹框、键盘交互框：用弹出菜单的那一层，不用菜单自己的 context。
    // 用菜单的 context 的话，「另开一个」先收了菜单，新主机的指纹框就弹不出来、按拒绝处理。
    final hostContext = navigator.context;
    final verifyHostKey = hostKeyVerifier(hostContext);
    final keyboardInteractive = keyboardInteractivePrompt(hostContext);
    var stopping = const <String>{};
    // 从 SSH 原地切到 Mosh 会关掉这条 SSH：挂在它上面的端口转发先列出来，用户确认了才切。
    if (option.inPlace && option.to == TabTransport.mosh) {
      final forwards =
          ref.read(portForwardControllerProvider.notifier).forwardsOn(session);
      if (forwards.isNotEmpty) {
        final ok = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                key: const ValueKey('transport-forwards-confirm'),
                icon: const Icon(Icons.warning_amber_outlined),
                title: const LText('这些端口转发会停掉'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LText('切到 Mosh 后这条 SSH 会关掉，上面的 ${forwards.length} 条转发跟着停：'),
                    const SizedBox(height: 8),
                    for (final item in forwards)
                      Text('• ${item.describe()}',
                          style: const TextStyle(fontFamily: 'monospace')),
                    const SizedBox(height: 8),
                    const LText('Mosh 不带端口转发。要留着它们就别切，或者另开一个 SSH 标签重新开转发。'),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const LText('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const LText('停掉并切换'),
                  ),
                ],
              ),
            ) ??
            false;
        if (!ok || !mounted) return;
        stopping = {for (final item in forwards) item.id};
      }
    }
    // 普通标签另开一个：菜单先收起来，等待卡片显示进度和失败原因。原地切换：菜单留着看进度、能取消。
    if (!option.inPlace) navigator.pop();
    try {
      final done = await controller.switchTransport(
        session.id,
        verifyHostKey: verifyHostKey,
        keyboardInteractive: keyboardInteractive,
        stoppingForwards: stopping,
      );
      if (option.inPlace && done) {
        if (mounted) navigator.pop();
        messenger.showSnackBar(SnackBar(
          content: LText('已切到 ${option.to.label}，还是同一个 tmux 会话'),
        ));
      }
    } on MoshServerMissing catch (error) {
      if (option.inPlace && mounted) navigator.pop();
      if (!hostContext.mounted) return;
      unawaited(showMoshInstallHint(
        hostContext,
        hint: error.hint,
        hostId: sourceHostIdOf(session.host),
      ));
    } catch (error) {
      // 另开的失败等待卡片里已经写了；原地切换的失败只有这里说。
      if (!option.inPlace) return;
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: LText('没有切换，原来的连接不变：$error'),
      ));
      if (mounted) setState(_load);
    }
  }
}

/// 同一台保险库主机上一个连着的 SSH 标签：优先就是 [session] 自己。
ActiveTerminalSession? _sshTabOnSameHost(
  SessionState state,
  ActiveTerminalSession session, {
  String? hostId,
}) {
  final id = hostId ?? sourceHostIdOf(session.host);
  bool usable(ActiveTerminalSession value) =>
      value.connected &&
      value.isSsh &&
      value.sshClient != null &&
      sourceHostIdOf(value.host) == id;
  if (usable(session)) return session;
  return state.sessions.where(usable).firstOrNull;
}

class _Facts extends StatelessWidget {
  const _Facts({required this.session, required this.state});

  final ActiveTerminalSession session;
  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final host = session.host;
    final transport = transportOf(session);
    final tmux = session.tmux?.target ?? session.resumeTmux;
    final progress = state.switching[session.id];
    final recovering = state.recovering.contains(session.id);
    final status = progress != null
        ? progress.describe()
        : session.connected
            ? '已连接'
            : recovering
                ? tmux == null
                    ? '正在自动恢复…'
                    : '正在重新附着…'
                : '已断开 · 终端里是断开前的画面（历史）';
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${host.label} · ${transport?.label ?? host.protocol.name}',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        Text('${host.username}@${host.hostname}:${host.port}', style: small),
        const SizedBox(height: 4),
        LText(
          tmux == null
              ? '普通 shell：跟着这条连接走，断了就没了；切换会另开一个标签。'
              : 'tmux 会话 ${tmux.displayName}（${tmux.sessionId}）· ${tmux.unixUser}@${tmux.hostKey} · ${tmux.socket.describe()}',
          style: small,
        ),
        LText('状态：$status',
            key: const ValueKey('transport-status'), style: small),
      ],
    );
  }
}

/// 只读的 tmux 会话选择（R42 「选会话」）。只查默认 socket（或这个标签正附着的那个），不启动 server、
/// 不新建、不结束；选了就按完整目标在新标签里附着，远端核对不过就停。要新建、结束、换 socket，
/// 到「系统管理 → tmux」。
class TmuxPickerSheet extends ConsumerStatefulWidget {
  const TmuxPickerSheet({super.key, required this.session});

  final ActiveTerminalSession session;

  @override
  ConsumerState<TmuxPickerSheet> createState() => _TmuxPickerSheetState();
}

class _TmuxPickerSheetState extends ConsumerState<TmuxPickerSheet> {
  late final TmuxSocketSpec _socket =
      widget.session.tmux?.target.socket ?? const TmuxSocketSpec.standard();
  late Future<TmuxProbe> _probe = _load();

  Future<TmuxProbe> _load() {
    final client = widget.session.sshClient;
    if (!widget.session.connected || client == null) {
      return Future.error(const TmuxCommandException('这个 SSH 标签已经断开了。'));
    }
    return ref.read(tmuxServiceProvider).probe(client, _socket);
  }

  String _availability(TmuxProbe probe) => switch (probe.availability) {
        TmuxAvailability.missing => '这台服务器上没有 tmux。',
        TmuxAvailability.unsupported =>
          'tmux 版本不在实测范围（${probe.versionLine}），不列会话。',
        TmuxAvailability.noServer => '${_socket.describe()} 上现在没有 tmux 会话。',
        TmuxAvailability.ready => '',
        _ => probe.problem ?? '读不出 tmux 会话列表。',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: LText('选 tmux 会话', style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: localized('刷新'),
                  onPressed: () => setState(() => _probe = _load()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            LText(
              '${widget.session.host.username}@${tmuxHostKeyOf(widget.session)} · ${_socket.describe()}。'
              '只读列出；要新建、结束或换 socket，用「系统管理 → tmux」。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: FutureBuilder<TmuxProbe>(
                future: _probe,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return LText('列不出来：${snapshot.error}');
                  }
                  final probe = snapshot.data;
                  if (probe == null) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (probe.availability != TmuxAvailability.ready ||
                      probe.uid == null) {
                    return LText(_availability(probe));
                  }
                  if (probe.sessions.isEmpty) {
                    return const LText('没有 tmux 会话。');
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      for (final row in probe.sessions)
                        ListTile(
                          key: ValueKey('tmux-pick-${row.sessionId}'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.view_quilt_outlined),
                          title: Text(row.name),
                          subtitle: LText(
                            row.attached > 0
                                ? '${row.sessionId} · ${row.windows} 个窗口 · 已有 ${row.attached} 个客户端附着'
                                : '${row.sessionId} · ${row.windows} 个窗口',
                          ),
                          onTap: () => _attach(targetOf(
                            row,
                            hostKey: tmuxHostKeyOf(widget.session),
                            unixUser: probe.unixUser,
                            uid: probe.uid!,
                            socket: _socket,
                          )),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _attach(TmuxTarget target) async {
    final controller = ref.read(sessionControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    try {
      await controller.openTmuxTerminal(widget.session, target);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: LText('$error')));
    }
  }
}

/// 服务器上没有 mosh-server（R42）：给这台服务器发行版对应的安装、卸载命令。
/// 三种用法：复制；「填进 SSH 标签」只粘贴不回车；「安装…」先弹确认框讲清楚会发生什么，确认了才新开
/// 一个 SSH 标签去执行（所有者 2026-10-17 同意）。sudo 的密码始终是用户在终端里自己输，App 不经手。
Future<void> showMoshInstallHint(
  BuildContext context, {
  required MoshInstallHint hint,
  required String hostId,
}) =>
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => MoshInstallHintSheet(hint: hint, hostId: hostId),
    );

/// 装好以后服务器和防火墙要放行的 UDP 端口：这台主机填的范围，没填是 mosh 默认的 60001–60999。
String _udpPorts(HostProfile? host) {
  var range = MoshBootstrap.defaultPortRange;
  if (host != null) {
    try {
      range = moshServerOptionsOf(host).portRange;
    } on Object {
      // 端口写错了：连接时会单独报，这里先按默认说。
    }
  }
  final (low, high) = range;
  return low == high ? 'UDP $low' : 'UDP $low–$high';
}

class MoshInstallHintSheet extends ConsumerWidget {
  const MoshInstallHintSheet({
    super.key,
    required this.hint,
    required this.hostId,
  });

  final MoshInstallHint hint;
  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(sessionControllerProvider);
    final host = ref
        .watch(vaultControllerProvider)
        .data
        ?.hosts
        .where((value) => value.id == hostId)
        .firstOrNull;
    // 按登录用户调整过的命令：复制、填进、安装用的都是这一条，用户看到的就是会跑的。
    final user = host?.username ?? '';
    final command = hint.runAs(hint.command, user: user);
    final uninstall = hint.runAs(hint.uninstall, user: user);
    final ports = _udpPorts(host);
    final target = state.sessions
        .where((value) =>
            value.connected &&
            value.isSsh &&
            sourceHostIdOf(value.host) == hostId)
        .firstOrNull;
    final small = theme.textTheme.bodySmall;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LText('服务器上没有 mosh-server', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            LText('认出来的系统：${hint.distro}'),
            const SizedBox(height: 8),
            if (command != null) ...[
              LText(
                command.contains('sudo ')
                    ? '在服务器上执行这一条。要管理员权限：sudo 会在终端里问你的密码。'
                    : '在服务器上执行这一条：',
              ),
              const SizedBox(height: 4),
              _CommandBox(command, key: const ValueKey('mosh-install-command')),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('mosh-install-run'),
                    onPressed: () =>
                        _install(context, ref, command, uninstall, ports),
                    icon: const Icon(Icons.download_outlined),
                    label: const LText('安装…'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('mosh-install-copy'),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(ClipboardData(text: command));
                      messenger.showSnackBar(
                        const SnackBar(content: LText('已复制安装命令')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const LText('复制'),
                  ),
                  if (target != null)
                    OutlinedButton.icon(
                      key: const ValueKey('mosh-install-paste'),
                      onPressed: () {
                        final controller =
                            ref.read(sessionControllerProvider.notifier);
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          controller.pasteInto(target, command);
                          final index = ref
                              .read(sessionControllerProvider)
                              .sessions
                              .indexOf(target);
                          if (index >= 0) controller.activate(index);
                          Navigator.of(context).pop();
                          // 刚点过「复制」的话那条提示还在：先收掉，不然这条要排 4 秒才出来。
                          messenger.hideCurrentSnackBar();
                          messenger.showSnackBar(const SnackBar(
                            content: LText('已填进 SSH 标签，没有回车。看过再自己按回车。'),
                          ));
                        } catch (error) {
                          messenger
                              .showSnackBar(SnackBar(content: LText('$error')));
                        }
                      },
                      icon: const Icon(Icons.keyboard_outlined),
                      label: const LText('填进 SSH 标签（不回车）'),
                    ),
                ],
              ),
            ],
            if (hint.note case final note?) ...[
              const SizedBox(height: 8),
              LText(note, style: small),
            ],
            const SizedBox(height: 12),
            LText(
              '装好以后，服务器防火墙（和云服务器的安全组）要放行 $ports，再重新连接或切换。',
              style: small,
            ),
            if (uninstall != null) ...[
              const SizedBox(height: 4),
              LText('以后不用了，卸载：', style: small),
              _CommandBox(uninstall,
                  key: const ValueKey('mosh-uninstall-command')),
            ],
            const SizedBox(height: 4),
            LText(
              '安装、卸载、清理服务器上剩下的东西，完整步骤见使用手册《Mosh 使用指南》。',
              style: small,
            ),
          ],
        ),
      ),
    );
  }

  /// 确认框把会发生的事一次说清：在哪执行、执行什么、密码谁来输、装完还要做什么、以后怎么卸。
  /// 确认了才新开 SSH 标签执行；取消就什么都不发。
  Future<void> _install(
    BuildContext context,
    WidgetRef ref,
    String command,
    String? uninstall,
    String ports,
  ) async {
    final controller = ref.read(sessionControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // 确认后先收起这个提示再开标签：指纹框、键盘交互框要弹在下面那一层（理由同 [TransportSheet] 的切换）。
    final verifyHostKey = hostKeyVerifier(navigator.context);
    final keyboardInteractive = keyboardInteractivePrompt(navigator.context);
    final host = ref
        .read(vaultControllerProvider)
        .data
        ?.hosts
        .where((value) => value.id == hostId)
        .firstOrNull;
    final label = host?.label ?? '';
    final small = Theme.of(context).textTheme.bodySmall;
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            key: const ValueKey('mosh-install-confirm'),
            icon: const Icon(Icons.download_outlined),
            title: const LText('在服务器上安装 mosh？'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LText('会新开一个 SSH 标签「安装 mosh · $label」，登录这台主机后执行：'),
                  const SizedBox(height: 4),
                  _CommandBox(command),
                  const SizedBox(height: 8),
                  if (command.contains('sudo '))
                    LText(
                      '要管理员权限：sudo 会在那个终端里问你的密码，你自己输。App 看不到、也不保存这个密码。'
                      '服务器上没有 sudo 的，会报「sudo: not found」：用 root 登录再装，或者自己换成 doas。',
                      style: small,
                    ),
                  LText(
                    'mosh 从这台服务器自己配的软件源下载，服务器要能上网。包管理器问「要不要继续」时，也在那个终端里回答。'
                    '标签断线恢复时不会再执行一次。',
                    style: small,
                  ),
                  const SizedBox(height: 6),
                  LText(
                    '装完还要在服务器防火墙（和云服务器的安全组）里放行 $ports，否则 Mosh 连不上。',
                    style: small,
                  ),
                  const SizedBox(height: 6),
                  LText(
                    uninstall == null
                        ? '以后不用了怎么卸载、怎么清理，见使用手册《Mosh 使用指南》。'
                        : '以后不用了：用「$uninstall」卸掉，再把放行的端口关回去；完整步骤见使用手册《Mosh 使用指南》。',
                    style: small,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                key: const ValueKey('mosh-install-confirm-run'),
                onPressed: () => Navigator.pop(context, true),
                child: const LText('打开 SSH 标签并安装'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    if (navigator.canPop()) navigator.pop();
    try {
      await controller.openMoshInstallTerminal(
        hostId: hostId,
        command: command,
        verifyHostKey: verifyHostKey,
        keyboardInteractive: keyboardInteractive,
      );
    } catch (error) {
      messenger
          .showSnackBar(SnackBar(content: LText('没能打开安装用的 SSH 标签：$error')));
    }
  }
}

class _CommandBox extends StatelessWidget {
  const _CommandBox(this.command, {super.key});

  final String command;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          command,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      );
}
