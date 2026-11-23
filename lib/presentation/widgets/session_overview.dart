import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../application/home_navigation.dart';
import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/host_identity.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import '../../infrastructure/terminal/terminal_text.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import '../ui/prism_theme.dart';
import 'empty_state.dart';
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

/// 在终端页两指往上滑出来的一层（F35，手势和大小所有者 11-01 改过）：所有开着的会话按机器分组，
/// 机器多了 tab 条能滑，每台机器的会话是一排小卡片。点卡片切过去。
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
    final confirmed = switch (window) {
      _Window(:final session?) => confirmCloseSession(context, session),
      _Window(:final pending?) => confirmClosePending(context, pending),
      _ => Future.value(false),
    };
    if (!await confirmed || !mounted) return;
    _stayOn(sourceHostIdOf(window.host));
    await _closeTabs([window]);
  }

  /// 机器 tab 上的 ×。只有一个标签就和卡片上的 × 问一样的话：那句写得最准。
  Future<void> _closeMachine(_Machine machine) async {
    final windows = [...machine.windows];
    if (windows.length == 1) return _closeWindow(windows.single);
    final confirmed = await confirmCloseMachine(
      context,
      name: machine.name,
      sessions: [
        for (final window in windows)
          if (window.session case final session?) session,
      ],
      pending: [
        for (final window in windows)
          if (window.pending case final pending?) pending,
      ],
    );
    if (!confirmed || !mounted) return;
    await _closeTabs(windows);
  }

  /// 关掉正在看的那个标签，当前会话会换到别的机器：没选过 tab 的话总览跟着跳走，这台剩下的卡片就看不见了。
  void _stayOn(String machineId) => setState(() => _machineId = machineId);

  /// 对话框开着的时候别的标签可能关了，下标按 ID 重新找。[SessionController.close] 先改界面再慢慢关连接，
  /// 所以一次全改完再等：等着上一个关完再关下一个的话，总览这时被收起来，剩下的就没人关了。
  Future<void> _closeTabs(List<_Window> windows) async {
    final controller = ref.read(sessionControllerProvider.notifier);
    final closing = <Future<void>>[];
    for (final window in windows) {
      final index = ref
          .read(sessionControllerProvider)
          .sessions
          .indexWhere((value) => value.id == window.id);
      if (index >= 0) {
        closing.add(controller.close(index));
      } else {
        // 各自只认自己那种状态：对话框开着时连接可能刚失败。
        controller
          ..dismissPending(window.id)
          ..cancelPendingConnection(window.id);
      }
    }
    await Future.wait(closing);
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
    final colors = prism.Theme.of(context).colorScheme;
    // 面板落在页面那一层，卡片和胶囊各高一层：层次靠底色，不靠描边。
    const level = prism.SurfaceLevel.page;
    // 只占底下一截：上面还看得见终端，点那里就关。
    return SafeArea(
      child: Material(
        key: const ValueKey('session-overview'),
        color: level.colorOf(colors),
        clipBehavior: Clip.antiAlias,
        shape: prism.AppShape.top(prism.AppCorner.xxl),
        child: prism.SurfaceScope(
          level: level,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: LText(
                        '会话总览',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: prism.AppTextStyle.title3
                            .of(context, emphasized: true)
                            .copyWith(color: colors.onSurface),
                      ),
                    ),
                    if (waiting.length > 1)
                      ShunButton(
                        key: const ValueKey('overview-reconnect-all'),
                        kind: ShunButtonKind.text,
                        label: '全部重连',
                        onPressed: () => _reconnect(waiting),
                      ),
                    ShunBarButton(
                      key: const ValueKey('overview-close'),
                      icon: Icons.close,
                      tooltip: localized('关闭'),
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
              ),
              if (selected == null)
                const EmptyState(
                  icon: Icons.terminal_outlined,
                  title: '没有打开的会话',
                )
              else ...[
                // 机器一台一个胶囊，主色只给选中的那台。机器不多，全部建出来：选中的那台才能滚进来。
                SingleChildScrollView(
                  key: const ValueKey('overview-machines'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      for (final machine in machines)
                        _MachineChip(
                          key: ValueKey('overview-machine-${machine.id}'),
                          machine: machine,
                          selected: machine == selected,
                          onSelect: () =>
                              setState(() => _machineId = machine.id),
                          onClose: () => _closeMachine(machine),
                        ),
                    ],
                  ),
                ),
                // 外层不做横滑：卡片已经在左右滑了，两层都滑的话手指到头就切了机器，分不清在翻什么。
                // Flexible：横屏弹着键盘时放不下整张卡，卡片跟着矮，不溟出。
                Flexible(
                  child: SizedBox(
                    height: _cardRowHeight,
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
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 一台机器的胶囊：名字（多于一个标签时带数量）和关掉这台全部会话的 ×。
///
/// 胶囊看着 40dp 高，× 的点按区仍是 48dp：它叠在胶囊右端，不算在胶囊的高度里。
class _MachineChip extends StatefulWidget {
  const _MachineChip({
    super.key,
    required this.machine,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  final _Machine machine;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  State<_MachineChip> createState() => _MachineChipState();
}

class _MachineChipState extends State<_MachineChip> {
  @override
  void initState() {
    super.initState();
    if (widget.selected) _reveal();
  }

  @override
  void didUpdateWidget(_MachineChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && !oldWidget.selected) _reveal();
  }

  /// 机器多到一行放不下时，选中的那台滚进来。
  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Scrollable.ensureVisible(context, alignment: .5);
      });

  @override
  Widget build(BuildContext context) {
    final machine = widget.machine;
    final colors = prism.Theme.of(context).colorScheme;
    final foreground = widget.selected ? colors.onPrimary : colors.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Stack(
          alignment: Alignment.centerRight,
          children: [
            prism.PressSurface(
              fill: widget.selected
                  ? colors.primary
                  : prism.SurfaceContext(context)
                      .raisedSurfaceLevel
                      .colorOf(colors),
              shape: prism.AppShape.full,
              inkColor: foreground,
              selected: widget.selected,
              minimum: const BoxConstraints(minHeight: 40),
              // 右边那一截是 × 的位置。
              padding: const EdgeInsets.only(left: 16, right: 44),
              onPressed: widget.onSelect,
              child: Text(
                machine.windows.length > 1
                    ? '${machine.name} · ${machine.windows.length}'
                    : machine.name,
                maxLines: 1,
                style: prism.AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .copyWith(color: foreground),
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: IconButton(
                key: ValueKey('overview-close-machine-${machine.id}'),
                tooltip: localized('关闭“${machine.name}”的全部会话'),
                iconSize: 18,
                color: foreground,
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
              ),
            ),
          ],
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

/// 小卡片（所有者 11-01：原来一张占满屏，太大）。392dp 宽的手机上一屏放得下两张多，露出半张就知道还能滑。
const _cardWidth = 156.0;
const _cardRowHeight = 196.0;

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
  // 开在当前会话那张；超出可滑范围时列表自己回弹到头。
  late final _scroll = ScrollController(
    initialScrollOffset: widget.machine.windows
            .indexWhere((window) => window.tabIndex == widget.activeTabIndex)
            .clamp(0, widget.machine.windows.length - 1) *
        _cardWidth,
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
        key: const ValueKey('overview-windows'),
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemExtent: _cardWidth,
        itemCount: widget.machine.windows.length,
        itemBuilder: (context, index) {
          final window = widget.machine.windows[index];
          return _WindowCard(
            key: ValueKey('overview-window-${window.id}'),
            window: window,
            title: _title(window),
            state: widget.state,
            active: window.tabIndex == widget.activeTabIndex,
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
    required this.active,
    required this.onOpen,
    required this.onClose,
    required this.onReconnect,
  });

  final _Window window;
  final String title;
  final SessionState state;

  /// 现在在看的那个标签。一屏几张卡片，要分得出来。
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback onClose;
  final ValueChanged<ActiveTerminalSession> onReconnect;

  @override
  Widget build(BuildContext context) {
    final session = window.session;
    final pending = window.pending;
    final failed = pending?.phase == PendingConnectionPhase.failed;
    final colors = prism.Theme.of(context).colorScheme;
    final level = prism.SurfaceContext(context).raisedSurfaceLevel;
    final fill = level.colorOf(colors);
    final note = prism.AppTextStyle.footnote
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      // 当前那张不描边：底色带一层主色，名字也用主色。
      child: prism.PressSurface(
        fill: active
            ? Color.alphaBlend(colors.primary.withValues(alpha: .16), fill)
            : fill,
        shape: prism.AppShape.md,
        selected: active,
        childFills: true,
        clipsChild: true,
        onPressed: onOpen,
        child: prism.SurfaceScope(
          level: level,
          // 里面的 × 和按钮是 Material 的：水波纹画在这一层，不会被卡片的底色盖住。
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 10),
                    _statusIcon(session, failed, colors),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // 名字靠末尾的序号分得开彼此，字再大就被截掉了。
                        style: prism.AppTextStyle.caption1
                            .of(context, emphasized: true)
                            .copyWith(
                              color: active ? colors.primary : colors.onSurface,
                            ),
                      ),
                    ),
                    // 还在连的也给关（所有者 11-01）：点了先问，确认才终止，不会误触。
                    IconButton(
                      key: ValueKey('overview-close-${window.id}'),
                      tooltip: localized('关闭标签“${window.host.label}”'),
                      iconSize: 18,
                      color: colors.onSurfaceVariant,
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Expanded(
                  child: session != null
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                          child: _Preview(
                            key: ValueKey('overview-preview-${session.id}'),
                            terminal: session.terminal,
                          ),
                        )
                      : Center(
                          child: LText(
                            failed ? '连接失败' : '正在连接…',
                            style: failed
                                ? note.copyWith(color: colors.error)
                                : note,
                          ),
                        ),
                ),
                if (session != null && state.recovering.contains(session.id))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                    child: LText(
                      '正在恢复连接…',
                      textAlign: TextAlign.center,
                      style: note,
                    ),
                  )
                else if (session != null && _canReconnect(session, state))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 2),
                    child: ShunButton(
                      key: ValueKey('overview-reconnect-${session.id}'),
                      kind: ShunButtonKind.tonal,
                      label: '重新连接',
                      onPressed: () => onReconnect(session),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 和标签条同一套：绿点、橙色叹号不只靠颜色，读屏也要知道断没断。
  Widget _statusIcon(
    ActiveTerminalSession? session,
    bool failed,
    prism.ColorScheme colors,
  ) {
    if (session == null) {
      return failed
          ? Icon(Icons.error_outline, size: 17, color: colors.error)
          : const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            );
    }
    return Icon(
      session.connected ? Icons.circle : Icons.error_outline,
      size: session.connected ? 10 : 16,
      color: ShunStatusColors.link(connected: session.connected),
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
        maxLines: 24,
        maxColumns: 80,
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
    // 终端快照是内容，不跟主题走：深底浅字，嵌在卡片里的一块。
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: const Color(0xFF12161B),
        shape: prism.AppShape.all(10),
      ),
      child: empty
          ? Center(
              child: LText(
                '还没有输出',
                style: prism.AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: color),
              ),
            )
          : ClipRect(
              child: Padding(
                padding: const EdgeInsets.all(5),
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
                      fontSize: 7,
                      height: 1.2,
                      color: color,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
