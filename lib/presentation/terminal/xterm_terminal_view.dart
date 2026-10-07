import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import '../../domain/terminal_link.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import '../../infrastructure/terminal/xterm_terminal_adapter.dart';
import '../localization/localized_widgets.dart';
import '../widgets/terminal_link_sheet.dart';
import 'terminal_view.dart';

/// 旧引擎 xterm2 的终端视图：画面、选区手柄、复制。除了测试，App 里只有这个文件和适配器认识 xterm2。
///
/// 视图只借用终端：挂载时占用显示权，销毁时释放；终端和背后的连接都不归它管，
/// 切标签、旋转、进出画中画时视图重建，终端和连接照旧（GST02）。
class XtermTerminalView extends StatefulWidget {
  const XtermTerminalView({
    super.key,
    required this.adapter,
    required this.options,
  });

  final XtermTerminalAdapter adapter;
  final TerminalViewOptions options;

  @override
  State<XtermTerminalView> createState() => _XtermTerminalViewState();
}

class _XtermTerminalViewState extends State<XtermTerminalView> {
  final _controller = TerminalController(
    pointerInputs: const PointerInputs({PointerInput.scroll}),
  );
  var _terminalViewKey = GlobalKey<TerminalViewState>();
  final _terminalStackKey = GlobalKey();
  final _scrollController = ScrollController();
  late TerminalViewLease _lease;
  Offset? _dragPointerToAnchor;
  Timer? _copyHoldTimer;
  Offset? _copyHoldOrigin;
  bool _copySnapshotOpen = false;
  late bool _alternateScreen;

  Terminal get _terminal => widget.adapter.terminal;

  @override
  void initState() {
    super.initState();
    _lease = widget.adapter.attachView();
    _alternateScreen = widget.adapter.isAlternateScreen;
    widget.adapter.addListener(_onTerminalChanged);
  }

  @override
  void didUpdateWidget(covariant XtermTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.options.secureKeyboard != widget.options.secureKeyboard) {
      // xterm keeps the platform TextInputConnection alive while the view is
      // mounted. Recreate it so Android and iOS receive the new input type.
      _terminalViewKey = GlobalKey<TerminalViewState>();
    }
    if (!identical(oldWidget.adapter, widget.adapter)) {
      oldWidget.adapter.removeListener(_onTerminalChanged);
      _lease.release();
      _lease = widget.adapter.attachView();
      _alternateScreen = widget.adapter.isAlternateScreen;
      widget.adapter.addListener(_onTerminalChanged);
      _controller.clearSelection();
    }
  }

  @override
  void dispose() {
    widget.adapter.removeListener(_onTerminalChanged);
    // 只释放自己这一次占用：新视图已经接手时（旧视图晚一步销毁）不影响它。
    _lease.release();
    _copyHoldTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onTerminalChanged() {
    final alternate = widget.adapter.isAlternateScreen;
    if (alternate != _alternateScreen) {
      _copyHoldTimer?.cancel();
      setState(() => _alternateScreen = alternate);
    }
    if (_controller.selection != null &&
        _controller.selectionFor(_terminal.buffer) == null) {
      _controller.clearSelection();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_lease.isActive) {
      // 终端已被别的视图接走或已释放：不再碰它，等自己被销毁。
      return const SizedBox.expand();
    }
    final scheme = Theme.of(context).colorScheme;
    final interactive = widget.options.interactive;
    final terminalTheme = TerminalTheme(
      cursor: scheme.primary,
      selection: scheme.primary.withValues(alpha: 0.35),
      foreground: scheme.onSurface,
      background: scheme.surface,
      black: terminalAnsiColors[0],
      red: terminalAnsiColors[1],
      green: terminalAnsiColors[2],
      yellow: terminalAnsiColors[3],
      blue: terminalAnsiColors[4],
      magenta: terminalAnsiColors[5],
      cyan: terminalAnsiColors[6],
      white: terminalAnsiColors[7],
      brightBlack: terminalAnsiColors[8],
      brightRed: terminalAnsiColors[9],
      brightGreen: terminalAnsiColors[10],
      brightYellow: terminalAnsiColors[11],
      brightBlue: terminalAnsiColors[12],
      brightMagenta: terminalAnsiColors[13],
      brightCyan: terminalAnsiColors[14],
      brightWhite: terminalAnsiColors[15],
      searchHitBackground: scheme.tertiaryContainer,
      searchHitBackgroundCurrent: scheme.primaryContainer,
      searchHitForeground: scheme.onSurface,
    );
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _scrollController]),
      child: _terminalContent(terminalTheme),
      builder: (context, terminalContent) {
        final selection =
            _controller.selectionFor(_terminal.buffer)?.normalized;
        final startHandle = selection == null
            ? null
            : _selectionHandlePosition(selection.begin);
        final endHandle =
            selection == null ? null : _selectionHandlePosition(selection.end);
        // xterm2 不认链接；选中的字整段是网址时，选字菜单里一样给「打开链接」（10-07，和 Ghostty 一致）。
        final link = selection == null || _alternateScreen
            ? null
            : webLinkIn(_terminal.buffer.getText(selection));
        return Stack(
          key: _terminalStackKey,
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            terminalContent!,
            if (interactive && startHandle != null)
              _TerminalSelectionHandle(
                key: const ValueKey('terminal-selection-handle-start'),
                anchor: startHandle,
                color: scheme.primary,
                onPanStart: (details) => _startHandleDrag(true, details),
                onPanUpdate: (details) => _updateHandleDrag(true, details),
                onPanEnd: _endHandleDrag,
              ),
            if (interactive && endHandle != null)
              _TerminalSelectionHandle(
                key: const ValueKey('terminal-selection-handle-end'),
                anchor: endHandle,
                color: scheme.primary,
                onPanStart: (details) => _startHandleDrag(false, details),
                onPanUpdate: (details) => _updateHandleDrag(false, details),
                onPanEnd: _endHandleDrag,
              ),
            if (interactive && (selection != null || _alternateScreen))
              Positioned(
                top: 10,
                right: 10,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (link != null) ...[
                      FilledButton.tonalIcon(
                        key: const ValueKey('open-terminal-link'),
                        onPressed: () => unawaited(showTerminalLinkSheet(
                          context,
                          shownText: link,
                          address: link,
                        )),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const LText('打开链接'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    FilledButton.tonalIcon(
                      key: const ValueKey('copy-terminal-selection'),
                      onPressed: _alternateScreen
                          ? () => _showCopySnapshot()
                          : _copySelection,
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      label: const LText('复制'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  /// Ctrl+Shift+K：清掉本地的历史和屏幕，只留提示符那几行（xterm2 的 clear）；不给服务器发东西。
  /// 全屏程序里什么都不做，和 Ghostty 一样。
  Widget _terminalContent(TerminalTheme theme) => Actions(
        actions: {
          TerminalClearScrollbackIntent:
              CallbackAction<TerminalClearScrollbackIntent>(
            onInvoke: (_) {
              if (_lease.isActive && !_terminal.isUsingAltBuffer) {
                _controller.clearSelection();
                _terminal.clear();
              }
              return null;
            },
          ),
        },
        child: _terminalListener(theme),
      );

  Widget _terminalListener(TerminalTheme theme) => Listener(
        onPointerDown: (event) {
          final mouse = event.kind == PointerDeviceKind.mouse;
          // Switching input devices changes policy; repeated finger gestures do not.
          if (_controller.pointerInput.inputs.contains(PointerInput.tap) !=
              mouse) {
            _controller.setPointerInputs(PointerInputs({
              PointerInput.scroll,
              if (mouse) PointerInput.tap,
            }));
          }
          _copyHoldTimer?.cancel();
          if (_alternateScreen &&
              widget.options.interactive &&
              event.kind == PointerDeviceKind.touch) {
            _copyHoldOrigin = event.position;
            // Extract text only after the hold is recognized, never on a swipe.
            _copyHoldTimer =
                Timer(const Duration(milliseconds: 550), _showCopySnapshot);
          }
        },
        onPointerMove: (event) {
          if (_copyHoldOrigin != null &&
              (event.position - _copyHoldOrigin!).distance > kTouchSlop) {
            _copyHoldTimer?.cancel();
            _copyHoldOrigin = null;
          }
        },
        onPointerUp: (_) => _copyHoldTimer?.cancel(),
        onPointerCancel: (_) => _copyHoldTimer?.cancel(),
        child: RepaintBoundary(
          child: TerminalView(
            _terminal,
            // 设置「全屏程序里滑动翻页」：xterm2 的 simulateScroll 就是在备用屏、没开鼠标报告时把滑动换成 ↑/↓，
            // 每滑过一行一个，和 Ghostty 的 1007 一样。默认关（R19）。
            simulateScroll: widget.options.fullscreenSwipe,
            key: _terminalViewKey,
            controller: _controller,
            scrollController: _scrollController,
            theme: theme,
            backgroundOpacity: widget.options.transparentBackground ? 0 : 1,
            keyboardAppearance: Theme.of(context).brightness,
            keyboardType: widget.options.secureKeyboard
                ? TextInputType.visiblePassword
                : TextInputType.emailAddress,
            deleteDetection: true,
            // xterm2 给了 shortcuts 就整个替换默认的：复制照抄它在 Android 上的默认（Ctrl+Shift+C），
            // 粘贴换成 App 的（先预览，SEC10），不让 xterm2 直接把剪贴板粘进终端。
            // 全选从 Ctrl+A 挪到 Ctrl+Shift+A、加 Ctrl+Shift+K 清滚动区，Ctrl+A 发给服务器（10-07，两个引擎一样）。
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.keyC,
                  control: true, shift: true): CopySelectionTextIntent.copy,
              SingleActivator(LogicalKeyboardKey.keyA,
                      control: true, shift: true):
                  SelectAllTextIntent(SelectionChangedCause.keyboard),
              SingleActivator(LogicalKeyboardKey.keyK,
                  control: true, shift: true): TerminalClearScrollbackIntent(),
              ...terminalPasteShortcuts,
            },
            autofocus: widget.options.interactive,
            padding: const EdgeInsets.all(8),
            textStyle: TerminalStyle(
                fontSize: widget.options.fontSize, fontFamily: 'monospace'),
          ),
        ),
      );

  Future<void> _showCopySnapshot() async {
    if (!mounted || _copySnapshotOpen) return;
    _copyHoldTimer?.cancel();
    _copySnapshotOpen = true;
    final text = widget.adapter.allText();
    try {
      await showTerminalCopySheet(context, text);
    } finally {
      _copySnapshotOpen = false;
    }
  }

  Offset? _selectionHandlePosition(CellOffset offset) {
    final terminalView = _terminalViewKey.currentState;
    final stackContext = _terminalStackKey.currentContext;
    if (terminalView == null || stackContext == null) return null;
    final stackBox = stackContext.findRenderObject();
    if (stackBox is! RenderBox || !stackBox.hasSize) return null;
    final renderTerminal = terminalView.renderTerminal;
    if (!renderTerminal.attached || !renderTerminal.hasSize) return null;
    final terminalOffset = renderTerminal.getOffset(offset).translate(
          0,
          renderTerminal.cellSize.height,
        );
    final position = stackBox.globalToLocal(
      renderTerminal.localToGlobal(terminalOffset),
    );
    if (position.dy < 0 ||
        position.dy > stackBox.size.height ||
        position.dx < 0 ||
        position.dx > stackBox.size.width) {
      return null;
    }
    return position;
  }

  void _startHandleDrag(bool start, DragStartDetails details) {
    final selection = _controller.selection?.normalized;
    final stackContext = _terminalStackKey.currentContext;
    if (selection == null || stackContext == null) return;
    final stackBox = stackContext.findRenderObject();
    if (stackBox is! RenderBox) return;
    final anchor = _selectionHandlePosition(
      start ? selection.begin : selection.end,
    );
    if (anchor == null) return;
    _dragPointerToAnchor =
        details.globalPosition - stackBox.localToGlobal(anchor);
  }

  void _updateHandleDrag(bool start, DragUpdateDetails details) {
    final pointerToAnchor = _dragPointerToAnchor;
    if (pointerToAnchor == null) return;
    final boundary = _selectionBoundaryAt(
      details.globalPosition - pointerToAnchor,
    );
    final selection = _controller.selection?.normalized;
    if (boundary == null || selection == null) return;

    var begin = selection.begin;
    var end = selection.end;
    if (start) {
      begin = boundary.isAfter(end) ? end : boundary;
    } else {
      end = boundary.isBefore(begin) ? begin : boundary;
    }
    _controller.setSelection(
      _terminal.buffer.createAnchorFromOffset(begin),
      _terminal.buffer.createAnchorFromOffset(end),
      mode: _controller.selectionMode,
    );
  }

  CellOffset? _selectionBoundaryAt(Offset globalPosition) {
    final terminalView = _terminalViewKey.currentState;
    if (terminalView == null) return null;
    final renderTerminal = terminalView.renderTerminal;
    if (!renderTerminal.attached || !renderTerminal.hasSize) return null;
    final local = renderTerminal.globalToLocal(globalPosition);
    final origin = renderTerminal.getOffset(const CellOffset(0, 0));
    final cellSize = renderTerminal.cellSize;
    final column = ((local.dx - origin.dx) / cellSize.width)
        .round()
        .clamp(0, _terminal.viewWidth)
        .toInt();
    final row = (((local.dy - origin.dy) / cellSize.height).round() - 1)
        .clamp(0, _terminal.buffer.lines.length - 1)
        .toInt();
    return CellOffset(column, row);
  }

  void _endHandleDrag(DragEndDetails details) {
    _dragPointerToAnchor = null;
  }

  Future<void> _copySelection() async {
    final selection = _controller.selectionFor(_terminal.buffer);
    if (selection == null) return;
    final text = _terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _controller.clearSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: LText('已复制终端文本'),
        duration: Duration(seconds: 1),
      ),
    );
  }
}

class _TerminalSelectionHandle extends StatelessWidget {
  const _TerminalSelectionHandle({
    super.key,
    required this.anchor,
    required this.color,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  static const hitSize = 44.0;

  final Offset anchor;
  final Color color;
  final GestureDragStartCallback onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;

  @override
  Widget build(BuildContext context) => Positioned(
        left: anchor.dx - hitSize / 2,
        top: anchor.dy - 2,
        width: hitSize,
        height: hitSize,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: onPanStart,
          onPanUpdate: onPanUpdate,
          onPanEnd: onPanEnd,
          child: CustomPaint(
            painter: _TerminalSelectionHandlePainter(color),
          ),
        ),
      );
}

class _TerminalSelectionHandlePainter extends CustomPainter {
  const _TerminalSelectionHandlePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final centerX = size.width / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(centerX - 2, 0, 4, 11),
        const Radius.circular(2),
      ),
      paint,
    );
    canvas.drawCircle(Offset(centerX, 16), 11, paint);
  }

  @override
  bool shouldRepaint(_TerminalSelectionHandlePainter oldDelegate) =>
      oldDelegate.color != color;
}
