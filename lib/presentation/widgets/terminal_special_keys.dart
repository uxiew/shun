import 'package:flutter/material.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/settings_controller.dart';
import '../../domain/models/settings.dart';
import '../../infrastructure/terminal/terminal_input_controller.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import 'terminal_key_button.dart';
import 'terminal_key_settings_sheet.dart';
import 'terminal_keys.dart';

export 'terminal_key_button.dart' show decodeTerminalKeyEscapes;

class TerminalSpecialKeys extends ConsumerStatefulWidget {
  const TerminalSpecialKeys({
    super.key,
    required this.order,
    this.exactOrder = false,
    this.hostOrder,
    this.hostLabel,
    this.onSaveHostOrder,
    required this.customKeys,
    required this.onSend,
    required this.onKey,
    this.onPaste,
    this.onCompose,
    required this.inputController,
    required this.onAi,
    required this.onPortForward,
    this.onAiCli,
    this.onCopyScreen,
    this.onPerformanceMonitor,
    this.onHostPassword,
    required this.pictureInPicture,
    required this.onPictureInPicture,
    required this.fullscreen,
    required this.onFullscreen,
    required this.split,
    required this.onSplit,
    this.transparentBackground = false,
    this.compact = false,
    this.showQuickKeys = true,
    this.inputPanel = false,
    this.onInputPanel,
    this.onHideKeyboard,
  });

  /// 全局那一套（设置里的 `terminalQuickKeys`）。
  final List<String> order;

  /// 见 `AppSettings.terminalQuickKeysExact`。
  final bool exactOrder;

  /// 这台主机专用的布局（R45）。不为 null 就用它，不看 [order]。
  final List<String>? hostOrder;

  /// 这一格对应的保险库主机。null：没进保险库的临时连接，快捷键设置里没有「只给这台主机」。
  final String? hostLabel;

  /// 存这台主机的布局；null 是去掉，回到全局。
  final Future<void> Function(List<String>? order)? onSaveHostOrder;
  final List<TerminalCustomKey> customKeys;
  final void Function(String, {bool enter}) onSend;

  /// 内置的功能键（Esc、Tab、方向键、Home/End）交给引擎编码，见 [TerminalSpecialKey]。
  final void Function(TerminalSpecialKey key) onKey;

  /// 「粘贴」：终端页读剪贴板、按内容决定直接粘贴还是先预览（R19）。为 null 时这个键不响应。
  final VoidCallback? onPaste;

  /// 长按「粘贴」：打开空白的多行编辑框，写好了再发（R19）。
  final VoidCallback? onCompose;
  final TerminalInputController inputController;

  /// 为 null 时隐藏 AI 按钮（本 fork 默认关闭 AI，见 ForkFeatures）。
  final VoidCallback? onAi;
  final VoidCallback? onPortForward;
  final VoidCallback? onAiCli;

  /// 「复制屏幕文字」：弹出整屏文字的快照、在里面选了复制。只在「更多」菜单里（收成一行时、
  /// 按钮放不下时），平时在终端页标签条上；不占操作按钮那一行的位置。为 null 时不显示。
  final VoidCallback? onCopyScreen;

  /// 「性能监控」：和「复制屏幕文字」一样平时在标签条右上角，这里只在「更多」里（所有者 11-01）。
  /// 进程、tmux、Docker 这些都在它打开的面板里。为 null 时不显示（不是 SSH、或者断开了）。
  final VoidCallback? onPerformanceMonitor;

  /// sudo 键：发这台主机存的密码（R66）。这台主机没存密码、没连着时是 null，不显示。
  final VoidCallback? onHostPassword;
  final bool pictureInPicture;
  final VoidCallback? onPictureInPicture;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final bool split;
  final VoidCallback? onSplit;
  final bool transparentBackground;

  /// 竖着放不下两行快捷键加一行操作按钮时（横屏、小屏弹着键盘）收成一行：快捷键横排可滑动，
  /// 操作按钮收进「更多」，「收起键盘」留在行尾（TER05、TER06）。
  final bool compact;

  /// 键盘收着时不显示快捷键，只留操作按钮一行（R26）。这时不管 [compact]：
  /// 操作按钮一行和收成一行的样式一样高，按钮不用挤进「更多」。
  final bool showQuickKeys;

  /// 现在用的是按键面板 / 大输入框（R25），不是系统键盘直接打进终端。
  final bool inputPanel;

  /// 在系统键盘和按键面板/大输入框之间切换。为 null 时不显示这个按钮。
  final VoidCallback? onInputPanel;

  /// 「收起键盘」：默认让终端失去焦点（系统键盘随之收起）；用面板时终端页还要把面板收起来。
  final VoidCallback? onHideKeyboard;

  @override
  ConsumerState<TerminalSpecialKeys> createState() =>
      _TerminalSpecialKeysState();
}

class _TerminalSpecialKeysState extends ConsumerState<TerminalSpecialKeys> {
  TerminalKeyActions get _actions => TerminalKeyActions(
        input: widget.inputController,
        onKey: widget.onKey,
        onText: widget.onSend,
        onPaste: widget.onPaste,
      );

  Map<String, TerminalKeySpec> get _definitions => {
        ...terminalQuickKeySpecs,
        for (final key in widget.customKeys)
          key.id:
              TerminalKeySpec(key.label, text: key.value, decodeEscapes: true),
      };

  List<String> _globalOrder(Map<String, TerminalKeySpec> definitions) {
    final kept = widget.order.where(definitions.containsKey).toList();
    if (widget.exactOrder && kept.isNotEmpty) return kept;
    return [
      ...kept,
      ...defaultTerminalQuickKeys.where(
        (value) => !widget.order.contains(value),
      ),
    ];
  }

  /// 专用布局里的键全都不认识（换了台手机，自定义键没带过来）算没有，一个键都不留就没法用了。
  List<String>? _hostOrder(Map<String, TerminalKeySpec> definitions) {
    final kept = widget.hostOrder?.where(definitions.containsKey).toList();
    return kept == null || kept.isEmpty ? null : kept;
  }

  @override
  Widget build(BuildContext context) {
    final definitions = _definitions;
    final normalized = _hostOrder(definitions) ?? _globalOrder(definitions);
    if (widget.compact && widget.showQuickKeys) {
      return _compactBar(context, normalized, definitions);
    }
    return AnimatedBuilder(
      animation: widget.inputController,
      builder: (context, _) => Material(
        key: const ValueKey('terminal-special-keys-surface'),
        color: widget.transparentBackground
            ? Colors.transparent
            : Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.showQuickKeys) ...[
                _quickKeyGrid(normalized, definitions),
                const SizedBox(height: 4),
              ],
              LayoutBuilder(builder: (context, constraints) {
                final actions = <Widget>[
                  if (widget.onAiCli != null)
                    IconButton(
                      key: const ValueKey('terminal-action-ai-cli'),
                      tooltip: localized('AI 命令行工具'),
                      onPressed: widget.onAiCli,
                      icon: const Icon(Icons.terminal),
                    ),
                  if (widget.onAi != null)
                    IconButton(
                      key: const ValueKey('terminal-action-ai'),
                      tooltip: localized('shu Agent'),
                      onPressed: widget.onAi,
                      icon: Icon(
                        Icons.auto_awesome,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  if (widget.onHostPassword != null)
                    IconButton(
                      key: const ValueKey('terminal-action-host-password'),
                      tooltip: localized('发送这台主机的密码'),
                      onPressed: widget.onHostPassword,
                      icon: const Icon(Icons.key_outlined),
                    ),
                  IconButton(
                    key: const ValueKey('terminal-action-port-forward'),
                    tooltip: localized('端口转发'),
                    onPressed: widget.onPortForward,
                    icon: const Icon(Icons.swap_horiz),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-picture-in-picture'),
                    tooltip: widget.pictureInPicture ? '退出画中画' : '画中画',
                    isSelected: widget.pictureInPicture,
                    onPressed: widget.onPictureInPicture,
                    icon: Icon(
                      widget.pictureInPicture
                          ? Icons.picture_in_picture_alt
                          : Icons.picture_in_picture,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-fullscreen'),
                    tooltip: widget.fullscreen ? '退出全屏' : '全屏',
                    isSelected: widget.fullscreen,
                    onPressed: widget.onFullscreen,
                    icon: Icon(
                      widget.fullscreen
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-split'),
                    tooltip: localized('分屏'),
                    isSelected: widget.split,
                    onPressed: widget.onSplit,
                    icon: const Icon(Icons.vertical_split_outlined),
                  ),
                  if (widget.onInputPanel != null) _inputPanelButton(),
                  IconButton(
                    key: const ValueKey('terminal-action-edit'),
                    tooltip: localized('编辑快捷键'),
                    onPressed: () => _customize(context),
                    icon: const Icon(Icons.tune, size: 20),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-hide-keyboard'),
                    tooltip: localized('收起键盘'),
                    onPressed: _hideKeyboard,
                    icon: const Icon(Icons.keyboard_hide_outlined),
                  ),
                ];
                final maxCount =
                    (constraints.maxWidth / 48).floor().clamp(1, 20);
                // 全屏时标签条藏起来了，它上面的「复制屏幕文字」「性能监控」只能从「更多」进：
                // 这时「更多」一定在。以前性能监控是浮在终端右上角的圆钮，盖住 tmux 状态栏、vim 行尾，
                // 和 R25 去掉的浮动「复制」是同一个问题；不是 SSH 的标签以前连「更多」都没有，点不到复制。
                // 有只在菜单里的项时也一定在，不能看放不放得下：445dp 宽的手机上 8 个按钮刚好放得下，
                // 「更多」就没了，所有者要的「更多里能开性能监控」（F34）在那种手机上点不到。
                final menuOnly =
                    widget.fullscreen || widget.onPerformanceMonitor != null;
                final overflow = (widget.onAiCli != null || menuOnly) &&
                    actions.length + (menuOnly ? 1 : 0) > maxCount;
                // Preserve the two keyboard controls when overflowing, rather
                // than shrinking every action below its 48dp touch target.
                final keyboard = actions.where((button) =>
                    button.key ==
                        const ValueKey('terminal-action-input-panel') ||
                    button.key ==
                        const ValueKey('terminal-action-hide-keyboard'));
                final keptKeyboard = keyboard.take(maxCount - 1).toList();
                final visible = overflow
                    ? <Widget>[
                        ...actions
                            .where((button) => !keptKeyboard.contains(button))
                            .take(maxCount - keptKeyboard.length - 1),
                        ...keptKeyboard,
                        _moreActions(context, normalized)
                      ]
                    : [
                        ...actions,
                        if (menuOnly) _moreActions(context, normalized),
                      ];
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: visible
                      .map((button) => Expanded(child: button))
                      .toList(growable: false),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// 一行的样式：每个键 48dp 高，横排放不下就左右滑。
  Widget _compactBar(
    BuildContext context,
    List<String> order,
    Map<String, TerminalKeySpec> definitions,
  ) {
    return AnimatedBuilder(
      animation: widget.inputController,
      builder: (context, _) => Material(
        key: const ValueKey('terminal-special-keys-surface'),
        color: widget.transparentBackground
            ? Colors.transparent
            : Theme.of(context).colorScheme.surface,
        child: SizedBox(
          height: TerminalKeyFeel.of(context).height,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  key: const ValueKey('terminal-special-keys-compact'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  children: [
                    for (final id in order)
                      SizedBox(
                        width: 56,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: _keyButton(definitions[id]!),
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.onInputPanel != null) _inputPanelButton(),
              _moreActions(context, order),
              IconButton(
                key: const ValueKey('terminal-action-hide-keyboard'),
                tooltip: localized('收起键盘'),
                onPressed: _hideKeyboard,
                icon: const Icon(Icons.keyboard_hide_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _hideKeyboard() {
    final hide = widget.onHideKeyboard;
    if (hide != null) return hide();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 系统键盘 ⇄ 按键面板/大输入框（R25）。用着面板时按钮亮着，提示写「换回系统键盘」。
  Widget _inputPanelButton() => IconButton(
        key: const ValueKey('terminal-action-input-panel'),
        tooltip: localized(widget.inputPanel ? '换回系统键盘' : '按键面板和大输入框'),
        isSelected: widget.inputPanel,
        onPressed: widget.onInputPanel,
        icon: const Icon(Icons.keyboard_alt_outlined),
        selectedIcon: const Icon(Icons.keyboard_alt),
      );

  Widget _moreActions(BuildContext context, List<String> order) {
    final aiCliLabel = localized('AI 命令行工具');
    final actions = <(String, String, IconData, VoidCallback?)>[
      if (widget.onAiCli != null)
        ('ai-cli', aiCliLabel, Icons.terminal, widget.onAiCli),
      if (widget.onAi != null)
        ('ai', localized('shu Agent'), Icons.auto_awesome, widget.onAi),
      if (widget.onHostPassword != null)
        (
          'host-password',
          localized('发送这台主机的密码'),
          Icons.key_outlined,
          widget.onHostPassword,
        ),
      if (widget.onCopyScreen != null)
        (
          'copy-screen',
          localized('复制屏幕文字'),
          Icons.copy_all_outlined,
          widget.onCopyScreen,
        ),
      if (widget.onPerformanceMonitor != null)
        (
          'performance-monitor',
          localized('性能监控'),
          Icons.monitor_heart_outlined,
          widget.onPerformanceMonitor,
        ),
      (
        'port-forward',
        localized('端口转发'),
        Icons.swap_horiz,
        widget.onPortForward,
      ),
      (
        'picture-in-picture',
        widget.pictureInPicture ? '退出画中画' : '画中画',
        Icons.picture_in_picture,
        widget.onPictureInPicture,
      ),
      (
        'fullscreen',
        widget.fullscreen ? '退出全屏' : '全屏',
        widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
        widget.onFullscreen,
      ),
      (
        'split',
        localized('分屏'),
        Icons.vertical_split_outlined,
        widget.onSplit,
      ),
      (
        'edit',
        localized('编辑快捷键'),
        Icons.tune,
        () => _customize(context),
      ),
      if (widget.onInputPanel != null)
        (
          'input-panel',
          localized(widget.inputPanel ? '换回系统键盘' : '按键面板和大输入框'),
          Icons.keyboard_alt_outlined,
          widget.onInputPanel
        ),
      (
        'hide-keyboard',
        localized('收起键盘'),
        Icons.keyboard_hide_outlined,
        _hideKeyboard
      ),
    ];
    return PopupMenuButton<VoidCallback>(
      key: const ValueKey('terminal-action-more'),
      tooltip: localized('更多'),
      icon: const Icon(Icons.more_horiz),
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        for (final (id, label, icon, onPressed) in actions)
          PopupMenuItem<VoidCallback>(
            key: ValueKey('terminal-action-$id'),
            value: onPressed,
            enabled: onPressed != null,
            child: ListTile(
              leading: Icon(icon),
              title: LText(label),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
    );
  }

  Widget _quickKeyGrid(
    List<String> order,
    Map<String, TerminalKeySpec> definitions,
  ) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final columns = _quickKeyColumns(order.length, constraints.maxWidth);
          // 键和键之间留最多 4dp，但先保证每个键 48dp 宽：360dp 宽的手机放 7 个时一格只有 49dp，就不留缝了
          //（键平时没有底色，缝本来也看不出来，只有亮着的修饰键能看出挨在一起）。
          final cell = constraints.maxWidth.isFinite
              ? constraints.maxWidth / columns
              : 56.0;
          final gap = ((cell - 48) / 2).clamp(0.0, 2.0);
          final rows = _quickKeyRows(order, definitions, columns, gap);
          // 键加得多又调高了也不能把终端挤没（小屏上会报溢出）：超过这个高度才在栏里上下滚。
          final height = (order.length / columns).ceil() *
              (TerminalKeyFeel.of(context).height + 4);
          final limit = MediaQuery.sizeOf(context).height * .4;
          if (height <= limit) return rows;
          return SizedBox(
            height: limit,
            child: SingleChildScrollView(child: rows),
          );
        },
      );

  /// 每行几个键：尽量两行放完（默认 14 个就是每行 7 个），但每格至少 48dp 宽（触控目标，UX02），最少 6 个一行。
  /// 7 个一行要 336dp 宽（加上两边留白，360dp 的手机刚好够）；更窄的回到 6 个一行、多出一行。
  static int _quickKeyColumns(int count, double width) {
    final fit = width.isFinite ? (width / 48).floor() : 6;
    return ((count + 1) ~/ 2).clamp(6, fit < 6 ? 6 : fit);
  }

  Widget _quickKeyRows(
    List<String> order,
    Map<String, TerminalKeySpec> definitions,
    int columnCount,
    double gap,
  ) {
    // 48dp：Android 的最小触控目标（UX02）。原来 38dp 高的行里按钮按内容收缩、只有约 20dp 能点到。
    final rowHeight = TerminalKeyFeel.of(context).height;
    final rowCount = (order.length / columnCount).ceil();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < rowCount; row++) ...[
          if (row > 0) const SizedBox(height: 4),
          SizedBox(
            height: rowHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var column = 0; column < columnCount; column++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: gap),
                      child: row * columnCount + column < order.length
                          ? _keyButton(
                              definitions[order[row * columnCount + column]]!,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _keyButton(TerminalKeySpec key) {
    final actions = _actions;
    return TerminalKeyButton(
      spec: key,
      selected: actions.isSelected(key),
      onPressed: actions.press,
      // 「粘贴」长按打开空白的多行编辑框（R19）。
      onLongPress: key.paste ? widget.onCompose : null,
      onLongPressHint: key.paste ? '多行编辑' : null,
    );
  }

  Future<void> _customize(BuildContext context) async {
    final definitions = _definitions;
    final result = await showTerminalKeySettings(
      context,
      globalOrder: _globalOrder(definitions),
      customKeys: widget.customKeys,
      hostLabel: widget.onSaveHostOrder == null ? null : widget.hostLabel,
      hostOrder: _hostOrder(definitions),
    );
    if (result == null) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final settings = ref.read(settingsControllerProvider);
      await ref.read(settingsControllerProvider.notifier).update(
            settings.copyWith(
              terminalQuickKeys: result.hostScope ? null : result.order,
              terminalQuickKeysExact: result.hostScope ? null : true,
              terminalCustomKeys: result.customKeys,
            ),
          );
      // 这台主机本来就跟全局：不碰保险库，每写一次都要加密落盘。
      if (result.hostScope || widget.hostOrder != null) {
        await widget.onSaveHostOrder?.call(
          result.hostScope ? result.order : null,
        );
      }
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: LText('快捷键没存上：$error')),
      );
    }
  }
}
