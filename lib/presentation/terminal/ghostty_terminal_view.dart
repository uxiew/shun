import 'dart:async';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../domain/terminal_link.dart';
import '../../infrastructure/terminal/ghostty_terminal_adapter.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import '../localization/localized_widgets.dart';
import '../widgets/terminal_link_sheet.dart';
import 'terminal_view.dart';

/// Ghostty 引擎的终端视图（R17）。除了测试，App 里只有这个文件和适配器认识 flterm。
///
/// 和 xterm2 视图一样只借用终端：挂载时占用显示权，销毁时释放（GST02）。
/// 不一样的是 flterm 一个控制器同一时刻只能挂一个 flterm 视图，第二个来挂直接抛 StateError，
/// 而 R16 的显示权换手时旧视图不会立刻重建。所以这里多一步交接：旧视图还挂着 flterm 视图时，
/// 新视图先空一帧、下一帧再挂；旧视图丢了显示权就尽快重建，把 flterm 视图卸下。
class GhosttyTerminalView extends StatefulWidget {
  const GhosttyTerminalView({
    super.key,
    required this.adapter,
    required this.options,
  });

  final GhosttyTerminalAdapter adapter;
  final TerminalViewOptions options;

  @override
  State<GhosttyTerminalView> createState() => _GhosttyTerminalViewState();
}

class _GhosttyTerminalViewState extends State<GhosttyTerminalView> {
  late TerminalViewLease _lease;
  var _showingEngine = false;
  var _rebuildScheduled = false;
  late bool _alternateScreen;
  late bool _hasSelection;

  /// 这次长按落在的链接（flterm 报的，OSC 8 链接的地址可能和屏幕上的字不一样）。
  /// 选区还在就在选字菜单里给「打开链接」，选区没了就忘掉。
  ActivatedLink? _longPressLink;

  /// 选中的字整段是网址时就是它。不在每次 build 里算：远端一直出字时 build 很勤，选区大的时候每次都要把整段格式化一遍。
  /// 选区只在手指操作（长按、拖、拖手柄、双击）和全选时变，所以在选区出现、消失和手指抬起后各算一次。
  String? _selectionUrl;
  var _selectionUrlScheduled = false;

  /// 交给 flterm 的焦点：从按键面板换回系统键盘时（[TerminalViewOptions.keyboardRequest]）要能让终端拿焦点。
  final _focusNode = FocusNode(debugLabel: 'ghostty-terminal');

  GhosttyTerminalAdapter get _adapter => widget.adapter;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _lease = _adapter.attachView();
    _alternateScreen = _adapter.isAlternateScreen;
    _hasSelection = false;
    _adapter.setFullscreenSwipe(widget.options.fullscreenSwipe);
    _adapter.addListener(_onTerminalChanged);
  }

  @override
  void didUpdateWidget(covariant GhosttyTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.adapter, widget.adapter)) {
      oldWidget.adapter.removeListener(_onTerminalChanged);
      _lease.release();
      _attach();
    } else if (oldWidget.options.fullscreenSwipe !=
        widget.options.fullscreenSwipe) {
      // 设置改了，开着的终端马上生效（不像引擎那样只管新开的）。
      _adapter.setFullscreenSwipe(widget.options.fullscreenSwipe);
    }
    final request = widget.options.keyboardRequest;
    if (request != 0 &&
        request != oldWidget.options.keyboardRequest &&
        widget.options.interactive) {
      _showSoftKeyboard();
    }
  }

  /// 拿焦点、叫出系统键盘。焦点原来在别处（大输入框）时 flterm 拿到焦点自己会叫；已经有焦点时
  /// 拿焦点什么都不变，要直接让输入法显示出来。这一帧画完再做：flterm 那时已经拿到 showKeyboard = true。
  void _showSoftKeyboard() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_lease.isActive) return;
      _focusNode.requestFocus();
      if (_focusNode.hasFocus) {
        unawaited(
            SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _adapter.removeListener(_onTerminalChanged);
    // 只释放自己这一次占用：新视图已经接手时（旧视图晚一步销毁）不影响它。
    _lease.release();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTerminalChanged() {
    if (!mounted) return;
    // 终端被释放、显示权被别的视图拿走：重建，把 flterm 视图卸下。
    if (_showingEngine && !_lease.isActive) return _rebuildSoon();
    if (!_lease.isActive) return;
    final alternate = _adapter.isAlternateScreen;
    final selection = _adapter.controller.hasSelection;
    if (alternate != _alternateScreen || selection != _hasSelection) {
      // 只在选区「有变没」时忘掉链接：长按开始时报链接，选区要等松手或拖动才出现。
      if (_hasSelection && !selection) _longPressLink = null;
      _alternateScreen = alternate;
      _hasSelection = selection;
      _refreshSelectionUrlSoon();
      _rebuildSoon();
    }
  }

  void _onLongPress(ActivatedLink? link) {
    if (!mounted || !_lease.isActive) return;
    _longPressLink = link;
    _rebuildSoon();
  }

  /// 手指抬起时 App 先收到，flterm 的手势识别器后收到、那时才定下选区：等这一帧画完再算。
  void _refreshSelectionUrlSoon() {
    if (_selectionUrlScheduled) return;
    _selectionUrlScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _selectionUrlScheduled = false;
      if (!mounted || !_lease.isActive || _adapter.isDisposed) return;
      final url = _adapter.controller.hasSelection
          ? webLinkIn(_adapter.controller.selectedText())
          : null;
      if (url != _selectionUrl) setState(() => _selectionUrl = url);
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// 选字菜单里「打开链接」打开的是什么：长按落在链接上就是那个链接（整段都算，拖出链接以外也算）；
  /// 否则选中的字整段是一个网址时就是它。都不是返回 null，不给这个按钮。
  ({String shown, String address})? _selectionLink() {
    if (!_hasSelection) return null;
    if (_longPressLink case final link?) {
      return (
        shown: link.text,
        // OSC 8 的地址解析不了时为空，确认框里会说看不懂、不给打开；不拿屏幕上的文字顶替地址。
        address:
            link.type == LinkType.osc8 ? link.uri?.toString() ?? '' : link.text,
      );
    }
    final url = _selectionUrl;
    return url == null ? null : (shown: url, address: url);
  }

  /// 通知可能在构建阶段到达（新视图在 initState 里拿走显示权），这时不能 setState，等这一帧画完。
  void _rebuildSoon() {
    if (_rebuildScheduled) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _rebuildScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _rebuildScheduled = false;
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    _showingEngine = false;
    if (!_lease.isActive) {
      // 终端已被别的视图接走或已释放：不再碰它，等自己被销毁。
      return const SizedBox.expand();
    }
    if (_adapter.engineViewHeldByOther(this)) {
      // 上一个视图的 flterm 视图还没卸下，这一帧先空着。
      _rebuildSoon();
      return const SizedBox.expand();
    }
    _showingEngine = true;
    final scheme = Theme.of(context).colorScheme;
    final options = widget.options;
    final interactive = options.interactive;
    final theme = TerminalTheme(
      palette: ColorPalette(
        ansiColors: terminalAnsiColors,
        background: scheme.surface,
        foreground: scheme.onSurface,
      ),
      cursor: CursorTheme(color: DynamicColor.fixed(scheme.primary)),
      selection: SelectionTheme(
        background: DynamicColor.fixed(scheme.primary.withValues(alpha: 0.35)),
      ),
      fontSize: options.fontSize,
      fontFamily: 'monospace',
      backgroundOpacity: options.transparentBackground ? 0 : 1,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        // 画中画小窗只看不操作：不抢焦点、不接手势。结构保持不变，进出画中画不重新挂 flterm 视图。
        IgnorePointer(
          ignoring: !interactive,
          child: ExcludeFocus(
            excluding: !interactive,
            child: _EngineViewMount(
              key: ObjectKey(_adapter),
              adapter: _adapter,
              owner: this,
              child: Listener(
                onPointerUp: (_) => _refreshSelectionUrlSoon(),
                child: _engineView(theme, options),
              ),
            ),
          ),
        ),
        if (interactive && (_hasSelection || _alternateScreen))
          Positioned(
            top: 10,
            right: 10,
            child: _selectionMenu(),
          ),
      ],
    );
  }

  Widget _engineView(TerminalTheme theme, TerminalViewOptions options) {
    final interactive = options.interactive;
    final controller = _adapter.controller;
    // Ctrl+Shift+A / Ctrl+Shift+K / Ctrl+Shift+C（见 terminalKeyShortcuts）。flterm 的清屏会给服务器发一个 Ctrl+L
    // 让 shell 重画提示符（上游 Ctrl+K 就是这样），全屏程序里什么都不做。
    return Actions(
      actions: {
        TerminalCopyIntent: CallbackAction<TerminalCopyIntent>(
          onInvoke: (_) {
            unawaited(_copySelection());
            return null;
          },
        ),
        TerminalSelectAllIntent: CallbackAction<TerminalSelectAllIntent>(
          onInvoke: (_) {
            if (_lease.isActive) controller.selectAll();
            return null;
          },
        ),
        TerminalClearScrollbackIntent:
            CallbackAction<TerminalClearScrollbackIntent>(
          onInvoke: (_) {
            if (_lease.isActive) controller.clear();
            return null;
          },
        ),
      },
      child: RepaintBoundary(
        child: _terminalView(controller, theme, options, interactive),
      ),
    );
  }

  Widget _terminalView(
    TerminalController controller,
    TerminalTheme theme,
    TerminalViewOptions options,
    bool interactive,
  ) {
    return TerminalView(
      controller: controller,
      theme: theme,
      focusNode: _focusNode,
      autofocus: interactive,
      // 用按键面板、大输入框时点终端不叫系统键盘（R25）：面板占着键盘的位置。
      showKeyboard: interactive && options.softKeyboard,
      // 设置里的「安全键盘」：输入法按可见密码框处理，不联想、不学习。
      secureTextInput: options.secureKeyboard,
      // 远端开着鼠标报告（tmux mouse on、htop）时，手指只有滑动发成滚轮；点按照样叫键盘，
      // 长按照样在本地选字，都不发鼠标点击（TER07，和 xterm2 一样）。
      gestureSettings: const TerminalGestureSettings(touchMouseClicks: false),
      // 粘贴换成 App 的（先预览），盖掉 flterm 在 Android 上直接粘贴的 Ctrl+V；
      // Ctrl+K、Ctrl+A、Ctrl+C 发给服务器，清屏、全选、复制挪到 Ctrl+Shift+K/A/C（10-07）。
      shortcuts: terminalKeyShortcuts,
      // 链接（R19）：远端用 OSC 8 标的链接，和文字里的 http/https 网址。不认文件路径
      // （flterm 的 LinkType.text 会认）：远端的路径在手机上打不开。
      // 不给 onActivate：点一下终端只叫键盘，点在链接上也一样（所有者 10-07 定）。
      // 长按落在链接上由 onLongPress 报出来，选字菜单里多一项「打开链接」，点了仍只弹确认框（SEC08、TER08）。
      linkSettings: LinkSettings(
        types: const {LinkType.osc8, LinkType.custom},
        rules: _webLinkRules,
        onLongPress: _onLongPress,
      ),
    );
  }

  Widget _selectionMenu() {
    final link = _selectionLink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (link != null) ...[
          FilledButton.tonalIcon(
            key: const ValueKey('open-terminal-link'),
            onPressed: () => unawaited(showTerminalLinkSheet(
              context,
              shownText: link.shown,
              address: link.address,
            )),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const LText('打开链接'),
          ),
          const SizedBox(width: 8),
        ],
        FilledButton.tonalIcon(
          key: const ValueKey('copy-terminal-selection'),
          onPressed: _hasSelection ? _copySelection : _showCopySnapshot,
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: const LText('复制'),
        ),
      ],
    );
  }

  Future<void> _copySelection() async {
    final controller = _adapter.controller;
    if (!_lease.isActive || !controller.hasSelection) return;
    final text = controller.selectedText();
    controller.clearSelection();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: LText('已复制终端文本'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _showCopySnapshot() =>
      showTerminalCopySheet(context, _adapter.allText());
}

final _webLinkRules = [
  LinkRule.regex(id: 'web', pattern: terminalWebLinkPattern),
];

/// 在适配器那里登记「有 flterm 视图挂着」，和 flterm 自己的挂、卸时机一致：
/// flterm 视图在 deactivate 时解绑控制器，这里也在 deactivate 时注销。
class _EngineViewMount extends StatefulWidget {
  const _EngineViewMount({
    super.key,
    required this.adapter,
    required this.owner,
    required this.child,
  });

  final GhosttyTerminalAdapter adapter;

  /// 挂着它的 Ghostty 视图。同一个视图重建时认得出是自己挂的，不会自己给自己让路。
  final Object owner;
  final Widget child;

  @override
  State<_EngineViewMount> createState() => _EngineViewMountState();
}

class _EngineViewMountState extends State<_EngineViewMount> {
  @override
  void initState() {
    super.initState();
    widget.adapter.retainEngineView(widget.owner);
  }

  @override
  void activate() {
    super.activate();
    widget.adapter.retainEngineView(widget.owner);
  }

  @override
  void deactivate() {
    widget.adapter.releaseEngineView(widget.owner);
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
