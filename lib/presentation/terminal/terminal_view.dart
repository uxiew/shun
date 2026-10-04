import 'package:flutter/material.dart';

import '../../infrastructure/terminal/terminal_session_adapter.dart';
import '../../infrastructure/terminal/xterm_terminal_adapter.dart';
import '../localization/localized_widgets.dart';
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
/// R17 接 Ghostty 时在这里加一支。
Widget terminalViewFor(
  TerminalSessionAdapter terminal,
  TerminalViewOptions options,
) =>
    switch (terminal) {
      XtermTerminalAdapter() =>
        XtermTerminalView(adapter: terminal, options: options),
      _ => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const LText('这个版本不支持这个终端引擎'),
            Text(terminal.engine),
          ]),
        ),
    };
