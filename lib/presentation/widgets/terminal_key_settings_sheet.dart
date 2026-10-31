import 'package:flutter/material.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';

import '../../domain/models/settings.dart';
import 'form_gap.dart';
import 'terminal_keys.dart';

class TerminalKeySettingsResult {
  const TerminalKeySettingsResult({
    required this.order,
    required this.customKeys,
    required this.hostScope,
  });

  final List<String> order;
  final List<TerminalCustomKey> customKeys;

  /// [order] 是这台主机专用的，不是全局的。
  final bool hostScope;
}

/// 快捷键设置：排序、加减、模板、只给这台主机（R45）。点「保存」才生效，关掉就是没改。
///
/// [hostLabel] 为 null 时（没进保险库的临时连接）没有「只给这台主机」：那份布局没地方存。
Future<TerminalKeySettingsResult?> showTerminalKeySettings(
  BuildContext context, {
  required List<String> globalOrder,
  required List<TerminalCustomKey> customKeys,
  String? hostLabel,
  List<String>? hostOrder,
}) =>
    showModalBottomSheet<TerminalKeySettingsResult>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _TerminalKeySettingsSheet(
        globalOrder: globalOrder,
        customKeys: customKeys,
        hostLabel: hostLabel,
        hostOrder: hostOrder,
      ),
    );

class _TerminalKeySettingsSheet extends StatefulWidget {
  const _TerminalKeySettingsSheet({
    required this.globalOrder,
    required this.customKeys,
    required this.hostLabel,
    required this.hostOrder,
  });

  final List<String> globalOrder;
  final List<TerminalCustomKey> customKeys;
  final String? hostLabel;
  final List<String>? hostOrder;

  @override
  State<_TerminalKeySettingsSheet> createState() =>
      _TerminalKeySettingsSheetState();
}

class _TerminalKeySettingsSheetState extends State<_TerminalKeySettingsSheet> {
  late final List<String> _working = [
    ...(widget.hostOrder ?? widget.globalOrder),
  ];
  late final List<TerminalCustomKey> _custom = [...widget.customKeys];
  late bool _hostScope = widget.hostOrder != null;

  String _labelFor(String id) {
    final builtIn = terminalQuickKeySpecs[id];
    if (builtIn != null) return builtIn.semanticsLabel ?? builtIn.label;
    for (final key in _custom) {
      if (key.id == id) return key.label;
    }
    return id;
  }

  /// 还能加的键：没在列表里的内置键和自定义键。
  List<String> get _addable => [
        for (final id in supportedTerminalQuickKeys)
          if (!_working.contains(id) && terminalQuickKeySpecs.containsKey(id))
            id,
        for (final key in _custom)
          if (!_working.contains(key.id)) key.id,
      ];

  void _replace(List<String> order) => setState(() {
        _working
          ..clear()
          ..addAll(order);
      });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .78,
      child: Column(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              // 开关、模板、添加按钮放列表头，跟着列表滚：横屏这个框只有 280dp 高，钉在上面的话放不下。
              header: _header(context),
              itemCount: _working.length,
              onReorderItem: (oldIndex, newIndex) => setState(() {
                final value = _working.removeAt(oldIndex);
                _working.insert(newIndex, value);
              }),
              itemBuilder: (context, index) => _row(_working[index]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('terminal-keys-save'),
                onPressed: () => Navigator.pop(
                  context,
                  TerminalKeySettingsResult(
                    order: _working,
                    customKeys: _custom,
                    hostScope: _hostScope,
                  ),
                ),
                child: const LText('保存快捷键'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final hostLabel = widget.hostLabel;
    final addable = _addable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: const LText('快捷键设置'),
          subtitle: const LText('拖动排序；按键会根据屏幕宽度自动换行'),
          trailing: TextButton(
            onPressed: () => setState(() {
              _working
                ..clear()
                ..addAll(defaultTerminalQuickKeys);
              // 专用布局只管这台主机，不能顺手把所有主机共用的自定义键清了。
              if (!_hostScope) _custom.clear();
            }),
            child: const LText('恢复默认'),
          ),
        ),
        if (hostLabel != null)
          SwitchListTile(
            key: const ValueKey('terminal-keys-host-scope'),
            dense: true,
            title: const LText('只给这台主机用'),
            subtitle: Text(hostLabel),
            value: _hostScope,
            onChanged: (value) {
              setState(() => _hostScope = value);
              // 打开：从眼前这一套改起。关掉：回到全局那一套。
              if (!value) _replace(widget.globalOrder);
            },
          ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final template in terminalKeyTemplates)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    key: ValueKey('terminal-keys-template-${template.id}'),
                    label: LText(template.label),
                    onPressed: () => _replace(template.keys),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MenuAnchor(
                menuChildren: [
                  for (final id in addable)
                    MenuItemButton(
                      key: ValueKey('terminal-keys-add-$id'),
                      onPressed: () => setState(() => _working.add(id)),
                      child: LText(_labelFor(id)),
                    ),
                ],
                builder: (context, menu, _) => OutlinedButton.icon(
                  key: const ValueKey('terminal-keys-add'),
                  onPressed: addable.isEmpty
                      ? null
                      : () => menu.isOpen ? menu.close() : menu.open(),
                  icon: const Icon(Icons.add),
                  label: const LText('添加按键'),
                ),
              ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed: () async {
                  final key = await _editCustomKey(context);
                  if (key == null) return;
                  setState(() {
                    _custom.add(key);
                    _working.add(key.id);
                  });
                },
                icon: const Icon(Icons.add),
                label: const LText('添加自定义快捷键'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _row(String id) {
    final customIndex = _custom.indexWhere((key) => key.id == id);
    return ListTile(
      key: ValueKey(id),
      leading: const Icon(Icons.drag_handle),
      title: LText(_labelFor(id)),
      subtitle: customIndex < 0
          ? const LText('内置按键')
          : LText('发送：${_custom[customIndex].value}'),
      trailing: customIndex < 0
          ? IconButton(
              key: ValueKey('terminal-key-remove-$id'),
              tooltip: localized('拿掉'),
              // 一个键都没有的话，读回来会当成没设置、变回默认，少一路会意外。
              onPressed: _working.length <= 1
                  ? null
                  : () => setState(() => _working.remove(id)),
              icon: const Icon(Icons.remove_circle_outline),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: localized('编辑'),
                  onPressed: () async {
                    final key = await _editCustomKey(
                      context,
                      initial: _custom[customIndex],
                    );
                    if (key == null) return;
                    setState(() => _custom[customIndex] = key);
                  },
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: localized('删除'),
                  onPressed: _working.length <= 1
                      ? null
                      : () => setState(() {
                            _custom.removeAt(customIndex);
                            _working.remove(id);
                          }),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
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
            const FormGap(),
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
