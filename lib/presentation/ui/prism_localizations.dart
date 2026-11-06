import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../localization/localized_widgets.dart';

/// Prism's built-in labels use the same active language and translation table
/// as LText/localized. ShunUiHost updates that language before building routes.
class ShunPrismLocalizations extends prism.UiLocalizations {
  @override
  String get back => localized('返回');
  @override
  String get cancel => localized('取消');
  @override
  String get clearSearch => localized('清除搜索');
  @override
  String get close => localized('关闭');
  @override
  String get copy => localized('复制');
  @override
  String get cut => localized('剪切');
  @override
  String get dialog => localized('对话框');
  @override
  String get hidePassword => localized('隐藏密码');
  @override
  String get more => localized('更多');
  @override
  String get noSearchResults => localized('无搜索结果');
  @override
  String get paste => localized('粘贴');
  @override
  String get reset => localized('重置');
  @override
  String get select => localized('选择');
  @override
  String get search => localized('搜索');
  @override
  String get selectAll => localized('全选');
  @override
  String get showLess => localized('收起');
  @override
  String get showMore => localized('展开');
  @override
  String get showPassword => localized('显示密码');
  @override
  String get sort => localized('排序');
  @override
  String get submit => localized('提交');
}

class ShunPrismLocalizationsDelegate
    extends LocalizationsDelegate<prism.UiLocalizations> {
  const ShunPrismLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'zh' || locale.languageCode == 'en';

  @override
  Future<prism.UiLocalizations> load(Locale locale) =>
      SynchronousFuture<prism.UiLocalizations>(ShunPrismLocalizations());

  @override
  bool shouldReload(ShunPrismLocalizationsDelegate old) => false;
}
