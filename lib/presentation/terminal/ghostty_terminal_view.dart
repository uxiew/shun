import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../infrastructure/terminal/ghostty_terminal_adapter.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import '../localization/localized_widgets.dart';
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
    _adapter.addListener(_onTerminalChanged);
  }

  @override
  void didUpdateWidget(covariant GhosttyTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.adapter, widget.adapter)) {
      oldWidget.adapter.removeListener(_onTerminalChanged);
      _lease.release();
      _attach();
    }
  }

  @override
  void dispose() {
    _adapter.removeListener(_onTerminalChanged);
    // 只释放自己这一次占用：新视图已经接手时（旧视图晚一步销毁）不影响它。
    _lease.release();
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
      _alternateScreen = alternate;
      _hasSelection = selection;
      _rebuildSoon();
    }
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
              child: RepaintBoundary(
                child: TerminalView(
                  controller: _adapter.controller,
                  theme: theme,
                  autofocus: interactive,
                  showKeyboard: interactive,
                  // 远端能把任意文字标成链接（OSC 8），点了打开什么由远端说了算；
                  // 链接识别也会吃掉点按，点终端叫不回键盘。识别和打开链接留给 R19 定规矩。
                  linkSettings: const LinkSettings(types: {}),
                ),
              ),
            ),
          ),
        ),
        if (interactive && (_hasSelection || _alternateScreen))
          Positioned(
            top: 10,
            right: 10,
            child: FilledButton.tonalIcon(
              key: const ValueKey('copy-terminal-selection'),
              onPressed: _hasSelection ? _copySelection : _showCopySnapshot,
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: const LText('复制'),
            ),
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
