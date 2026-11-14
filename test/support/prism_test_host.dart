import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shun/presentation/ui/prism_localizations.dart';

// 不经 ShunApp、用裸 MaterialApp 单独装页面的测试，补上 Prism 要的两样：
//
//   MaterialApp(
//     localizationsDelegates: prismTestDelegates,
//     builder: prismTestBuilder,
//     home: …,
//   )
//
// App 里这两样由 ShunUiHost 提供（R82）。缺了：Prism 的搜索框、弹出菜单报
// 「No UiLocalizations found」，分组小标题报「No MeasureScope found」，
// 看着像页面坏了，其实只是测试宿主少了东西（R86、R87 都撞过）。

/// Prism 自己的几句（搜索、清除搜索、对话框……）走 shun 的本地化表，和 App 里一样。
const prismTestDelegates = <LocalizationsDelegate<Object>>[
  ShunPrismLocalizationsDelegate(),
];

/// 线性 1 倍：和 App 在默认字号下一样。
Widget prismTestBuilder(BuildContext context, Widget? child) =>
    prism.MeasureScope(
      measure: prism.Measure.of(context, 1),
      child: child!,
    );
