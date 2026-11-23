import 'dart:async';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:prism_ui/prism_ui.dart' as prism;

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

  /// 按住连发（方向键、PgUp/PgDn、退格）：按住 400ms 后按 [TerminalKeyFeel.repeatInterval] 连发。
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

/// 按键手感（R45）。设置页改的，快捷键栏和按键面板都读。外面没有这一层（别的页面、测试）就是默认值。
class TerminalKeyFeel extends InheritedWidget {
  const TerminalKeyFeel({
    super.key,
    this.height = 48,
    this.haptics = false,
    this.repeatInterval = const Duration(milliseconds: 70),
    required super.child,
  });

  /// 快捷键栏每行多高。面板里的键不看它：它们按面板高度分，本来就比这高。
  final double height;
  final bool haptics;
  final Duration repeatInterval;

  static const _fallback = TerminalKeyFeel(child: SizedBox.shrink());

  /// 手指还按着时也会调到（连发），不能建依赖，所以用 get。
  static TerminalKeyFeel of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TerminalKeyFeel>() ?? _fallback;

  @override
  bool updateShouldNotify(TerminalKeyFeel oldWidget) =>
      height != oldWidget.height ||
      haptics != oldWidget.haptics ||
      repeatInterval != oldWidget.repeatInterval;
}

/// 一个键的样子和手感：至少 48dp（UX02），可连发的键按住连发。
///
/// 键帽是比所在表面高一层的底色（R94）：没有描边，亮着的修饰键换成主色，按下时再深一层。
/// 键帽比点按范围四边各小 [_capInset]：360dp 宽的手机上格子只有 49dp，相邻的键帽也不会连成一片，
/// 点按范围仍是整个格子。
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

  static const _capInset = 2.0;

  @override
  State<TerminalKeyButton> createState() => _TerminalKeyButtonState();
}

class _TerminalKeyButtonState extends State<TerminalKeyButton> {
  Timer? _repeatDelay;
  Timer? _repeatTimer;
  int? _repeatPointer;
  Offset? _repeatOrigin;
  bool _suppressNextTap = false;

  @override
  void didUpdateWidget(covariant TerminalKeyButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一个位置换了键（切到有专用布局的主机）：手指还按着也要停，不然连发的就成了新键。
    if (!identical(oldWidget.spec, widget.spec)) {
      _stopRepeating(clearTapSuppression: true);
    }
  }

  @override
  void dispose() {
    _stopRepeating(clearTapSuppression: true);
    super.dispose();
  }

  void _pressFeedback() {
    if (TerminalKeyFeel.of(context).haptics) {
      unawaited(HapticFeedback.selectionClick());
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final selected = widget.selected;
    final colors = prism.Theme.of(context).colorScheme;
    final cap = prism.SurfaceContext(context).raisedSurfaceLevel;
    return Semantics(
      button: true,
      selected: selected,
      onLongPressHint: widget.onLongPressHint == null
          ? null
          : localized(widget.onLongPressHint!),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: spec.repeatable
            ? (event) => _startRepeating(event.pointer, event.position)
            : null,
        onPointerMove: spec.repeatable ? _onPointerMove : null,
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
            backgroundColor: Colors.transparent,
            foregroundColor: selected ? colors.onPrimary : colors.onSurface,
            // 按下的反馈画在键帽上（见下），不要盖住整个格子的水波。
            overlayColor: Colors.transparent,
            shape: prism.AppShape.sm,
            backgroundBuilder: (context, states, child) => Padding(
              padding: const EdgeInsets.all(TerminalKeyButton._capInset),
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: selected
                      ? colors.primary
                      : (states.contains(WidgetState.pressed) ? cap.next : cap)
                          .colorOf(colors),
                  shape: prism.AppShape.sm,
                ),
                child: child,
              ),
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
                    // 只有一个符号的键（↑、⏎、|）字放大：14sp 的箭头细得几乎看不清。
                    style: spec.label.runes.length == 1
                        ? const TextStyle(fontSize: 20)
                        : null,
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
    _pressFeedback();
    widget.onPressed(widget.spec);
  }

  void _startRepeating(int pointer, Offset origin) {
    if (_repeatPointer != null) return;
    _repeatPointer = pointer;
    _repeatOrigin = origin;
    _repeatDelay = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || _repeatPointer != pointer) return;
      _suppressNextTap = true;
      _pressFeedback();
      widget.onPressed(widget.spec);
      _repeatTimer = Timer.periodic(
        TerminalKeyFeel.of(context).repeatInterval,
        (_) {
          if (mounted && _repeatPointer == pointer) {
            widget.onPressed(widget.spec);
          }
        },
      );
    });
  }

  /// 手指从键上起步滑走（按键面板左右滑着切到大输入框、快捷键栏一行时左右滑）：还没开始连发就不连发了。
  /// 已经在连发的不停——按住方向键时手指难免挪一点。
  void _onPointerMove(PointerMoveEvent event) {
    final origin = _repeatOrigin;
    if (_repeatPointer != event.pointer || origin == null) return;
    if (_repeatTimer != null) return;
    if ((event.position - origin).distance > kTouchSlop) {
      _stopRepeating(clearTapSuppression: false);
    }
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
    _repeatOrigin = null;
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
