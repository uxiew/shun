import 'package:flterm/flterm.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

/// Android 上 scanCode 为 0 的按键，Flutter 给的物理键是合成值：0x11_0000_0000 + Android keyCode。
/// Gboard 软键盘的退格、adb `input keyevent`、部分蓝牙键盘/遥控器都是这种。
const _androidPlane = 0x1100000000;
const _planeMask = 0xFF00000000;

/// 物理键是 Android 合成值时，按逻辑键补发给终端；否则返回 ignored，交回 flterm 自己的路径。
///
/// 为什么要有：flterm 0.0.5 只按物理键查表（keyFromPhysical），合成值一律认不出，
/// 编码结果为空就直接 ignored——实测 Gboard 点退格 0 字节（用户删不了字），
/// adb 注入的方向键/Esc/Tab/Ctrl 组合 0 字节。fork 已把编辑、导航键和字母的兜底并进 flterm，
/// 这里留着兜 Ctrl/Alt+数字等 fork 没收的键，也保持 R04 测过的组合。
///
/// 只接管合成物理键：真实硬件键盘带 scanCode，仍由 flterm 处理，避免同一次按键发两遍。
/// 带字符且无 Ctrl/Alt 的键（adb `input text`）flterm 按字符能编码，也不接管。
KeyEventResult androidKeyFallback(TerminalController controller, KeyEvent e) {
  if (e.physicalKey.usbHidUsage & _planeMask != _androidPlane) {
    return KeyEventResult.ignored;
  }
  final kb = HardwareKeyboard.instance;
  final ctrl = kb.isControlPressed, alt = kb.isAltPressed;
  final key = _named[e.logicalKey] ?? ((ctrl || alt) ? _letterOrDigit(e.logicalKey) : null);
  if (key == null) return KeyEventResult.ignored;
  // 抬起也吞掉：否则 Flutter 会把未处理的键还给平台输入连接，退格可能再删一次哨兵字符。
  if (e is KeyUpEvent) return KeyEventResult.handled;
  var mods = const Mods.none();
  if (kb.isShiftPressed) mods = mods | const Mods.shift();
  if (ctrl) mods = mods | const Mods.ctrl();
  if (alt) mods = mods | const Mods.alt();
  if (kb.isMetaPressed) mods = mods | const Mods.superKey();
  controller.sendKey(key, mods: mods);
  return KeyEventResult.handled;
}

final _named = <LogicalKeyboardKey, Key>{
  LogicalKeyboardKey.backspace: Key.backspace,
  LogicalKeyboardKey.enter: Key.enter,
  LogicalKeyboardKey.numpadEnter: Key.numpadEnter,
  LogicalKeyboardKey.tab: Key.tab,
  LogicalKeyboardKey.escape: Key.escape,
  LogicalKeyboardKey.arrowUp: Key.arrowUp,
  LogicalKeyboardKey.arrowDown: Key.arrowDown,
  LogicalKeyboardKey.arrowLeft: Key.arrowLeft,
  LogicalKeyboardKey.arrowRight: Key.arrowRight,
  LogicalKeyboardKey.home: Key.home,
  LogicalKeyboardKey.end: Key.end,
  LogicalKeyboardKey.pageUp: Key.pageUp,
  LogicalKeyboardKey.pageDown: Key.pageDown,
  LogicalKeyboardKey.insert: Key.insert,
  LogicalKeyboardKey.delete: Key.delete,
  LogicalKeyboardKey.f1: Key.f1,
  LogicalKeyboardKey.f2: Key.f2,
  LogicalKeyboardKey.f3: Key.f3,
  LogicalKeyboardKey.f4: Key.f4,
  LogicalKeyboardKey.f5: Key.f5,
  LogicalKeyboardKey.f6: Key.f6,
  LogicalKeyboardKey.f7: Key.f7,
  LogicalKeyboardKey.f8: Key.f8,
  LogicalKeyboardKey.f9: Key.f9,
  LogicalKeyboardKey.f10: Key.f10,
  LogicalKeyboardKey.f11: Key.f11,
  LogicalKeyboardKey.f12: Key.f12,
};

/// Ctrl/Alt 组合里的字母数字：逻辑键 id 就是小写 ASCII 码。
Key? _letterOrDigit(LogicalKeyboardKey k) {
  final id = k.keyId;
  if (id >= 0x61 && id <= 0x7a) return Key.values.byName(String.fromCharCode(id));
  if (id >= 0x30 && id <= 0x39) return Key.values.byName('digit${id - 0x30}');
  return null;
}
