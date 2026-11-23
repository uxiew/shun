import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../ui/components.dart';

/// 管理页里的一张卡（R91）：Prism 分组卡片的底色和圆角，替掉 Material 的 Card。
/// 用 [ShunSectionItem] 画，不用 Prism 的 Card：那个不管能不能点都是一个按钮节点，
/// 读屏会多出一个「不可用的按钮」。里面的展开头、行、图标按钮照旧各自成节点。
class ManagementCard extends StatelessWidget {
  const ManagementCard({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.all(4),
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: margin,
        child: prism.ItemPositionProvider(
          position: prism.ItemPosition.startAndEnd,
          child: ShunSectionItem(
            padding: padding,
            // 里面的 ListTile、ExpansionTile 要一个 Material 祖先画水波，底色由卡片给。
            child: Builder(
                builder: (context) => Material(
                      type: MaterialType.transparency,
                      child: ExpansionTileTheme(
                        data: ExpansionTileTheme.of(context).copyWith(
                          shape: prism.AppShape.md,
                          collapsedShape: prism.AppShape.md,
                        ),
                        child: IconButtonTheme(
                          data: IconButtonThemeData(
                              style: ShunBarButton.styleOf(context)),
                          child: child,
                        ),
                      ),
                    )),
          ),
        ),
      );
}
