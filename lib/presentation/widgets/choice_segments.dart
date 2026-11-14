import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../localization/localized_widgets.dart';

class ChoiceSegment<T> {
  const ChoiceSegment(this.value, this.label,
      {this.key, this.showsMore = false});

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
/// 英文和大字号下它的文字还会溢出。也不用 Prism 的 SegmentedControl：它高 44dp、不到 48 的点按下限，
/// 长字直接截成省略号，点已选中的那段同样不回调，也没法给每段挂 key。外观（抬一层的底、胶囊形）取 Prism。
///
/// 每段按自己文字的宽度分（R84）：「IPv4 / IPv6 / MagicDNS 名称」等分时长的那段要折行或缩字，
/// 按宽度分就都是一行、原字号。只有整行连原字号都放不下（很窄、很大的字号）时才等分并缩小字，
/// 不换行、不溢出。
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

  /// 外框内边距：加上每段 42dp，整行 48dp，够手指点。
  static const _inset = 3.0;

  /// 每段文字两边留的空。
  static const _padding = 8.0;
  static const _moreIcon = 18.0;

  @override
  Widget build(BuildContext context) {
    final prismTheme = prism.Theme.of(context);
    final background = prism.SurfaceContext(context)
        .raisedSurfaceLevel
        .colorOf(prismTheme.colorScheme);
    // 段宽按本地化后的字量：切语言时要重新量（const 的分段不会因父级重建而重建）。
    Localizations.maybeLocaleOf(context);
    final style = _style(Theme.of(context), selected: true);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final natural = [
      for (final segment in segments)
        _labelWidth(segment, style, scaler, direction),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final room = constraints.maxWidth - _inset * 2;
      final total = natural.fold(0.0, (sum, width) => sum + width);
      final fits = total <= room;
      return Container(
        decoration: ShapeDecoration(
          color: background,
          shape: prism.AppShape.full,
        ),
        padding: const EdgeInsets.all(_inset),
        child: Row(
          children: [
            for (final (index, segment) in segments.indexed)
              Expanded(
                // 放得下：宽度和文字成比例，每段都不比自己的字窄；放不下：等分，字缩小。
                flex: fits ? (natural[index] * 100).round() : 1,
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
    });
  }

  /// 选中时字更粗，按选中的样子量，切换时宽度不跳。
  static double _labelWidth(
    ChoiceSegment<Object?> segment,
    TextStyle? style,
    TextScaler scaler,
    TextDirection direction,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: localized(segment.label), style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width.ceilToDouble() +
        _padding * 2 +
        (segment.showsMore ? _moreIcon : 0);
  }
}

TextStyle? _style(ThemeData theme, {required bool selected}) =>
    theme.textTheme.labelLarge?.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
    );

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
    // 选中色沿用原来的 secondaryContainer，不换成 Prism 原样的 primary 底：R83 记了 36 套主题
    // primary 底上的按钮字不到 4.5:1（证据 2.5 节，留 R96 取舍），换过去就把这个问题带进分段。
    final color = selected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;
    const shape = StadiumBorder();
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? theme.colorScheme.secondaryContainer
            : Colors.transparent,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: ConstrainedBox(
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
                        style: _style(theme, selected: selected)
                            ?.copyWith(color: color),
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
