import 'package:flutter/material.dart';

/// 非模态面板外层的 key：测试按它找面板，不按 BottomSheet 类型找。
const nonModalPanelKey = ValueKey('non-modal-panel');

/// 在 [scaffold] 底部开一个非模态面板（R84，从 Tailscale 设置抽出来，所有者 11-02 定的交互）。
///
/// 不盖遮罩：背后的列表照常能看能点；下滑、返回键关掉它（Scaffold 底部面板自带）。
/// 表面颜色和顶部圆角取 material_compat 的 bottomSheetTheme（即 Prism 的页面层、xxl 圆角），这里不另定。
/// 要让用户确认的事（删除、覆盖）别放这种面板：用普通模态确认框，确认期间背后就该点不动。
///
/// [builder] 拿到的 `close(value)` 关掉面板，并让这次调用返回 value；下滑或返回键关掉时返回 null。
/// 同一个 Scaffold 上再开一个时，先关旧的（旧调用返回 null），再开新的。
/// 页面退掉后 Scaffold 没了，旧面板也等不到关闭，所以只等还在同一个 Scaffold 上的。
Future<T?> showNonModalPanel<T>(
  ScaffoldState scaffold, {
  required Widget Function(BuildContext context, ValueChanged<T?> close)
      builder,
}) async {
  final previous = _openPanel;
  if (previous != null && identical(previous.on, scaffold)) {
    previous.sheet.close();
    await previous.sheet.closed;
    if (!scaffold.mounted) return null;
  }
  T? result;
  late final PersistentBottomSheetController sheet;
  sheet = scaffold.showBottomSheet(
    (context) => KeyedSubtree(
      key: nonModalPanelKey,
      child: builder(context, (value) {
        result = value;
        sheet.close();
      }),
    ),
    // 没有遮罩时靠阴影把面板和背后的列表分开。
    elevation: 12,
  );
  final panel = (on: scaffold, sheet: sheet);
  _openPanel = panel;
  await sheet.closed;
  if (identical(_openPanel, panel)) _openPanel = null;
  return result;
}

({ScaffoldState on, PersistentBottomSheetController sheet})? _openPanel;
