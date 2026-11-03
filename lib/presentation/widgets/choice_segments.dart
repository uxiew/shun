import 'package:flutter/material.dart';

import '../localization/localized_widgets.dart';

class ChoiceSegment<T> {
  const ChoiceSegment(this.value, this.label, {this.key, this.showsMore = false});

  final T value;

  /// 中文原文，显示时再本地化。
  final String label;
  final Key? key;

  /// 点了不是当场切换，而是再弹一层选项：带个小箭头。
  final bool showsMore;
}

/// 一行互斥的选项，点一下就换，下面的字段跟着变（新建连接的类型、认证方式）。
///
/// 不用 [SegmentedButton]：点已选中的那段它不回调，「更多」选中以后就没法换成别的插件；
/// 英文和大字号下它的文字还会溢出。这里每段等宽，放不下的字缩小，不换行、不溢出。
class ChoiceSegments<T> extends StatelessWidget {
  const ChoiceSegments({
    super.key,
    required this.segments,
    required this.selected,
    required this.onTap,
  });

  final List<ChoiceSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(12);
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          for (final segment in segments)
            Expanded(
              child: _Segment(
                key: segment.key,
                label: segment.label,
                showsMore: segment.showsMore,
                selected: segment.value == selected,
                onTap: () => onTap(segment.value),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.label,
    required this.showsMore,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool showsMore;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;
    final radius = BorderRadius.circular(9);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? theme.colorScheme.secondaryContainer : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            // 外框再加 3dp 内边距，整行 48dp，够手指点。
            constraints: const BoxConstraints(minHeight: 42),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LText(
                        label,
                        maxLines: 1,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: color,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      if (showsMore)
                        Icon(Icons.arrow_drop_down, size: 18, color: color),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
