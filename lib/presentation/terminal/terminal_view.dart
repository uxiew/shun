import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../infrastructure/terminal/ghostty_terminal_adapter.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import '../../infrastructure/terminal/xterm_terminal_adapter.dart';
import '../localization/localized_widgets.dart';
import 'ghostty_terminal_view.dart';
import 'xterm_terminal_view.dart';

/// 终端视图的显示选项，和引擎无关。
@immutable
class TerminalViewOptions {
  const TerminalViewOptions({
    required this.fontSize,
    required this.secureKeyboard,
    required this.interactive,
    required this.transparentBackground,
  });

  final double fontSize;

  /// 敏感输入：让输入法按密码框处理（不学习、不联想）。
  final bool secureKeyboard;

  /// 画中画小窗里只看不操作：不抢焦点、不选区、不复制。
  final bool interactive;
  final bool transparentBackground;
}

/// 按终端实际用的引擎选视图。终端页只调这里，不认识任何引擎的类型（R16）。
Widget terminalViewFor(
  TerminalSessionAdapter terminal,
  TerminalViewOptions options,
) =>
    switch (terminal) {
      XtermTerminalAdapter() =>
        XtermTerminalView(adapter: terminal, options: options),
      GhosttyTerminalAdapter() =>
        GhosttyTerminalView(adapter: terminal, options: options),
      _ => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const LText('这个版本不支持这个终端引擎'),
            Text(terminal.engine),
          ]),
        ),
    };

/// 两个引擎共用的 16 色（Tomorrow Night），换引擎时 ls、git 的颜色不变。
const terminalAnsiColors = <Color>[
  Color(0xff1d1f21),
  Color(0xffcc6666),
  Color(0xffb5bd68),
  Color(0xfff0c674),
  Color(0xff81a2be),
  Color(0xffb294bb),
  Color(0xff8abeb7),
  Color(0xffc5c8c6),
  Color(0xff666666),
  Color(0xffd54e53),
  Color(0xffb9ca4a),
  Color(0xffe7c547),
  Color(0xff7aa6da),
  Color(0xffc397d8),
  Color(0xff70c0b1),
  Color(0xffeaeaea),
];

/// 全屏程序（vim、tmux、less）里没法直接选字：弹出整屏文字的快照，在里面选了复制。
Future<void> showTerminalCopySheet(BuildContext context, String text) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _TerminalCopySheet(text: text),
    );

class _TerminalCopySheet extends StatefulWidget {
  const _TerminalCopySheet({required this.text});
  final String text;
  @override
  State<_TerminalCopySheet> createState() => _TerminalCopySheetState();
}

class _TerminalCopySheetState extends State<_TerminalCopySheet> {
  late final _text = TextEditingController(text: widget.text);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
        heightFactor: .8,
        child: Column(children: [
          Row(children: [
            const SizedBox(width: 16),
            const Expanded(child: LText('选择并复制')),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _text,
              builder: (_, value, child) => TextButton(
                key: const ValueKey('copy-terminal-snapshot'),
                onPressed: () async {
                  final selection = value.selection;
                  final text = selection.isValid && !selection.isCollapsed
                      ? selection.textInside(value.text)
                      : value.text;
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) Navigator.pop(context);
                },
                child: LText(
                    value.selection.isValid && !value.selection.isCollapsed
                        ? '复制'
                        : '复制全部'),
              ),
            ),
            IconButton(
                tooltip: localized('关闭'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close)),
          ]),
          Expanded(
              child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const ValueKey('terminal-copy-snapshot'),
              controller: _text,
              readOnly: true,
              showCursor: false,
              expands: true,
              maxLines: null,
              minLines: null,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(border: InputBorder.none),
            ),
          )),
        ]),
      );
}
