import 'package:flutter/material.dart';

import '../localization/localized_widgets.dart';

// 功能提示：页面上只留控件名和状态，解释收进标题旁的 ⓘ，点开才看。
// 什么该常驻、什么该收进来，见 docs/dev/ui-text.md。

/// 读屏念这个按钮时用的名字。拆成常量是因为本地化覆盖测试按整句查译文，
/// 带插值的中文句子查不到。
const _hintSuffix = '说明';

String hintLabel(String title) {
  final name = localized(title);
  return ShunLocalizations.isEnglish
      ? 'About “$name”'
      : '「$name」${localized(_hintSuffix)}';
}

Future<void> showHint(
  BuildContext context, {
  required String title,
  required String message,
}) =>
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      // 说明有三段长的（AI 工具），横屏或大字号时默认的半屏高度放不下：允许长高，再放不下就滚动。
      // 以前是固定的 Column，溢出时「知道了」被挤出屏幕。
      isScrollControlled: true,
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LText(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            LText(message, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const LText('知道了'),
              ),
            ),
          ],
        ),
      ),
    );

/// 标题旁的 ⓘ。点按区域照常 48dp（UX02 真机量过的下限），图标画小一号，不抢标题。
class HintButton extends StatelessWidget {
  const HintButton({super.key, required this.title, required this.message});

  /// 中文原文，显示时再本地化。
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: hintLabel(title),
        // 不设 visualDensity.compact：它会把下面的 48 压成 40，放进 AppBar 后读屏框就小于 48dp。
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        iconSize: 18,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        onPressed: () => showHint(context, title: title, message: message),
        icon: const Icon(Icons.info_outline),
      );
}

/// 标题 + 紧跟着的 ⓘ。给 ListTile.title、分组标题用；别放进 SwitchListTile
/// （它把子树合成一个读屏节点，ⓘ 就点不到了），开关用 [HintSwitchTile]。
class HintTitle extends StatelessWidget {
  const HintTitle(this.title, {super.key, this.hint, this.style});

  final String title;
  final String? hint;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Flexible(child: LText(title, style: style)),
          if (hint != null) HintButton(title: title, message: hint!),
        ],
      );
}

/// 带 ⓘ 的开关行。外观照 SwitchListTile：点整行切换。
///
/// 读屏上是两个节点：ⓘ 按钮，和带标题的开关。不用 SwitchListTile 是因为它的
/// MergeSemantics 会把 ⓘ 并进开关，TalkBack 用户就打不开说明了。
class HintSwitchTile extends StatelessWidget {
  const HintSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.hint,
    this.subtitle,
    this.secondary,
    this.contentPadding,
  });

  final String title;
  final String? hint;

  /// 只放状态（比如「已选图片」），解释放 [hint]。
  final String? subtitle;
  final Widget? secondary;
  final bool value;

  /// null 时开关变灰，整行不响应。
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onChanged != null;
    return InkWell(
      onTap: enabled ? () => onChanged!(!value) : null,
      // 整行的点按只给看得见的人用；读屏走下面带标题的开关，不重复念两遍。
      excludeFromSemantics: true,
      child: Padding(
        padding: contentPadding ?? const EdgeInsets.symmetric(horizontal: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              if (secondary != null) ...[
                ExcludeSemantics(
                  child: IconTheme.merge(
                    data: IconThemeData(
                        color: theme.colorScheme.onSurfaceVariant),
                    child: secondary!,
                  ),
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: ExcludeSemantics(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LText(title, style: theme.textTheme.bodyLarge),
                              if (subtitle != null)
                                LText(
                                  subtitle!,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (hint != null) HintButton(title: title, message: hint!),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                label: subtitle == null
                    ? localized(title)
                    : '${localized(title)}, ${localized(subtitle!)}',
                child: Switch(value: value, onChanged: onChanged),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
