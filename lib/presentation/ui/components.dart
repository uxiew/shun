import 'package:flutter/material.dart';
import 'package:prism_ui/icons/icons.dart' as glyphs;
import 'package:prism_ui/prism_ui.dart' as prism;

import '../localization/localized_widgets.dart';
import '../widgets/hint.dart';
import '../widgets/secret_content.dart';

// shun 的薄公共控件（R84）。只收各页反复手写、又有固定规矩的几样：
// - 带「处理中」的按钮：各页都是 `onPressed: _busy ? null : …`，有的转圈有的不转，读屏听不出在忙；
// - 秘密输入框：三个输入法开关和防截屏每页自己记，漏一个 secret_content_test 才报；
// - 列表行：Prism 的 ListRow 排版，ⓘ、开关放在 trailing 时读屏仍是独立节点。
// 外观只读 R83 的语义主题（Prism 部件读 prism.Theme，Material 部件读 material_compat 翻译出的主题），
// 这里不定义颜色、字号、圆角。
//
// 没用 Prism 的 TextField / SecretTextFormField：Prism 的 InputDecoration 没有浮动标签（labelText），
// shun 的表单、FormGap 的 20dp 都按浮动标签定；它的 SecretTextFormField 也没关输入法学习
// （test/ui_rules_bypass_test.dart 会报）。按钮同理：Prism 的 TonalButton 只有一种样子、没有忙碌态。
//
// key 约定：调用处给的 key 挂在控件最外层，`find.byKey` 后 tap / enterText 都能用；
// 值写成「页面-字段」（如 `ts-settings-key`），换控件实现时不改 key，测试按 key、语义、行为断言。

/// [ShunButton] 的样子。前四种对应 Material 的四种按钮；[neutral] 是主按钮旁边的次要动作：
/// 高一层的底、正文色的字，不描边、不带主色（Material 的 tonal 在主按钮旁边像第二个强调色）。
enum ShunButtonKind { filled, tonal, neutral, outlined, text }

/// 带忙碌态的按钮。
///
/// [onPressed] 为 null 是禁用；[busy] 为真时图标换成转圈、按钮不响应（防连点重复提交），
/// 读屏在名字前念「处理中」。忙完调用处把 [busy] 改回 false 即可，不用自己换 child。
class ShunButton extends StatelessWidget {
  const ShunButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = ShunButtonKind.filled,
    this.icon,
    this.busy = false,
    this.focusNode,
    this.autofocus = false,
  });

  /// 中文原文，显示时再本地化。
  final String label;
  final VoidCallback? onPressed;
  final ShunButtonKind kind;
  final IconData? icon;
  final bool busy;
  final FocusNode? focusNode;
  final bool autofocus;

  /// [ShunButtonKind.neutral] 的样式。测试、读屏认控件类型的地方还得留着 `FilledButton.tonal`，
  /// 把这个样式给它，和 [ShunButton] 的 neutral 是同一个样子。
  static ButtonStyle neutralStyleOf(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return FilledButton.styleFrom(
      backgroundColor:
          prism.SurfaceContext(context).raisedSurfaceLevel.colorOf(colors),
      foregroundColor: colors.onSurface,
    );
  }

  @override
  Widget build(BuildContext context) {
    final action = busy ? null : onPressed;
    final leading = busy
        ? SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: localizedOf(context, '处理中'),
            ),
          )
        : icon == null
            ? null
            : Icon(icon);
    final child = LText(label);
    return switch (kind) {
      ShunButtonKind.filled => leading == null
          ? FilledButton(
              onPressed: action,
              focusNode: focusNode,
              autofocus: autofocus,
              child: child,
            )
          : FilledButton.icon(
              onPressed: action,
              focusNode: focusNode,
              autofocus: autofocus,
              icon: leading,
              label: child,
            ),
      ShunButtonKind.tonal => leading == null
          ? FilledButton.tonal(
              onPressed: action,
              focusNode: focusNode,
              autofocus: autofocus,
              child: child,
            )
          : FilledButton.tonalIcon(
              onPressed: action,
              focusNode: focusNode,
              autofocus: autofocus,
              icon: leading,
              label: child,
            ),
      ShunButtonKind.neutral => leading == null
          ? FilledButton.tonal(
              onPressed: action,
              focusNode: focusNode,
              autofocus: autofocus,
              style: neutralStyleOf(context),
              child: child,
            )
          : FilledButton.tonalIcon(
              onPressed: action,
              focusNode: focusNode,
              autofocus: autofocus,
              style: neutralStyleOf(context),
              icon: leading,
              label: child,
            ),
      ShunButtonKind.outlined => leading == null
          ? OutlinedButton(
              onPressed: action,
              focusNode: focusNode,
              autofocus: autofocus,
              child: child,
            )
          : OutlinedButton.icon(
              onPressed: action,
              focusNode: focusNode,
              autofocus: autofocus,
              icon: leading,
              label: child,
            ),
      ShunButtonKind.text => leading == null
          ? TextButton(
              onPressed: action,
              focusNode: focusNode,
              autofocus: autofocus,
              child: child,
            )
          : TextButton.icon(
              onPressed: action,
              focusNode: focusNode,
              autofocus: autofocus,
              icon: leading,
              label: child,
            ),
    };
  }
}

/// 密码、口令、token 的输入框：一直关着输入法学习、联想、自动更正（切成明文也关），
/// 显示在屏幕上时窗口防截屏（自带 [SecretContent]，调用处不用再记）。
///
/// [errorText] 非空时标红并念出来；[enabled] 为 false 时框和眼睛按钮都不响应。
class ShunSecretField extends StatefulWidget {
  const ShunSecretField({
    super.key,
    required this.controller,
    required this.label,
    this.helperText,
    this.errorText,
    this.enabled = true,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
  });

  final TextEditingController controller;

  /// 中文原文，显示时再本地化。
  final String label;

  /// 不超过 16 个汉字（test/ui_rules_test.dart 会查到这里）。
  final String? helperText;
  final String? errorText;
  final bool enabled;
  final FocusNode? focusNode;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  @override
  State<ShunSecretField> createState() => _ShunSecretFieldState();
}

class _ShunSecretFieldState extends State<ShunSecretField> {
  var _obscured = true;

  @override
  Widget build(BuildContext context) => SecretContent(
        child: TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          enabled: widget.enabled,
          obscureText: _obscured,
          enableIMEPersonalizedLearning: false,
          enableSuggestions: false,
          autocorrect: false,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: widget.textInputAction,
          onSubmitted: widget.onSubmitted,
          onChanged: widget.onChanged,
          decoration: LInputDecoration(
            labelText: widget.label,
            helperText: widget.helperText,
            errorText: widget.errorText,
            suffixIcon: IconButton(
              tooltip: localizedOf(context, _obscured ? '显示密码' : '隐藏密码'),
              onPressed: widget.enabled
                  ? () => setState(() => _obscured = !_obscured)
                  : null,
              icon: Icon(_obscured ? Icons.visibility : Icons.visibility_off),
            ),
          ),
        ),
      );
}

/// 一行：名字、状态（副标题）、右边的 ⓘ 或箭头。排版用 Prism 的 ListRow；
/// 放在 [ShunSection] 里时画成 FlClash 设置页那种分组卡片（Prism 的 DecorationListItem：
/// 首尾行圆角、行间细线）。
///
/// 读屏：名字和副标题合成一个节点（可点时是按钮；放在分组里时就是 Prism 卡片那个节点）；
/// [trailing] 里的 ⓘ 是独立节点。
/// [trailing] 里放会自己成节点的控件（Material 的 IconButton/Switch、HintButton）；
/// Prism 的 Switch 不自成节点，会被并进整行，开关行用 [ShunSwitchRow]。
class ShunListRow extends StatelessWidget {
  const ShunListRow({
    super.key,
    required this.title,
    this.localizeTitle = true,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.chevron = false,
    this.details,
    this.describeLeading = false,
    this.expanded,
    this.selected,
  });

  /// 中文原文，或不应翻译的外部名称。
  final String title;
  final bool localizeTitle;

  /// 只写状态，不超过 16 个汉字。
  final String? subtitle;

  /// 副标题下面另起的一块：要能选中复制的指纹、现成的地址行这类不是一句话的东西。
  /// 放在分组里时它的字也并进这一行的读屏节点。
  final Widget? details;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 长按（主机行长按出和 ⋮ 一样的菜单）。读屏上是这一行同一个节点的「长按」动作，不另起节点。
  final VoidCallback? onLongPress;
  final bool enabled;

  /// 点了进下一页：右边画 Prism 的「›」（[trailing] 为空时）。
  final bool chevron;

  /// [leading] 带信息时为 true（主机的系统、Telnet/Mosh 角标）：读屏把它的说明念进这一行。
  /// 默认 false，左边图标当装饰不念。
  final bool describeLeading;

  /// 点了展开/收起下面内容的行（树形视图的分组、Tailscale 来源）：读屏报「已展开」「已收起」。
  /// null 表示不是这种行。
  final bool? expanded;

  /// 选一个的列表里的一项（分组、密钥、凭据面板）：true 是当前那项，右边打勾（[trailing] 为空时），
  /// 读屏报「已选中」；false 报「未选中」。null 表示不是这种行。
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    final grouped = prism.ItemPositionProvider.of(context) != null;
    final tappable = onTap != null;
    final active = enabled && tappable;
    final longPress = enabled ? onLongPress : null;
    final dim = enabled ? 1.0 : 0.38;
    final tinted = this.leading == null
        ? null
        : IconTheme.merge(
            data: IconThemeData(
              color: colors.onSurfaceVariant.withValues(alpha: dim),
            ),
            child: this.leading!,
          );
    final leading = tinted == null || describeLeading
        ? tinted
        : ExcludeSemantics(child: tinted);
    final displayTitle = localizeTitle ? localizedOf(context, title) : title;
    Widget buildTitle() => Text(
          displayTitle,
          style: prism.AppTextStyle.body.of(context).copyWith(
                color: colors.onSurface.withValues(alpha: dim),
              ),
        );
    // 文字直接交给 LText，不先存进局部变量：UI 规则按参数流向发现副标题的上限，
    // 经过变量就追不到了。
    final titleText = ExcludeSemantics(
      child: buildTitle(),
    );
    final subtitleText = subtitle == null
        ? null
        : ExcludeSemantics(
            child: LText(
              subtitle!,
              style: prism.AppTextStyle.subheadline.of(context).copyWith(
                    color: colors.onSurfaceVariant.withValues(alpha: dim),
                  ),
            ),
          );
    final trailing = this.trailing ??
        (chevron
            ? ExcludeSemantics(
                child: glyphs.GlyphIcon(
                  glyphs.Glyphs.chevronForward,
                  color: colors.onSurfaceVariant.withValues(alpha: dim),
                ),
              )
            : selected == true
                ? ExcludeSemantics(
                    child: glyphs.GlyphIcon(
                      glyphs.Glyphs.check,
                      color: colors.primary.withValues(alpha: dim),
                    ),
                  )
                : null);
    if (grouped) {
      // Prism 的分组卡片自己就是一个按钮节点（CardSurface 是语义边界，带点按）。名字要落在
      // 同一个节点上：标题、副标题不排除，直接并进卡片节点；外面不再套自己的节点，
      // 否则读屏听到的是「有名字不能点」和「能点没名字」两个节点（R86 清点时实测）。
      // 长按和展开状态同理：标在卡片里面（并进卡片节点）；长按的手势另由外层收，整行都能按。
      // Prism 卡片只在里面有带 onTap 的部件时才让出点按，只挂长按不影响点一下。
      // 选中状态：当前那项交给卡片自己报（isSelected）；没选中的在里面补「未选中」。
      // 两边都标「已选中」会冲突，读屏拆成两个节点（R87 分组 chip 实测）。
      final item = prism.DecorationListItem(
        leading: leading,
        isSelected: selected == true,
        title: Semantics(
          onLongPress: longPress,
          expanded: expanded,
          selected: selected == false ? false : null,
          child: buildTitle(),
        ),
        subtitle: subtitle == null && details == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (subtitle != null)
                    LText(
                      subtitle!,
                      style: prism.AppTextStyle.subheadline
                          .of(context)
                          .copyWith(
                            color:
                                colors.onSurfaceVariant.withValues(alpha: dim),
                          ),
                    ),
                  if (details != null)
                    DefaultTextStyle.merge(
                      style: prism.AppTextStyle.subheadline
                          .of(context)
                          .copyWith(
                            color:
                                colors.onSurfaceVariant.withValues(alpha: dim),
                          ),
                      child: details!,
                    ),
                ],
              ),
        trailing: trailing,
        onPressed: active ? onTap : null,
      );
      if (longPress == null) return item;
      return GestureDetector(
        onLongPress: longPress,
        excludeFromSemantics: true,
        child: item,
      );
    }
    return Semantics(
      container: true,
      button: tappable,
      enabled: tappable ? enabled : null,
      expanded: expanded,
      selected: selected,
      label: subtitle == null
          ? displayTitle
          : '$displayTitle, ${localizedOf(context, subtitle!)}',
      onTap: active ? onTap : null,
      onLongPress: longPress,
      child: InkWell(
        onTap: active ? onTap : null,
        onLongPress: longPress,
        excludeFromSemantics: true,
        child: prism.ListRow(
          leading: leading,
          title: titleText,
          subtitle: details == null
              ? subtitleText
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [if (subtitleText != null) subtitleText, details!],
                ),
          trailing: trailing,
        ),
      ),
    );
  }
}

/// 开关行（放在 [ShunSection] 里）：点整行切换，右边是 Prism 的开关，有 [hint] 时开关左边一个 ⓘ。
///
/// 读屏上和 HintSwitchTile 一样是两个节点：带标题的开关（整行就是它），和能单独点的 ⓘ。
/// Prism 的开关自己的语义排除掉，免得一个开关念两遍。
/// [onChanged] 为 null 时整行变灰、不响应，ⓘ 照样能开。
class ShunSwitchRow extends StatelessWidget {
  const ShunSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.hint,
    this.subtitle,
    this.subtitleIsData = false,
    this.leading,
  });

  /// 中文原文，显示时再本地化。
  final String title;

  /// 点 ⓘ 才看到的说明。
  final String? hint;

  /// 只写状态，不超过 16 个汉字。
  final String? subtitle;

  /// [subtitle] 是数据（主机名、路径）而不是界面文字时为真：原样显示，不查翻译表。
  final bool subtitleIsData;
  final Widget? leading;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final dim = enabled ? 1.0 : 0.38;
    // 整行是 Prism 卡片那个按钮节点：标题并进去，再在里面挂上开关状态；
    // Prism 开关自己的语义排除掉，免得念两遍。ⓘ 是 Material 按钮，自成子节点。
    return prism.DecorationListItem(
      leading: leading == null
          ? null
          : ExcludeSemantics(
              child: IconTheme.merge(
                data: IconThemeData(
                  color: colors.onSurfaceVariant.withValues(alpha: dim),
                ),
                child: leading!,
              ),
            ),
      title: Semantics(
        toggled: value,
        child: LText(
          title,
          style: prism.AppTextStyle.body.of(context).copyWith(
                color: colors.onSurface.withValues(alpha: dim),
              ),
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Builder(
              builder: (context) {
                final style =
                    prism.AppTextStyle.subheadline.of(context).copyWith(
                          color: colors.onSurfaceVariant.withValues(alpha: dim),
                        );
                return subtitleIsData
                    ? Text(subtitle!, style: style)
                    : LText(subtitle!, style: style);
              },
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hint != null) HintButton(title: title, message: hint!),
          ExcludeSemantics(
            child: prism.Switch(value: value, onChanged: onChanged),
          ),
        ],
      ),
      onPressed: enabled ? () => onChanged!(!value) : null,
    );
  }
}

/// 选一个值的行（放在 [ShunSection] 里）：右边是当前值和「⌄」，点整行弹出 Prism 的菜单，
/// 当前值打勾。FlClash 设置页的下拉项就是这样。
///
/// 读屏是一个按钮节点：标题和当前值。[options] 的文字是中文原文，显示时再本地化；
/// [onChanged] 为 null 时整行变灰、不弹菜单。
class ShunOptionsRow<T> extends StatelessWidget {
  const ShunOptionsRow({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    this.leading,
  });

  /// 中文原文，显示时再本地化。
  final String title;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  final Widget? leading;

  String _labelOf(BuildContext context, T value) => localizedOf(
        context,
        options
            .firstWhere((option) => option.$1 == value,
                orElse: () => options.first)
            .$2,
      );

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final dim = enabled ? 1.0 : 0.38;
    prism.PopupOpen? open;
    // 整行是 Prism 卡片那个按钮节点：标题和当前值的字都并进去，读出来是「标题 当前值」。
    return prism.DecorationListItem(
      leading: leading == null
          ? null
          : ExcludeSemantics(
              child: IconTheme.merge(
                data: IconThemeData(
                  color: colors.onSurfaceVariant.withValues(alpha: dim),
                ),
                child: leading!,
              ),
            ),
      title: LText(
        title,
        style: prism.AppTextStyle.body.of(context).copyWith(
              color: colors.onSurface.withValues(alpha: dim),
            ),
      ),
      trailing: prism.PopupAnchor(
        targetBuilder: (popup) {
          open = popup;
          return Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Text(
                _labelOf(context, value),
                style: prism.AppTextStyle.body.of(context).copyWith(
                      color: colors.onSurfaceVariant.withValues(alpha: dim),
                    ),
              ),
              ExcludeSemantics(
                child: glyphs.GlyphIcon(
                  glyphs.Glyphs.picker,
                  color: colors.onSurfaceVariant.withValues(alpha: dim),
                ),
              ),
            ],
          );
        },
        popupBuilder: (_) => prism.PopupMenu(
          items: [
            for (final (option, label) in options)
              prism.PopupMenuItem(
                label: localizedOf(context, label),
                checked: option == value,
                onPressed: () => onChanged?.call(option),
              ),
          ],
        ),
      ),
      onPressed: enabled ? () => open?.call() : null,
    );
  }
}

/// 一组设置：小标题（有 [hint] 时右边一个 ⓘ），下面是连在一起的分组卡片。
/// [children] 里放 [ShunListRow]、[ShunSwitchRow]、[ShunOptionsRow]、[ShunSectionItem]。
/// 没有 [title] 时只留和别的组一样的间距。
class ShunSection extends StatelessWidget {
  const ShunSection({
    super.key,
    this.title,
    required this.children,
    this.hint,
  });

  /// 中文原文，显示时再本地化。
  final String? title;
  final String? hint;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title == null)
            const prism.ListSectionGap()
          else
            Semantics(
              header: true,
              child: prism.ListHeader(
                title: localizedOf(context, title!),
                trailing: hint == null
                    ? null
                    : HintButton(title: title!, message: hint!),
              ),
            ),
          prism.generateGroup(children),
        ],
      );
}

/// 分组里的一块自由内容（滑块、预览、分段选择）：和行一样的卡片底色和首尾圆角，
/// 不是最后一块时底边画一条和行间一样的细线。
class ShunSectionItem extends StatelessWidget {
  const ShunSectionItem({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final position = prism.ItemPositionProvider.of(context)?.position;
    final last = position == null ||
        position == prism.ItemPosition.end ||
        position == prism.ItemPosition.startAndEnd;
    final colors = prism.Theme.of(context).colorScheme;
    final level = prism.SurfaceContext(context).raisedSurfaceLevel;
    // 不用 Prism 的 Card：它不管能不能点都是一个按钮节点，读屏会多出一个「不可用的按钮」。
    // 这里只照它画同样的底色和圆角；整块是一个读屏分组，里面的分段按钮、滑块各自成节点。
    final card = Semantics(
      container: true,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: level.colorOf(colors),
          shape: prism.AppShape.of(prism.listItemRadiusOf(position)),
        ),
        child: prism.SurfaceScope(
          level: level,
          child: DefaultTextStyle.merge(
            style: prism.AppTextStyle.body.of(context).copyWith(
                  color: colors.onSurface,
                ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
    if (last) return card;
    return Stack(
      children: [
        card,
        // 和 Prism 行间细线一样：左边从内容起点画，右边留 14dp。
        PositionedDirectional(
          start: 16,
          end: 14,
          bottom: 0,
          child: Container(height: 0.5, color: prism.Divider.colorOf(context)),
        ),
      ],
    );
  }
}

/// 底栏五个根页面的页头（FlClash 手机页同款）：左边粗体大标题，右边一排圆形按钮。
///
/// 不画底色、不占状态栏：放在页面 SafeArea 里的第一行。[title] 是已本地化的字。
class ShunPageHeader extends StatelessWidget {
  const ShunPageHeader({
    super.key,
    required this.title,
    this.leading,
    this.actions = const [],
  });

  final String title;
  final Widget? leading;
  final List<Widget> actions;

  /// 整条页头的高度，放进 Scaffold 的 appBar 槽时用。
  static const height = 64.0;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      child: SizedBox(
        height: height - 16,
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 10)],
            Expanded(
              // 标题最多放大到 1.34 倍（Prism 页头同一个上限）：再大就撑破这一行，正文照常放大。
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.34,
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: prism.AppTextStyle.title1
                        .of(context, emphasized: true)
                        .copyWith(color: colors.onSurface),
                  ),
                ),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// 页头里的圆形按钮：40dp 的圆落在卡片那一层的底色上，点按范围仍是 48dp。
class ShunBarButton extends StatelessWidget {
  const ShunBarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;

  /// 已本地化的字。
  final String tooltip;
  final VoidCallback? onPressed;

  /// 圆形按钮的样式；[ShunAppBar] 把它套给顶栏里所有的图标按钮。
  static ButtonStyle styleOf(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return IconButton.styleFrom(
      backgroundColor:
          prism.SurfaceContext(context).raisedSurfaceLevel.colorOf(colors),
      foregroundColor: colors.onSurface,
      disabledForegroundColor: colors.onSurface.withValues(alpha: 0.38),
      iconSize: 22,
      fixedSize: const Size.square(40),
      minimumSize: const Size.square(40),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.padded,
      shape: const CircleBorder(),
    );
  }

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: styleOf(context),
        icon: Icon(icon),
      );
}

/// 推入页和整页表单的顶栏：仍是一条 Material AppBar（标题、返回、动作的行为照旧），只是里面的
/// 图标按钮（含自动加的返回、关闭）都成了 [ShunBarButton] 那样的圆形按钮，标题用粗体。
class ShunAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ShunAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.bottom,
  });

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return IconButtonTheme(
      data: IconButtonThemeData(style: ShunBarButton.styleOf(context)),
      child: AppBar(
        title: title,
        actions: actions,
        leading: leading,
        bottom: bottom,
        titleSpacing: 4,
        actionsPadding: const EdgeInsets.only(right: 4),
        titleTextStyle: prism.AppTextStyle.title3
            .of(context, emphasized: true)
            .copyWith(color: colors.onSurface),
      ),
    );
  }
}

/// 中性的小胶囊：分组、标签、数量这类附带信息，落在卡片里再深一层的底上。
///
/// 颜色留给状态：要表示状态时传 [color]，只给字上色，底仍是中性的。[label] 是已本地化的字或数据。
class ShunPill extends StatelessWidget {
  const ShunPill(this.label, {super.key, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: prism.SurfaceContext(context).raisedSurfaceLevel.colorOf(colors),
        shape: prism.AppShape.full,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: prism.AppTextStyle.caption1
              .of(context, emphasized: true)
              .copyWith(color: color ?? colors.onSurfaceVariant),
        ),
      ),
    );
  }
}
