// 模拟「视图量出新尺寸」只能走 flterm 的内部入口：真机上是 flterm 视图布局后调同一个 handleResize。
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:flterm/src/controller/terminal_controller.dart'
    show TerminalSession;
import 'package:flterm/src/foundation/surface_geometry.dart'
    show SurfaceMeasurement;
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';

/// 测试用的终端。R20 起安装包里只有 Ghostty，测试也用它：测到的就是手机上跑的那个引擎。
/// 原版的 xterm2 只在 `xterm_terminal_adapter.dart` 里给对照测试用。
GhosttyTerminalAdapter newTestTerminal() => GhosttyTerminalAdapter();

/// 模拟视图布局后量出 [columns]×[rows]：Ghostty 的网格跟着变，适配器照常把新尺寸交给远端
/// （经 [TerminalSessionAdapterBase] 的合并和节流，和真机一样）。
void resizeTestTerminal(
    TerminalSessionAdapter terminal, int columns, int rows) {
  final controller =
      (terminal as GhosttyTerminalAdapter).controller as TerminalSession;
  controller.handleResize(SurfaceMeasurement(
    cols: columns,
    rows: rows,
    cellWidth: 8,
    cellHeight: 16,
    paddingLeft: 0,
    paddingRight: 0,
    paddingTop: 0,
    paddingBottom: 0,
    devicePixelRatio: 1,
  ));
}
