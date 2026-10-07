import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/settings_controller.dart';
import '../../domain/models/settings.dart';
import '../../infrastructure/terminal/terminal_input_controller.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import 'terminal_key_button.dart';
import 'terminal_keys.dart';

export 'terminal_key_button.dart' show decodeTerminalKeyEscapes;

class TerminalSpecialKeys extends ConsumerStatefulWidget {
  const TerminalSpecialKeys({
    super.key,
    required this.order,
    required this.customKeys,
    required this.onSend,
    required this.onKey,
    this.onPaste,
    this.onCompose,
    required this.inputController,
    required this.onAi,
    required this.onPortForward,
    required this.onSystemManagement,
    required this.pictureInPicture,
    required this.onPictureInPicture,
    required this.fullscreen,
    required this.onFullscreen,
    required this.split,
    required this.onSplit,
    this.transparentBackground = false,
    this.compact = false,
  });

  final List<String> order;
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
  final VoidCallback? onSystemManagement;
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

  @override
  Widget build(BuildContext context) {
    final definitions = <String, TerminalKeySpec>{
      ...terminalQuickKeySpecs,
      for (final key in widget.customKeys)
        key.id:
            TerminalKeySpec(key.label, text: key.value, decodeEscapes: true),
    };
    final normalized = [
      ...widget.order.where(definitions.containsKey),
      ...defaultTerminalQuickKeys.where(
        (value) => !widget.order.contains(value),
      ),
    ];
    if (widget.compact) return _compactBar(context, normalized, definitions);
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
              _quickKeyGrid(normalized, definitions),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  if (widget.onAi != null)
                    IconButton(
                      key: const ValueKey('terminal-action-ai'),
                      tooltip: localized('Catty Agent'),
                      onPressed: widget.onAi,
                      icon: Icon(
                        Icons.auto_awesome,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  IconButton(
                    key: const ValueKey('terminal-action-port-forward'),
                    tooltip: localized('端口转发'),
                    onPressed: widget.onPortForward,
                    icon: const Icon(Icons.swap_horiz),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-system-management'),
                    tooltip: localized('系统管理'),
                    onPressed: widget.onSystemManagement,
                    icon: const Icon(Icons.admin_panel_settings_outlined),
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
                  IconButton(
                    key: const ValueKey('terminal-action-edit'),
                    tooltip: localized('编辑快捷键'),
                    onPressed: () => _customize(context, normalized),
                    icon: const Icon(Icons.tune, size: 20),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-hide-keyboard'),
                    tooltip: localized('收起键盘'),
                    onPressed: () =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    icon: const Icon(Icons.keyboard_hide_outlined),
                  ),
                ]
                    .map((button) => Expanded(child: button))
                    .toList(growable: false),
              ),
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
          height: 48,
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
              _moreActions(context, order),
              IconButton(
                key: const ValueKey('terminal-action-hide-keyboard'),
                tooltip: localized('收起键盘'),
                onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
                icon: const Icon(Icons.keyboard_hide_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _moreActions(BuildContext context, List<String> order) {
    final actions = <(String, String, IconData, VoidCallback?)>[
      if (widget.onAi != null)
        ('ai', localized('Catty Agent'), Icons.auto_awesome, widget.onAi),
      (
        'port-forward',
        localized('端口转发'),
        Icons.swap_horiz,
        widget.onPortForward,
      ),
      (
        'system-management',
        localized('系统管理'),
        Icons.admin_panel_settings_outlined,
        widget.onSystemManagement,
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
        () => _customize(context, order),
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
          return _quickKeyRows(order, definitions, columns, gap);
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
    const rowHeight = 48.0;
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

  Future<void> _customize(
    BuildContext context,
    List<String> current,
  ) async {
    final working = [...current];
    final custom = [...widget.customKeys];
    final result = await showModalBottomSheet<_QuickKeySettingsResult>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          String labelFor(String id) {
            final builtIn = terminalQuickKeySpecs[id];
            if (builtIn != null) return builtIn.label;
            for (final key in custom) {
              if (key.id == id) return key.label;
            }
            return id;
          }

          return SizedBox(
            height: MediaQuery.sizeOf(context).height * .78,
            child: Column(
              children: [
                ListTile(
                  title: const LText('快捷键设置'),
                  subtitle: const LText('拖动排序；按键会根据屏幕宽度自动换行'),
                  trailing: TextButton(
                    onPressed: () => setModalState(() {
                      working
                        ..clear()
                        ..addAll(defaultTerminalQuickKeys);
                      custom.clear();
                    }),
                    child: const LText('恢复默认'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final key = await _editCustomKey(context);
                        if (key == null) return;
                        setModalState(() {
                          custom.add(key);
                          working.add(key.id);
                        });
                      },
                      icon: const Icon(Icons.add),
                      label: const LText('添加自定义快捷键'),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ReorderableListView.builder(
                    itemCount: working.length,
                    onReorderItem: (oldIndex, newIndex) => setModalState(() {
                      final value = working.removeAt(oldIndex);
                      working.insert(newIndex, value);
                    }),
                    itemBuilder: (context, index) {
                      final id = working[index];
                      final customIndex =
                          custom.indexWhere((key) => key.id == id);
                      return ListTile(
                        key: ValueKey(id),
                        leading: const Icon(Icons.drag_handle),
                        title: LText(labelFor(id)),
                        subtitle: customIndex < 0
                            ? const LText('内置按键')
                            : LText('发送：${custom[customIndex].value}'),
                        trailing: customIndex < 0
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: localized('编辑'),
                                    onPressed: () async {
                                      final key = await _editCustomKey(
                                        context,
                                        initial: custom[customIndex],
                                      );
                                      if (key == null) return;
                                      setModalState(() {
                                        custom[customIndex] = key;
                                      });
                                    },
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  IconButton(
                                    tooltip: localized('删除'),
                                    onPressed: () => setModalState(() {
                                      custom.removeAt(customIndex);
                                      working.remove(id);
                                    }),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(
                        context,
                        _QuickKeySettingsResult(working, custom),
                      ),
                      child: const LText('保存快捷键'),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (result == null) return;
    final settings = ref.read(settingsControllerProvider);
    await ref.read(settingsControllerProvider.notifier).update(
          settings.copyWith(
            terminalQuickKeys: result.order,
            terminalCustomKeys: result.customKeys,
          ),
        );
  }

  Future<TerminalCustomKey?> _editCustomKey(
    BuildContext context, {
    TerminalCustomKey? initial,
  }) async {
    final label = TextEditingController(text: initial?.label);
    final value = TextEditingController(text: initial?.value);
    return showDialog<TerminalCustomKey>(
      context: context,
      builder: (context) => AlertDialog(
        title: LText(initial == null ? '添加自定义快捷键' : '编辑自定义快捷键'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: label,
              autofocus: true,
              decoration: LInputDecoration(
                labelText: '显示名称',
                hintText: '例如：清屏',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: value,
              decoration: LInputDecoration(
                labelText: '发送内容',
                hintText: r'例如：clear\n 或 \x03',
                helperText: r'支持 \n、\t、\e 和 \xNN 转义',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: () {
              final keyLabel = label.text.trim();
              final keyValue = value.text;
              if (keyLabel.isEmpty || keyValue.isEmpty) return;
              Navigator.pop(
                context,
                TerminalCustomKey(
                  id: initial?.id ??
                      'custom-${DateTime.now().microsecondsSinceEpoch}',
                  label: keyLabel,
                  value: keyValue,
                ),
              );
            },
            child: const LText('确定'),
          ),
        ],
      ),
    );
  }
}

class _QuickKeySettingsResult {
  const _QuickKeySettingsResult(this.order, this.customKeys);

  final List<String> order;
  final List<TerminalCustomKey> customKeys;
}
