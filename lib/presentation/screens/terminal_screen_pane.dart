part of 'terminal_screen.dart';

class _ConnectionStatusPane extends StatelessWidget {
  const _ConnectionStatusPane({
    required this.pending,
    this.onReturn,
    this.onClose,
    this.onCancel,
  });

  final PendingTerminalConnection pending;
  final VoidCallback? onReturn;
  final VoidCallback? onClose;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = pending.phase == PendingConnectionPhase.failed;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              key: const ValueKey('terminal-connection-status-dialog'),
              elevation: 12,
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HostSystemIcon(host: pending.host, size: 50),
                    const SizedBox(height: 12),
                    LText(
                      pending.host.label,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    HostAddressLine(
                      pending.host,
                      withProtocol: true,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 20),
                    if (failed)
                      Icon(
                        Icons.error_outline,
                        size: 38,
                        color: scheme.error,
                      )
                    else ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 18),
                    ],
                    LText(
                      failed ? '安全连接建立失败' : '正在建立安全连接…',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: failed ? scheme.error : null,
                          ),
                    ),
                    if (!failed && pending.stage != null) ...[
                      const SizedBox(height: 8),
                      LText(
                        pending.stage!.describe(),
                        key: const ValueKey('pending-connection-stage'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                    if (!failed && pending.checkPrompt != null) ...[
                      const SizedBox(height: 14),
                      TailscaleCheckCard(prompt: pending.checkPrompt!),
                    ],
                    if (failed) ...[
                      const SizedBox(height: 8),
                      LText(
                        '${pending.error ?? '未知错误'}',
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      if (pending.error != null &&
                          connectionHint(pending.error!) != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          key: const ValueKey('connection-failure-hint'),
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.lightbulb_outline,
                                size: 18,
                                color: scheme.onSecondaryContainer,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: LText(
                                  connectionHint(pending.error!)!,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: scheme.onSecondaryContainer,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (pending.routePlan != null) ...[
                        const SizedBox(height: 14),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: LText(
                            '这次实际走的路线',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        const SizedBox(height: 4),
                        RouteLegsView(plan: pending.routePlan!, dense: true),
                      ],
                    ],
                    if (!failed && pending.routePlan != null) ...[
                      const SizedBox(height: 6),
                      LText(
                        routeSummary(pending.routePlan!),
                        key: const ValueKey('pending-route-summary'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                    if (onReturn != null ||
                        onClose != null ||
                        onCancel != null) ...[
                      const SizedBox(height: 18),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (onReturn != null)
                            TextButton.icon(
                              onPressed: onReturn,
                              icon: const Icon(Icons.arrow_back),
                              label: const LText('返回当前终端'),
                            ),
                          if (onClose != null)
                            FilledButton.icon(
                              onPressed: onClose,
                              icon: const Icon(Icons.close),
                              label: const LText('关闭标签页'),
                            ),
                          if (onCancel != null)
                            FilledButton.icon(
                              key: const ValueKey('cancel-pending-connection'),
                              onPressed: onCancel,
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: const LText('终止连接'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalPictureInPictureHeader extends StatelessWidget {
  const _TerminalPictureInPictureHeader({required this.session});

  final ActiveTerminalSession session;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SizedBox(
          height: 30,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: session.connected
                      ? Colors.greenAccent
                      : Colors.orangeAccent,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: LText(
                    session.host.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const Icon(Icons.picture_in_picture, size: 15),
              ],
            ),
          ),
        ),
      );
}

class _TerminalPane extends StatefulWidget {
  const _TerminalPane({
    super.key,
    required this.session,
    required this.fontSize,
    required this.secureKeyboard,
    this.fullscreenSwipe = false,
    this.softKeyboard = true,
    this.keyboardRequest = 0,
    required this.pictureInPicture,
    required this.transparentBackground,
    this.onFocused,
    this.onPaste,
    this.onTap,
    this.inputTarget = false,
    this.banner,
  });
  final ActiveTerminalSession session;
  final double fontSize;
  final bool secureKeyboard;
  final bool fullscreenSwipe;

  /// 见 [TerminalViewOptions.softKeyboard]、[TerminalViewOptions.keyboardRequest]（R25）。
  final bool softKeyboard;
  final int keyboardRequest;
  final bool pictureInPicture;
  final bool transparentBackground;

  /// 这一格的终端拿到焦点（用户点了它）。分屏时据此决定快捷键栏发给谁。
  final ValueChanged<String>? onFocused;

  /// 硬件键盘在这一格里按了粘贴快捷键（[TerminalPasteIntent]）。
  final ValueChanged<ActiveTerminalSession>? onPaste;

  /// 手指在这一格上点了一下（不是拖、不是长按）。用按键面板时据此把收起的面板展开（R25）。
  final VoidCallback? onTap;

  /// 分屏时输入正发往这一格：描一圈边。另一格没有边，不只靠颜色区分。
  final bool inputTarget;

  /// 盖在这一格顶上的连接状态条（R22：断开、正在恢复、为什么停了、「重新连接」）。
  /// 叠在终端上面而不是挤占终端的位置：出现、消失都不改终端尺寸，不给远端发窗口变化。
  final Widget? banner;

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

/// 和引擎无关的那部分：背景、画中画小窗的文字更新。画面、选区、复制在各引擎自己的视图里
/// （`presentation/terminal/`），这里不认识任何引擎的类型（R16）。
class _TerminalPaneState extends State<_TerminalPane> {
  Timer? _pictureInPictureUpdateTimer;

  /// 认点按用：引擎自己的手势识别器总会赢下竞争（R04），外面套 GestureDetector 收不到，只能看原始指针。
  int? _tapPointer;
  Offset? _tapOrigin;
  Duration? _tapStart;

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch || _tapPointer != null) return;
    _tapPointer = event.pointer;
    _tapOrigin = event.position;
    _tapStart = event.timeStamp;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _tapPointer) return;
    final origin = _tapOrigin!;
    final start = _tapStart!;
    _tapPointer = null;
    if ((event.position - origin).distance <= kTouchSlop &&
        event.timeStamp - start < kLongPressTimeout) {
      widget.onTap?.call();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _tapPointer) _tapPointer = null;
  }

  TerminalSessionAdapter get _terminal => widget.session.terminal;

  @override
  void initState() {
    super.initState();
    _terminal.addListener(_onTerminalChanged);
    if (widget.pictureInPicture) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sendPipUpdate());
    }
  }

  @override
  void didUpdateWidget(covariant _TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session.terminal, widget.session.terminal)) {
      oldWidget.session.terminal.removeListener(_onTerminalChanged);
      _terminal.addListener(_onTerminalChanged);
    }
    if (!oldWidget.pictureInPicture && widget.pictureInPicture) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sendPipUpdate());
    } else if (oldWidget.pictureInPicture && !widget.pictureInPicture) {
      _pictureInPictureUpdateTimer?.cancel();
      _pictureInPictureUpdateTimer = null;
    }
  }

  @override
  void dispose() {
    _terminal.removeListener(_onTerminalChanged);
    _pictureInPictureUpdateTimer?.cancel();
    super.dispose();
  }

  void _onTerminalChanged() {
    if (!widget.pictureInPicture || _pictureInPictureUpdateTimer != null) {
      return;
    }
    _pictureInPictureUpdateTimer = Timer(
      const Duration(seconds: 1),
      () {
        _pictureInPictureUpdateTimer = null;
        _sendPipUpdate();
      },
    );
  }

  void _sendPipUpdate() {
    if (!mounted || !widget.pictureInPicture || _terminal.isDisposed) return;
    final scheme = Theme.of(context).colorScheme;
    unawaited(
      TerminalPictureInPictureService.update(
        title: widget.session.host.label,
        text: terminalPictureInPictureText(_terminal),
        connected: widget.session.connected,
        backgroundColor: scheme.surface.toARGB32(),
        foregroundColor: scheme.onSurface.toARGB32(),
        accentColor: scheme.primary.toARGB32(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final terminalLabel = localized('终端');
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) widget.onFocused?.call(widget.session.id);
      },
      // 描边叠在终端上面、不接手势；终端那一层的结构不随描边变，换格时不会把终端视图卸下重挂。
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 读屏软件把整块终端当一个控件报「终端：主机名」，点按（叫出键盘）照样能用（UX02）。
          MergeSemantics(
            child: Semantics(
              label: '$terminalLabel：${widget.session.host.label}',
              child: ColoredBox(
                color: widget.transparentBackground
                    ? Colors.transparent
                    : scheme.surface,
                child: Actions(
                  actions: {
                    TerminalPasteIntent: CallbackAction<TerminalPasteIntent>(
                      onInvoke: (_) {
                        widget.onPaste?.call(widget.session);
                        return null;
                      },
                    ),
                  },
                  child: Listener(
                    onPointerDown: _onPointerDown,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerCancel,
                    child: terminalViewFor(
                      _terminal,
                      TerminalViewOptions(
                        fontSize: widget.fontSize,
                        secureKeyboard: widget.secureKeyboard,
                        fullscreenSwipe: widget.fullscreenSwipe,
                        softKeyboard: widget.softKeyboard,
                        keyboardRequest: widget.keyboardRequest,
                        interactive: !widget.pictureInPicture,
                        transparentBackground: widget.transparentBackground,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.inputTarget)
            IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey('terminal-pane-input-target'),
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary, width: 2),
                ),
              ),
            ),
          if (widget.banner case final banner?)
            Positioned(top: 0, left: 0, right: 0, child: banner),
        ],
      ),
    );
  }
}

/// 断开的标签顶上那一条（R22）：现在是什么状态、为什么，加「重新连接」。
/// 原地切换连接方式时（R42）也用它显示进度，加「取消」。
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({
    super.key,
    required this.message,
    this.recovering = false,
    this.warning = false,
    this.onReconnect,
    this.onAcknowledge,
    this.onCancel,
  });

  final String message;
  final bool recovering;

  /// 不是断开，是提醒（比如后台保活没开起来）。
  final bool warning;
  final VoidCallback? onReconnect;
  final VoidCallback? onAcknowledge;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: (warning ? scheme.tertiaryContainer : scheme.secondaryContainer)
          .withValues(alpha: .94),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(
          children: [
            if (recovering)
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                warning ? Icons.warning_amber_outlined : Icons.link_off,
                size: 18,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: LText(
                message,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (onReconnect != null)
              TextButton(
                key: const ValueKey('terminal-reconnect'),
                onPressed: onReconnect,
                child: const LText('重新连接'),
              ),
            if (onAcknowledge != null)
              TextButton(
                key: const ValueKey('terminal-input-checked'),
                onPressed: onAcknowledge,
                child: const LText('已核查'),
              ),
            if (onCancel != null)
              TextButton(
                key: const ValueKey('terminal-switch-cancel'),
                onPressed: onCancel,
                child: const LText('取消'),
              ),
          ],
        ),
      ),
    );
  }
}
