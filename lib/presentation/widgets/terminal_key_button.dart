import 'dart:async';

import 'package:flutter/material.dart';

import '../../infrastructure/terminal/terminal_input_controller.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import '../localization/localized_widgets.dart';

/// 快捷键栏（R18）和按键面板（R25）共用的一个键：它是什么、按下去发什么。
///
/// 发什么只有三条路，都走终端页给的出口（`SessionController.pressKey` / `typeInto` / 粘贴预览），不另开发送路径：
/// - [special]：功能键，交给引擎按远端当前的键盘模式编码（vim、less 打开应用光标键后方向键要发 `ESC O A`）；
/// - [text]：按打字发，经过快捷键栏的一次性修饰键，和真按键一样（Ctrl 亮着按 `[` 就是 Esc）；
/// - [paste]：粘贴，交给终端页读剪贴板、按内容决定直接粘贴还是先预览（R19）。
/// [modifier] 是 Ctrl/Alt/Shift：按一下亮起，只管下一个键（R18）。
@immutable
class TerminalKeySpec {
  const TerminalKeySpec(
    this.label, {
    this.text,
    this.special,
    this.modifier,
    this.paste = false,
    this.icon,
    this.repeatable = false,
    this.semanticsLabel,
    this.decodeEscapes = false,
  });

  /// 键上写的字。
  final String label;
  final String? text;
  final TerminalSpecialKey? special;

  /// `ctrl`、`alt`、`shift`。
  final String? modifier;
  final bool paste;
  final IconData? icon;

  /// 按住连发（方向键、PgUp/PgDn、退格）：按住 400ms 后每 70ms 发一次。
  final bool repeatable;

  /// 读屏软件念的名字。键上只有一个符号（`|`、`↑`）时给它，不然 TalkBack 可能念不出来或念成别的。
  final String? semanticsLabel;

  /// [text] 里的 `\n`、`\t`、`\e`、`\xNN` 按转义解开：只有用户自己加的快捷键这样写。
  final bool decodeEscapes;
}

/// 按下一个键做什么。快捷键栏和按键面板各拿一份，发给同一个终端（分屏时是用户点过的那一格）。
class TerminalKeyActions {
  const TerminalKeyActions({
    required this.input,
    required this.onKey,
    required this.onText,
    this.onPaste,
  });

  /// 那一格终端的一次性修饰键。快捷键栏和面板上的 Ctrl 亮不亮都看它。
  final TerminalInputController input;
  final void Function(TerminalSpecialKey key) onKey;
  final void Function(String text) onText;
  final VoidCallback? onPaste;

  bool isSelected(TerminalKeySpec spec) =>
      spec.modifier != null && input.modifiers.contains(spec.modifier);

  void press(TerminalKeySpec spec) {
    final modifier = spec.modifier;
    if (modifier != null) {
      final next = {...input.modifiers};
      if (!next.add(modifier)) next.remove(modifier);
      input.setModifiers(next);
      return;
    }
    if (spec.special case final special?) {
      onKey(special);
      return;
    }
    if (spec.paste) {
      // 不按打字发（换行就是回车、多行逐行执行）：交给终端页走粘贴（R19）。
      input.clearModifiers();
      onPaste?.call();
      return;
    }
    final raw = spec.text ?? '';
    final text = spec.decodeEscapes ? decodeTerminalKeyEscapes(raw) : raw;
    if (text.isNotEmpty) onText(text);
  }
}

/// 一个键的样子和手感：至少 48dp（UX02），修饰键亮着时有底色，可连发的键按住连发。
class TerminalKeyButton extends StatefulWidget {
  const TerminalKeyButton({
    super.key,
    required this.spec,
    required this.selected,
    required this.onPressed,
    this.onLongPress,
    this.onLongPressHint,
  });

  final TerminalKeySpec spec;
  final bool selected;
  final ValueChanged<TerminalKeySpec> onPressed;

  /// 不可连发的键的长按（快捷键栏的「粘贴」长按打开多行编辑框）。
  final VoidCallback? onLongPress;
  final String? onLongPressHint;

  @override
  State<TerminalKeyButton> createState() => _TerminalKeyButtonState();
}

class _TerminalKeyButtonState extends State<TerminalKeyButton> {
  Timer? _repeatDelay;
  Timer? _repeatTimer;
  int? _repeatPointer;
  bool _suppressNextTap = false;

  @override
  void dispose() {
    _stopRepeating(clearTapSuppression: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final selected = widget.selected;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      onLongPressHint: widget.onLongPressHint == null
          ? null
          : localized(widget.onLongPressHint!),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown:
            spec.repeatable ? (event) => _startRepeating(event.pointer) : null,
        onPointerUp:
            spec.repeatable ? (event) => _endRepeating(event.pointer) : null,
        onPointerCancel:
            spec.repeatable ? (event) => _endRepeating(event.pointer) : null,
        child: TextButton(
          onPressed: _handleTap,
          onLongPress: widget.onLongPress,
          style: TextButton.styleFrom(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: selected ? scheme.primaryContainer : null,
            foregroundColor:
                selected ? scheme.onPrimaryContainer : scheme.onSurface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: spec.icon == null
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  child: LText(
                    spec.label,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    semanticsLabel: spec.semanticsLabel,
                  ),
                )
              : Tooltip(
                  message: localized(spec.label),
                  // 有长按动作的键（「粘贴」）提示不抢长按。
                  triggerMode: widget.onLongPress != null
                      ? TooltipTriggerMode.manual
                      : null,
                  child: Icon(spec.icon, size: 20),
                ),
        ),
      ),
    );
  }

  void _handleTap() {
    if (widget.spec.repeatable && _suppressNextTap) {
      _suppressNextTap = false;
      return;
    }
    widget.onPressed(widget.spec);
  }

  void _startRepeating(int pointer) {
    if (_repeatPointer != null) return;
    _repeatPointer = pointer;
    _repeatDelay = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || _repeatPointer != pointer) return;
      _suppressNextTap = true;
      widget.onPressed(widget.spec);
      _repeatTimer = Timer.periodic(
        const Duration(milliseconds: 70),
        (_) {
          if (mounted && _repeatPointer == pointer) {
            widget.onPressed(widget.spec);
          }
        },
      );
    });
  }

  void _endRepeating(int pointer) {
    if (_repeatPointer != pointer) return;
    final suppressTap = _suppressNextTap;
    _stopRepeating(clearTapSuppression: false);
    if (suppressTap) {
      // TextButton resolves its tap after the pointer-up dispatch. Clear the
      // guard on the next event-loop turn in case the long press was cancelled
      // and no tap callback is produced.
      Timer.run(() => _suppressNextTap = false);
    }
  }

  void _stopRepeating({required bool clearTapSuppression}) {
    _repeatDelay?.cancel();
    _repeatTimer?.cancel();
    _repeatDelay = null;
    _repeatTimer = null;
    _repeatPointer = null;
    if (clearTapSuppression) _suppressNextTap = false;
  }
}

/// 自定义快捷键里的转义：`\e`、`\n`、`\r`、`\t`、`\xNN`、`\\`。
String decodeTerminalKeyEscapes(String input) {
  var value = input
      .replaceAll(r'\e', '\x1b')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\t', '\t');
  value = value.replaceAllMapped(
    RegExp(r'\\x([0-9a-fA-F]{2})'),
    (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
  );
  return value.replaceAll(r'\\', '\\');
}
