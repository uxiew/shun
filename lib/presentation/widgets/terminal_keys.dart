import 'package:flutter/material.dart';

import '../../infrastructure/terminal/terminal_session_adapter.dart';
import 'terminal_key_button.dart';

// 快捷键栏和按键面板上的键，在这里定义一次（R25 把它们从快捷键栏里拿出来共用）。
// 读屏名字（semanticsLabel）给只有一个符号的键：TalkBack 念「竖线」比念不出来或念成「垂直线」好懂。

const escapeKey = TerminalKeySpec('Esc', special: TerminalSpecialKey.escape);
const tabKey = TerminalKeySpec('Tab', special: TerminalSpecialKey.tab);
const ctrlKey = TerminalKeySpec('Ctrl', modifier: 'ctrl');
const altKey = TerminalKeySpec('Alt', modifier: 'alt');
const shiftKey = TerminalKeySpec('Shift', modifier: 'shift');
const arrowUpKey = TerminalKeySpec(
  '↑',
  special: TerminalSpecialKey.arrowUp,
  repeatable: true,
  semanticsLabel: '上箭头',
);
const arrowDownKey = TerminalKeySpec(
  '↓',
  special: TerminalSpecialKey.arrowDown,
  repeatable: true,
  semanticsLabel: '下箭头',
);
const arrowLeftKey = TerminalKeySpec(
  '←',
  special: TerminalSpecialKey.arrowLeft,
  repeatable: true,
  semanticsLabel: '左箭头',
);
const arrowRightKey = TerminalKeySpec(
  '→',
  special: TerminalSpecialKey.arrowRight,
  repeatable: true,
  semanticsLabel: '右箭头',
);
const homeKey = TerminalKeySpec('Home', special: TerminalSpecialKey.home);
const endKey = TerminalKeySpec('End', special: TerminalSpecialKey.end);
// 10-07 加：less、man、vim 里翻一页；按住连发，和方向键一样。
const pageUpKey = TerminalKeySpec(
  'PgUp',
  special: TerminalSpecialKey.pageUp,
  repeatable: true,
);
const pageDownKey = TerminalKeySpec(
  'PgDn',
  special: TerminalSpecialKey.pageDown,
  repeatable: true,
);
const enterKey = TerminalKeySpec(
  '⏎',
  special: TerminalSpecialKey.enter,
  semanticsLabel: '回车',
);
const backspaceKey = TerminalKeySpec(
  '⌫',
  special: TerminalSpecialKey.backspace,
  repeatable: true,
  semanticsLabel: '退格',
);
const deleteKey = TerminalKeySpec('Del', special: TerminalSpecialKey.delete);
const insertKey = TerminalKeySpec('Ins', special: TerminalSpecialKey.insert);
const pasteKey = TerminalKeySpec(
  '粘贴',
  paste: true,
  icon: Icons.content_paste_outlined,
);

/// Ctrl+字母按文字发控制字符（0x03 这种），和硬件键盘上按出来的一样。
TerminalKeySpec ctrlLetterKey(String letter) => TerminalKeySpec(
      'Ctrl+$letter',
      text: String.fromCharCode(letter.codeUnitAt(0) & 0x1f),
    );

final ctrlCKey = ctrlLetterKey('C');
final ctrlDKey = ctrlLetterKey('D');
final ctrlZKey = ctrlLetterKey('Z');
final ctrlLKey = ctrlLetterKey('L');

const functionKeys = <TerminalKeySpec>[
  TerminalKeySpec('F1', special: TerminalSpecialKey.f1),
  TerminalKeySpec('F2', special: TerminalSpecialKey.f2),
  TerminalKeySpec('F3', special: TerminalSpecialKey.f3),
  TerminalKeySpec('F4', special: TerminalSpecialKey.f4),
  TerminalKeySpec('F5', special: TerminalSpecialKey.f5),
  TerminalKeySpec('F6', special: TerminalSpecialKey.f6),
  TerminalKeySpec('F7', special: TerminalSpecialKey.f7),
  TerminalKeySpec('F8', special: TerminalSpecialKey.f8),
  TerminalKeySpec('F9', special: TerminalSpecialKey.f9),
  TerminalKeySpec('F10', special: TerminalSpecialKey.f10),
  TerminalKeySpec('F11', special: TerminalSpecialKey.f11),
  TerminalKeySpec('F12', special: TerminalSpecialKey.f12),
];

/// 一个符号键：按打字发这个字符（Ctrl 亮着时套上 Ctrl，比如 Ctrl + `[` 就是 Esc）。
TerminalKeySpec symbolKey(String symbol) => TerminalKeySpec(
      symbol,
      text: symbol,
      semanticsLabel: symbolNames[symbol],
    );

/// 符号在读屏软件里念什么。
///
/// 名字写在前面（名字 → 符号再倒过来）：本地化覆盖检查按「引号里有中文」抓字面量，
/// 一行里先出现符号的引号会把整行抓成一段，查不到译文。
const _symbolsByName = <String, String>{
  '斜杠': '/',
  '反斜杠': '\\',
  '竖线': '|',
  '波浪号': '~',
  '反引号': '`',
  '减号': '-',
  '下划线': '_',
  '等号': '=',
  '加号': '+',
  '星号': '*',
  '与号': '&',
  '脱字符': '^',
  '美元符号': r'$',
  '井号': '#',
  '艾特符号': '@',
  '感叹号': '!',
  '问号': '?',
  '百分号': '%',
  '单引号': "'",
  '双引号': '"',
  '冒号': ':',
  '分号': ';',
  '逗号': ',',
  '句点': '.',
  '左圆括号': '(',
  '右圆括号': ')',
  '左方括号': '[',
  '右方括号': ']',
  '左花括号': '{',
  '右花括号': '}',
  '小于号': '<',
  '大于号': '>',
};

final symbolNames = <String, String>{
  for (final MapEntry(:key, :value) in _symbolsByName.entries) value: key,
};

/// 快捷键栏的内置键（id → 键）。id 存在设置里（`terminalQuickKeys`），别改名。
final terminalQuickKeySpecs = <String, TerminalKeySpec>{
  'escape': escapeKey,
  'alt': altKey,
  'ctrl': ctrlKey,
  'shift': shiftKey,
  'tab': tabKey,
  'arrowUp': arrowUpKey,
  'arrowDown': arrowDownKey,
  'arrowLeft': arrowLeftKey,
  'arrowRight': arrowRightKey,
  'home': homeKey,
  'end': endKey,
  'pageUp': pageUpKey,
  'pageDown': pageDownKey,
  'paste': pasteKey,
  'ctrlC': ctrlCKey,
  'ctrlD': ctrlDKey,
  'ctrlZ': ctrlZKey,
  'pipe': symbolKey('|'),
  'slash': symbolKey('/'),
  'tilde': symbolKey('~'),
};
