import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

/// 让 Prism 分组、分段选择（里面有 LayoutBuilder）躲开 AlertDialog / SimpleDialog 的固有尺寸测量。
///
/// 这两种对话框外面套了 IntrinsicWidth，会向里面每个部件问「最宽、最高要多少」；
/// Prism 分组里有 LayoutBuilder，答不了，直接抛
/// 「LayoutBuilder does not support returning intrinsic dimensions」。
/// 这里对测量一律答 0：对话框宽度由别的部件和最小宽 280 决定，真正排版时仍按实际约束铺满。
/// （SizedBox(width: double.maxFinite) 只在 SimpleDialog 里管用，AlertDialog 的 Column 还会问高度，所以不用它。）
class NoIntrinsics extends SingleChildRenderObjectWidget {
  const NoIntrinsics({super.key, required Widget child}) : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNoIntrinsics();
}

class _RenderNoIntrinsics extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => 0;
}
