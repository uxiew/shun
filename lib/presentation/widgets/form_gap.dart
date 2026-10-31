import 'package:flutter/widgets.dart';

/// 表单里上下两个输入框之间的间隔。
///
/// 标签浮起来时压在框的上边框上，往上多占 8dp 左右：间隔 12 看着还是挤，0 就是上一个框直接碰到下一个框的标签。
/// 改这个值所有表单一起变，所以别在表单里写 SizedBox(height: 10)：test/ui_rules_test.dart 会报。
const double formFieldGap = 20;

class FormGap extends SizedBox {
  const FormGap({super.key}) : super(height: formFieldGap);
}
