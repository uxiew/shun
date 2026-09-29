import 'package:flterm/flterm.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/widgets.dart';

/// 轻点终端时，如果软键盘没在显示，就把它叫回来。
///
/// 为什么要有：flterm 0.0.5 自己记一份键盘状态。系统收起键盘（返回键、切到别的 App 再回来）
/// 时它不知道，仍记为 showing，于是 showKeyboard() 成了空操作；点终端只 requestFocus，
/// 焦点没变也不会触发弹键盘。模拟器实测：按返回收起后连点两次终端，键盘都不出来。
///
/// 用 Listener 而不是 GestureDetector：TerminalView 里已有点按识别器，外层再加一个会在手势竞技场里输掉。
/// 位移超过 kTouchSlop 算滚动/选择，不弹键盘。
class KeyboardReshow extends StatefulWidget {
  const KeyboardReshow({
    super.key,
    required this.controller,
    required this.child,
  });

  final TerminalController controller;
  final Widget child;

  @override
  State<KeyboardReshow> createState() => _KeyboardReshowState();
}

class _KeyboardReshowState extends State<KeyboardReshow> {
  Offset? _down;

  void _onUp(PointerUpEvent e) {
    final down = _down;
    _down = null;
    if (down == null || (e.position - down).distance > kTouchSlop) return;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) return; // 键盘已在显示
    // 先 hide 再 show，只走公开接口，让 flterm 内部状态和实际一致。
    widget.controller
      ..hideKeyboard()
      ..showKeyboard();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (e) => _down = e.position,
    onPointerUp: _onUp,
    onPointerCancel: (_) => _down = null,
    child: widget.child,
  );
}
