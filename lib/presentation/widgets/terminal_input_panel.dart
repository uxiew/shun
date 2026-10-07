import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../application/terminal_compose.dart';
import '../../domain/models/settings.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../localization/localized_widgets.dart';
import 'terminal_compose_box.dart';
import 'terminal_key_button.dart';
import 'terminal_keys.dart';

/// 终端下面的输入面板（R25 第一部分，所有者 10-07 提的；参考 LobiShell、UU 远程这类移动端的交互，没用它们的素材）：
/// 左边一页是 App 自己的按键面板，右边一页是大输入框，左右滑动切换，顶上的两个标签也能点着切（读屏软件用）。
///
/// 面板开着时系统键盘收着（大输入框那页点进框里才弹），它占的就是系统键盘原来的位置。
/// 按键面板的键和快捷键栏走同一个出口（[TerminalKeyActions]：功能键交给引擎编码，文字经修饰键发），
/// 大输入框按 R19 的粘贴发（[TerminalComposeBox]）。
class TerminalInputPanel extends StatefulWidget {
  const TerminalInputPanel({
    super.key,
    required this.session,
    required this.mode,
    required this.onModeChanged,
    required this.keyActions,
    required this.customKeys,
    required this.drafts,
    required this.composeFocus,
    required this.onSystemKeyboard,
    this.secureKeyboard = false,
    this.dense = false,
    this.showHeader = true,
    this.transparentBackground = false,
  });

  /// 输入发往的那一格的当前连接。
  final ActiveTerminalSession session;

  /// [terminalInputKeys] 或 [terminalInputCompose]。
  final String mode;
  final ValueChanged<String> onModeChanged;
  final TerminalKeyActions keyActions;

  /// 用户在快捷键栏里加的自定义快捷键，面板里另有一页放它们。
  final List<TerminalCustomKey> customKeys;
  final TerminalComposeDrafts drafts;
  final FocusNode composeFocus;

  /// 换回系统键盘直接打进终端（原来的方式）。
  final VoidCallback onSystemKeyboard;
  final bool secureKeyboard;

  /// 地方很小（横屏弹着键盘）：大输入框只留一行。
  final bool dense;

  /// 顶上那一行（两个标签、分页、换回系统键盘）。在大输入框里打字、系统键盘弹着时收起来，地方留给框；
  /// 那时要换页可以左右滑，换回系统键盘用快捷键栏上的按钮。
  final bool showHeader;
  final bool transparentBackground;

  @override
  State<TerminalInputPanel> createState() => _TerminalInputPanelState();
}

/// 按键面板里的几页。
enum _KeyPage { common, symbols, control, function, custom }

class _TerminalInputPanelState extends State<TerminalInputPanel> {
  late final _pages = PageController(initialPage: _pageIndex(widget.mode));
  var _keyPage = _KeyPage.common;

  static int _pageIndex(String mode) => mode == terminalInputCompose ? 1 : 0;

  @override
  void didUpdateWidget(covariant TerminalInputPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final page = _pageIndex(widget.mode);
    if (_pages.hasClients && (_pages.page?.round() ?? page) != page) {
      _pages.jumpToPage(page);
    }
    if (_keyPage == _KeyPage.custom && widget.customKeys.isEmpty) {
      _keyPage = _KeyPage.common;
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _show(String mode) {
    if (mode == widget.mode) return;
    widget.onModeChanged(mode);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final composing = widget.mode == terminalInputCompose;
    return Material(
      key: const ValueKey('terminal-input-panel'),
      color: widget.transparentBackground ? Colors.transparent : scheme.surface,
      child: Column(
        children: [
          if (widget.showHeader && !widget.dense) _header(context, composing),
          Expanded(
            child: PageView(
              key: const ValueKey('terminal-input-panel-pages'),
              controller: _pages,
              onPageChanged: (index) => _show(
                index == 1 ? terminalInputCompose : terminalInputKeys,
              ),
              children: [
                AnimatedBuilder(
                  animation: widget.keyActions.input,
                  builder: (context, _) => _keysPage(),
                ),
                TerminalComposeBox(
                  session: widget.session,
                  drafts: widget.drafts,
                  focusNode: widget.composeFocus,
                  secureKeyboard: widget.secureKeyboard,
                  dense: widget.dense,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, bool composing) {
    // 单独一行取译文：本地化覆盖检查按引号抓中文，插值里套引号会被抓成半截。
    final sendTo = localized('发到');
    final pages = [
      (_KeyPage.common, '常用'),
      (_KeyPage.symbols, '符号'),
      (_KeyPage.control, '组合键'),
      (_KeyPage.function, 'F 键'),
      if (widget.customKeys.isNotEmpty) (_KeyPage.custom, '自定义'),
    ];
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          _modeTab(
            key: const ValueKey('terminal-input-tab-keys'),
            icon: Icons.keyboard_alt_outlined,
            label: '按键面板',
            selected: !composing,
            onPressed: () => _show(terminalInputKeys),
          ),
          _modeTab(
            key: const ValueKey('terminal-input-tab-compose'),
            icon: Icons.edit_note,
            label: '大输入框',
            selected: composing,
            onPressed: () => _show(terminalInputCompose),
          ),
          Expanded(
            child: composing
                ? Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      '$sendTo ${widget.session.host.label}',
                      key: const ValueKey('terminal-compose-target'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  )
                : ListView(
                    key: const ValueKey('terminal-key-pages'),
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final (page, label) in pages)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: ChoiceChip(
                            key: ValueKey('terminal-key-page-${page.name}'),
                            label: LText(label),
                            selected: _keyPage == page,
                            showCheckmark: false,
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            onSelected: (_) => setState(() => _keyPage = page),
                          ),
                        ),
                    ],
                  ),
          ),
          IconButton(
            key: const ValueKey('terminal-input-system-keyboard'),
            tooltip: localized('换回系统键盘'),
            onPressed: widget.onSystemKeyboard,
            icon: const Icon(Icons.keyboard_outlined),
          ),
        ],
      ),
    );
  }

  Widget _modeTab({
    required Key key,
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) =>
      IconButton(
        key: key,
        tooltip: localized(label),
        isSelected: selected,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: selected
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
        ),
        icon: Icon(icon),
      );

  Widget _keysPage() => LayoutBuilder(
        builder: (context, constraints) => _keyGrid(constraints.maxWidth),
      );

  Widget _keyGrid(double width) {
    // 横屏（一行放得下 12 个 52dp 的键）：每页摆成两行，面板矮，终端多留几行；竖屏摆成四行。
    final wide = width - 8 >= 12 * 52;
    final maxWidth = wide ? 12 * 72.0 : 560.0;
    final inner = math.min(width - 8, maxWidth);
    final rows = switch (_keyPage) {
      _KeyPage.common => wide ? _commonRowsWide : _commonRows,
      // 符号多：每行能放几个就放几个（每个至少 48dp），411dp 宽的手机一行 8 个、四行放完；横屏一行 16 个。
      _KeyPage.symbols =>
        _flow(_symbols, (inner / 48).floor().clamp(6, wide ? 16 : 8)),
      _KeyPage.control => wide ? _pairUp(_controlRows) : _controlRows,
      _KeyPage.function => wide ? _pairUp(_functionRows) : _functionRows,
      _KeyPage.custom => _flow([
          for (final key in widget.customKeys)
            TerminalKeySpec(key.label, text: key.value, decodeEscapes: true),
        ], wide ? 6 : 3),
    };
    final columns = rows.fold(1, (most, row) => math.max(most, row.length));
    // 键和键之间留最多 4dp，但先保证每个键 48dp 宽（UX02）。
    final gap = ((inner / columns - 48) / 2).clamp(0.0, 2.0);
    return SingleChildScrollView(
      key: ValueKey('terminal-key-grid-${_keyPage.name}'),
      padding: const EdgeInsets.fromLTRB(4, 1, 4, 4),
      child: Center(
        child: ConstrainedBox(
          // 横屏很宽：键不用拉成一百多 dp 宽，按竖屏的手感放在中间。
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            children: [
              for (final row in rows) _keyRow(row, columns, gap),
            ],
          ),
        ),
      ),
    );
  }

  /// 横屏把四行两两并成两行（第一行接第二行、第三行接第四行）。
  static List<List<TerminalKeySpec?>> _pairUp(
    List<List<TerminalKeySpec?>> rows,
  ) =>
      [
        for (var i = 0; i < rows.length; i += 2)
          [...rows[i], if (i + 1 < rows.length) ...rows[i + 1]],
      ];

  static List<List<TerminalKeySpec?>> _flow(
    List<TerminalKeySpec> keys,
    int columns,
  ) =>
      [
        for (var i = 0; i < keys.length; i += columns)
          keys.sublist(i, math.min(i + columns, keys.length)),
      ];

  Widget _keyRow(List<TerminalKeySpec?> row, int columns, double gap) {
    final actions = widget.keyActions;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: SizedBox(
        // 48dp：Android 的最小触控目标（UX02）。
        height: 48,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 不满一行的（最后一行符号、自定义键）也按整行的格子宽，左对齐。
            for (var i = 0; i < columns; i++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: gap),
                  child: i >= row.length || row[i] == null
                      ? const SizedBox.shrink()
                      : TerminalKeyButton(
                          spec: row[i]!,
                          selected: actions.isSelected(row[i]!),
                          onPressed: actions.press,
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 常用：修饰键、Esc/Tab、退格回车，方向键排成倒 T（↑ 在 ↓ 正上方），翻页和最常用的几个符号。
final _commonRows = <List<TerminalKeySpec?>>[
  [escapeKey, tabKey, ctrlKey, altKey, shiftKey, backspaceKey],
  [ctrlCKey, ctrlDKey, ctrlZKey, arrowUpKey, ctrlLKey, enterKey],
  [homeKey, endKey, arrowLeftKey, arrowDownKey, arrowRightKey, deleteKey],
  [
    pageUpKey,
    pageDownKey,
    symbolKey('/'),
    symbolKey('|'),
    symbolKey('~'),
    symbolKey('-')
  ],
];

/// 常用页横屏的摆法：两行十二个，方向键仍是倒 T（↑ 在 ↓ 正上方）。
final _commonRowsWide = <List<TerminalKeySpec?>>[
  [
    escapeKey,
    tabKey,
    ctrlKey,
    altKey,
    shiftKey,
    backspaceKey,
    pageUpKey,
    homeKey,
    ctrlCKey,
    arrowUpKey,
    ctrlLKey,
    enterKey
  ],
  [
    symbolKey('/'),
    symbolKey('|'),
    symbolKey('~'),
    symbolKey('-'),
    ctrlDKey,
    ctrlZKey,
    pageDownKey,
    endKey,
    arrowLeftKey,
    arrowDownKey,
    arrowRightKey,
    deleteKey
  ],
];

/// 符号：shell 里常用、手机键盘要切两三层才找得到的。按这个顺序一行行排（一行几个看屏幕宽度）。
final _symbols = [
  for (final symbol in const [
    '/', '\\', '|', '~', '`', '-', '_', '=', //
    '+', '*', '&', '^', r'$', '#', '@', '%', //
    '!', '?', "'", '"', ':', ';', ',', '.', //
    '(', ')', '[', ']', '{', '}', '<', '>', //
  ])
    symbolKey(symbol),
];

/// Ctrl 组合：readline（bash、zsh 的 emacs 键位）和 tmux 常用的，面板上没有字母键，单独放一页。
final _controlRows = <List<TerminalKeySpec?>>[
  [for (final letter in 'AEUKWY'.split('')) ctrlLetterKey(letter)],
  [for (final letter in 'RPNBFL'.split('')) ctrlLetterKey(letter)],
  [
    ctrlCKey,
    ctrlDKey,
    ctrlZKey,
    const TerminalKeySpec('Ctrl+\\', text: '\x1c'),
    ctrlLetterKey('O'),
    ctrlLetterKey('X'),
  ],
  [ctrlKey, altKey, shiftKey, escapeKey, tabKey, enterKey],
];

/// F 键：F1–F12，加上 Insert/Delete、Home/End、翻页和修饰键（Shift+F5 这种要先按修饰键）。
final _functionRows = <List<TerminalKeySpec?>>[
  functionKeys.sublist(0, 6),
  functionKeys.sublist(6),
  [insertKey, deleteKey, homeKey, endKey, pageUpKey, pageDownKey],
  [ctrlKey, altKey, shiftKey, escapeKey, tabKey, enterKey],
];
