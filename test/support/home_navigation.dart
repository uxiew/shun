import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 底栏：Prism 的浮动 NavigationDock（2026-11-21 替掉 R85 的 NavigationBar）。
final homeNavigationBar = find.byKey(const ValueKey('home-navigation-bar'));

/// 底栏第 [index] 个入口，顺序同 `homeTabIds`。
///
/// 浮动底栏的入口只收图形和名字，挂不了 key；它给每个入口一个读屏按钮，按这个找，不按名字找，
/// 中英文界面都能用。
Finder homeNavigationEntry(int index) => find
    .descendant(
      of: homeNavigationBar,
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.button == true,
      ),
    )
    .at(index);
