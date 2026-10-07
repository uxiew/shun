import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../infrastructure/terminal/ghostty_terminal_adapter.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import '../localization/localized_widgets.dart';
import 'ghostty_terminal_view.dart';

/// 终端视图的显示选项，和引擎无关。
@immutable
class TerminalViewOptions {
  const TerminalViewOptions({
    required this.fontSize,
    required this.secureKeyboard,
    required this.interactive,
    required this.transparentBackground,
    this.fullscreenSwipe = false,
    this.softKeyboard = true,
    this.keyboardRequest = 0,
  });

  final double fontSize;

  /// 敏感输入：让输入法按密码框处理（不学习、不联想）。
  final bool secureKeyboard;

  /// 画中画小窗里只看不操作：不抢焦点、不选区、不复制。
  final bool interactive;
  final bool transparentBackground;

  /// 设置「全屏程序里滑动翻页」：全屏程序（less、man、vim）没开鼠标报告时，手指上下滑发 ↑/↓，每滑过一行发一个。
  /// 默认关：没开 mouse 的 tmux 看起来也是全屏程序，滑动的 ↑ 会到 shell、翻出上一条历史命令（R19）。
  /// 开着鼠标报告的程序（tmux mouse on、htop）不受影响，照样只发滚轮。
  final bool fullscreenSwipe;

  /// 点终端、终端拿到焦点时叫不叫系统键盘（R25）。用按键面板、大输入框时为 false：面板占着系统键盘的位置，
  /// 点终端不该把键盘叫出来盖住面板。硬件键盘照样能打进终端。
  final bool softKeyboard;

  /// 这个数变了（且不是 0）就让终端拿焦点、叫出系统键盘：从按键面板换回系统键盘时用，用户不用再点一下终端。
  final int keyboardRequest;
}

/// 硬件键盘的粘贴快捷键（R19）。引擎自带的快捷键是直接把剪贴板粘进终端、不预览；
/// 终端视图把 Ctrl+V（以及 Ctrl+Shift+V、Meta+V）改成发这个意图，由终端页接住，走和快捷键栏
/// 「粘贴」同一套预览（SEC10）。没人接（比如单独挂一个终端视图）时这个键原样交给终端，按的就是 Ctrl+V。
class TerminalPasteIntent extends Intent {
  const TerminalPasteIntent();
}

const terminalPasteShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyV, control: true):
      TerminalPasteIntent(),
  SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
      TerminalPasteIntent(),
  SingleActivator(LogicalKeyboardKey.keyV, meta: true): TerminalPasteIntent(),
};

/// 硬件键盘 Ctrl+Shift+A：全选本地终端里的字（不发给服务器）。
class TerminalSelectAllIntent extends Intent {
  const TerminalSelectAllIntent();
}

/// 硬件键盘 Ctrl+Shift+K：清掉本地的滚动区（往回翻的历史）。全屏程序里不做事。
class TerminalClearScrollbackIntent extends Intent {
  const TerminalClearScrollbackIntent();
}

/// 硬件键盘 Ctrl+Shift+C：复制选中的字（不发给服务器）。没有选区时什么都不做。
class TerminalCopyIntent extends Intent {
  const TerminalCopyIntent();
}

/// 这个组合键照常交给终端编码、发给服务器。
///
/// 故意不给它配任何 Action：快捷键管理器匹配上了却找不到 Action，就当没匹配上，按键接着往下走到终端。
/// 用它盖掉引擎自带的同一组合键——flterm 在 Android 上把 Ctrl+K 当清屏（服务器收到的是 Ctrl+L）、
/// Ctrl+A 当全选（什么都不发）、有选区时 Ctrl+C 当复制（不发 ^C）。给它配了 Action，这几个键就又发不到服务器了。
class TerminalSendKeyIntent extends Intent {
  const TerminalSendKeyIntent();
}

/// 终端视图的硬件快捷键（R19 粘贴 + 10-07 所有者的决定）。
///
/// Ctrl+K（nano 剪切一行、readline 删到行尾）、Ctrl+A（readline 回行首、tmux/screen 的前缀键）、
/// Ctrl+C（中断，有没有选区都一样）要发给服务器；App 自己的「清滚动区」「全选」「复制」挪到
/// Ctrl+Shift+K、Ctrl+Shift+A、Ctrl+Shift+C（和 Linux 桌面终端一样）。终端视图要接住这三个 App 意图。
///
/// 盖掉引擎默认的同一组合键靠的是 const 对象同一份：flterm 默认表里的 `const SingleActivator(.keyK, control: true)`
/// 和这里的是同一个对象，合并 map 时这里的覆盖它。这里改成非 const，或者两边参数不一样（比如多写一个
/// `includeRepeats`），两条就会并存，排在前面的引擎默认值先匹配上，Ctrl+K 又变回清屏。
const terminalKeyShortcuts = <ShortcutActivator, Intent>{
  ...terminalPasteShortcuts,
  SingleActivator(LogicalKeyboardKey.keyK, control: true):
      TerminalSendKeyIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, control: true):
      TerminalSendKeyIntent(),
  SingleActivator(LogicalKeyboardKey.keyC, control: true):
      TerminalSendKeyIntent(),
  SingleActivator(LogicalKeyboardKey.keyK, control: true, shift: true):
      TerminalClearScrollbackIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true):
      TerminalSelectAllIntent(),
  SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
      TerminalCopyIntent(),
};

/// 按终端实际用的引擎选视图。终端页只调这里，不认识任何引擎的类型（R16）。
/// R20 起只有 Ghostty；认不出的引擎照实写出来，不拿别的视图凑合。
Widget terminalViewFor(
  TerminalSessionAdapter terminal,
  TerminalViewOptions options,
) =>
    switch (terminal) {
      GhosttyTerminalAdapter() =>
        GhosttyTerminalView(adapter: terminal, options: options),
      _ => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const LText('这个版本不支持这个终端引擎'),
            Text(terminal.engine),
          ]),
        ),
    };

/// 终端的 16 色（Tomorrow Night），和原版 Netcatty（xterm2）一样，ls、git 的颜色不变。
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
