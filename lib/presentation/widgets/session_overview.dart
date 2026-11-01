import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/home_navigation.dart';
import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/host_identity.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import '../../infrastructure/terminal/terminal_text.dart';
import '../localization/localized_widgets.dart';
import 'session_tab_actions.dart';

/// 总览里的一张卡：一个标签，连着的会话，或者还在连、连失败的。
class _Window {
  const _Window(this.tabIndex, this.host, {this.session, this.pending});

  /// [SessionController.activate] 用的下标。
  final int tabIndex;
  final HostProfile host;
  final ActiveTerminalSession? session;
  final PendingTerminalConnection? pending;

  String get id => session?.id ?? pending!.id;
}

class _Machine {
  _Machine(this.id, this.name);

  final String id;
  final String name;
  final windows = <_Window>[];
}

/// 按机器分组。临时标签（tmux、AI 工具）拿的是主机的拷贝，按来源主机算同一台。
List<_Machine> _machines(SessionState state, List<HostProfile> hosts) {
  final names = {for (final host in hosts) host.id: host.label};
  final machines = <String, _Machine>{};
  void add(_Window window) {
    final id = sourceHostIdOf(window.host);
    machines
        .putIfAbsent(id, () => _Machine(id, names[id] ?? window.host.label))
        .windows
        .add(window);
  }

  for (final (index, session) in state.sessions.indexed) {
    add(_Window(index, session.host, session: session));
  }
  for (final (index, pending) in state.pendingConnections.indexed) {
    add(_Window(state.sessions.length + index, pending.host, pending: pending));
  }
  return machines.values.toList();
}

/// 从底栏「终端」往上滑出来的一层（F35）：所有开着的会话按机器分组，机器多了 tab 条能滑，
/// 每台机器的会话左右滑着看。点卡片切过去。
///
/// 预览是文字快照：一个终端只能挂一个视图（单 view 约束），这里再挂一个会抢走终端页的画面和尺寸。
class SessionOverview extends ConsumerStatefulWidget {
  const SessionOverview({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<SessionOverview> createState() => _SessionOverviewState();
}

class _SessionOverviewState extends ConsumerState<SessionOverview> {
  String? _machineId;

  void _open(_Window window) {
    ref.read(sessionControllerProvider.notifier).activate(window.tabIndex);
    ref.read(homeTabProvider.notifier).state = 1;
    widget.onClose();
  }

  Future<void> _closeWindow(_Window window) async {
    final controller = ref.read(sessionControllerProvider.notifier);
    final session = window.session;
    if (session == null) {
      controller.dismissPending(window.id);
      return;
    }
    if (!await confirmCloseSession(context, session) || !mounted) return;
    // 对话框开着的时候别的标签可能关了，下标要重新找。
    final index = ref
        .read(sessionControllerProvider)
        .sessions
        .indexWhere((value) => value.id == session.id);
    if (index >= 0) await controller.close(index);
  }

  /// 一个接一个连：同时连的话，指纹、密码框会叠在一起，分不清是哪台在问。
  ///
  /// 点完重连接着点卡片切过去很常见，总览这时就收了：问答挂在 Navigator 这一层才弹得出来，
  /// 挂在总览自己的 context 上会按拒绝处理，连接莫名失败。总览收了，没连的也接着连。
  Future<void> _reconnect(List<ActiveTerminalSession> sessions) async {
    final prompts = Navigator.of(context).context;
    final controller = ref.read(sessionControllerProvider.notifier);
    for (final session in sessions) {
      if (!prompts.mounted) return;
      await reconnectSession(prompts, controller, session);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionControllerProvider);
    final hosts =
        ref.watch(vaultControllerProvider).data?.hosts ?? const <HostProfile>[];
    final machines = _machines(state, hosts);
    final activeIndex = state.activePendingId == null
        ? state.activeIndex
        : state.sessions.length +
            state.pendingConnections
                .indexWhere((value) => value.id == state.activePendingId);
    final selected = machines
            .where((machine) => machine.id == _machineId)
            .firstOrNull ??
        machines
            .where((machine) =>
                machine.windows.any((window) => window.tabIndex == activeIndex))
            .firstOrNull ??
        machines.firstOrNull;
    final waiting = [
      for (final session in state.sessions)
        if (_canReconnect(session, state)) session,
    ];
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        // 顶上露一条背后的页面：知道这是盖在上面的一层，点那里就关。
        padding: const EdgeInsets.only(top: 40),
        child: Material(
          key: const ValueKey('session-overview'),
          color: theme.colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: LText('会话总览', style: theme.textTheme.titleMedium),
                    ),
                    if (waiting.length > 1)
                      TextButton(
                        key: const ValueKey('overview-reconnect-all'),
                        onPressed: () => _reconnect(waiting),
                        child: const LText('全部重连'),
                      ),
                    IconButton(
                      key: const ValueKey('overview-close'),
                      tooltip: localized('关闭'),
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (selected == null)
                const Expanded(child: Center(child: LText('没有打开的会话')))
              else ...[
                // 机器里少了、多了就换一个控制器，起始位置设成现在选的那台。
                DefaultTabController(
                  key: ValueKey(machines.map((m) => m.id).join('\n')),
                  length: machines.length,
                  initialIndex: machines.indexOf(selected),
                  child: TabBar(
                    key: const ValueKey('overview-machines'),
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    onTap: (index) =>
                        setState(() => _machineId = machines[index].id),
                    tabs: [
                      for (final machine in machines)
                        Tab(
                          key: ValueKey('overview-machine-${machine.id}'),
                          text: machine.windows.length > 1
                              ? '${machine.name} · ${machine.windows.length}'
                              : machine.name,
                        ),
                    ],
                  ),
                ),
                // 外层不做横滑：卡片已经在左右滑了，两层都滑的话手指到头就切了机器，分不清在翻什么。
                Expanded(
                  child: _WindowPager(
                    key: ValueKey('overview-pager-${selected.id}'),
                    machine: selected,
                    activeTabIndex: activeIndex,
                    state: state,
                    onOpen: _open,
                    onClose: _closeWindow,
                    onReconnect: (session) => _reconnect([session]),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 能不能点「重新连接」。AI tmux 标签不算：它要从最近工作入口核对原窗格后返回，点卡片进去看原因。
bool _canReconnect(ActiveTerminalSession session, SessionState state) =>
    !session.connected &&
    !session.closedByUser &&
    session.aiTmuxRun == null &&
    !state.recovering.contains(session.id);

class _WindowPager extends StatefulWidget {
  const _WindowPager({
    super.key,
    required this.machine,
    required this.activeTabIndex,
    required this.state,
    required this.onOpen,
    required this.onClose,
    required this.onReconnect,
  });

  final _Machine machine;
  final int activeTabIndex;
  final SessionState state;
  final ValueChanged<_Window> onOpen;
  final ValueChanged<_Window> onClose;
  final ValueChanged<ActiveTerminalSession> onReconnect;

  @override
  State<_WindowPager> createState() => _WindowPagerState();
}

class _WindowPagerState extends State<_WindowPager> {
  // 两边露出一点相邻的卡：一眼看得出还能滑。
  late final _pages = PageController(
    viewportFraction: .86,
    initialPage: widget.machine.windows
        .indexWhere((window) => window.tabIndex == widget.activeTabIndex)
        .clamp(0, widget.machine.windows.length - 1),
  );

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageView.builder(
        key: const ValueKey('overview-windows'),
        controller: _pages,
        itemCount: widget.machine.windows.length,
        itemBuilder: (context, index) {
          final window = widget.machine.windows[index];
          return _WindowCard(
            key: ValueKey('overview-window-${window.id}'),
            window: window,
            title: _title(window),
            state: widget.state,
            onOpen: () => widget.onOpen(window),
            onClose: () => widget.onClose(window),
            onReconnect: widget.onReconnect,
          );
        },
      );

  /// tab 上已经是机器名了，卡片写分得开彼此的名字。
  String _title(_Window window) {
    final tmux = window.session?.tmux?.target.displayName;
    if (tmux != null) return 'tmux $tmux';
    final same = [
      for (final other in widget.machine.windows)
        if (other.session?.tmux == null &&
            other.host.label == window.host.label)
          other,
    ];
    return same.length > 1
        ? '${window.host.label} #${same.indexOf(window) + 1}'
        : window.host.label;
  }
}

class _WindowCard extends StatelessWidget {
  const _WindowCard({
    super.key,
    required this.window,
    required this.title,
    required this.state,
    required this.onOpen,
    required this.onClose,
    required this.onReconnect,
  });

  final _Window window;
  final String title;
  final SessionState state;
  final VoidCallback onOpen;
  final VoidCallback onClose;
  final ValueChanged<ActiveTerminalSession> onReconnect;

  @override
  Widget build(BuildContext context) {
    final session = window.session;
    final pending = window.pending;
    final failed = pending?.phase == PendingConnectionPhase.failed;
    return Card(
      margin: const EdgeInsets.fromLTRB(6, 8, 6, 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 12),
                _statusIcon(session, failed),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                // 还在连的不给关：和标签条一样，要停到等待页点「终止连接」。
                if (session != null || failed)
                  IconButton(
                    key: ValueKey('overview-close-${window.id}'),
                    tooltip: localized('关闭标签“${window.host.label}”'),
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  )
                else
                  const SizedBox(height: 48),
              ],
            ),
            Expanded(
              child: session != null
                  ? _Preview(
                      key: ValueKey('overview-preview-${session.id}'),
                      terminal: session.terminal,
                    )
                  : Center(
                      child: LText(failed ? '连接失败' : '正在连接…'),
                    ),
            ),
            if (session != null && state.recovering.contains(session.id))
              const Padding(
                padding: EdgeInsets.all(12),
                child: LText('正在恢复连接…', textAlign: TextAlign.center),
              )
            else if (session != null && _canReconnect(session, state))
              Padding(
                padding: const EdgeInsets.all(8),
                child: FilledButton.tonal(
                  key: ValueKey('overview-reconnect-${session.id}'),
                  onPressed: () => onReconnect(session),
                  child: const LText('重新连接'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 和标签条同一套：绿点、橙色叹号不只靠颜色，读屏也要知道断没断。
  Widget _statusIcon(ActiveTerminalSession? session, bool failed) {
    if (session == null) {
      return failed
          ? const Icon(Icons.error_outline, size: 17, color: Colors.redAccent)
          : const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            );
    }
    return Icon(
      session.connected ? Icons.circle : Icons.error_outline,
      size: session.connected ? 10 : 16,
      color: session.connected ? Colors.greenAccent : Colors.orangeAccent,
      semanticLabel: session.connected ? null : localized('已断开'),
    );
  }
}

/// 终端最近几十行的文字快照，累在底下。只在卡片显示着的时候每秒读一次，不存盘。
class _Preview extends StatefulWidget {
  const _Preview({super.key, required this.terminal});

  final TerminalSessionAdapter terminal;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  late String _text = _read();
  late final Timer _timer;

  String _read() => terminalPictureInPictureText(
        widget.terminal,
        maxLines: 40,
        maxColumns: 120,
      );

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = _read();
      if (next != _text) setState(() => _text = next);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFD7DBE0);
    // 终端内容不过翻译表：服务器输出里碰巧有表里的词，会被改掉。
    final empty = _text.isEmpty || _text == '等待终端输出…';
    return ColoredBox(
      color: const Color(0xFF12161B),
      child: empty
          ? Center(
              child: LText(
                '还没有输出',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: color),
              ),
            )
          : ClipRect(
              child: Padding(
                padding: const EdgeInsets.all(8),
                // 文字比卡片高时保留最后几行，比卡片宽时裁掉右边：和终端看到的一致。
                child: OverflowBox(
                  alignment: Alignment.bottomLeft,
                  maxHeight: double.infinity,
                  maxWidth: double.infinity,
                  child: Text(
                    _text,
                    softWrap: false,
                    textScaler: TextScaler.noScaling,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      height: 1.25,
                      color: color,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
