import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../localization/localized_widgets.dart';
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

/// [ShunButton] 的四种样子，对应 Material 的四种按钮。
enum ShunButtonKind { filled, tonal, outlined, text }

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

  @override
  Widget build(BuildContext context) {
    final action = busy ? null : onPressed;
    final leading = busy
        ? SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: localized('处理中'),
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
              tooltip: localized(_obscured ? '显示密码' : '隐藏密码'),
              onPressed: widget.enabled
                  ? () => setState(() => _obscured = !_obscured)
                  : null,
              icon: Icon(_obscured ? Icons.visibility : Icons.visibility_off),
            ),
          ),
        ),
      );
}

/// 一行：名字、状态（副标题）、右边的开关或 ⓘ。排版用 Prism 的 ListRow。
///
/// 读屏：名字和副标题合成一个节点（可点时是按钮）；[trailing] 里的开关、ⓘ 各是独立节点，
/// 不像 ListTile 套上 MergeSemantics 那样把 ⓘ 吞掉。
class ShunListRow extends StatelessWidget {
  const ShunListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  /// 中文原文，显示时再本地化。
  final String title;

  /// 只写状态，不超过 16 个汉字。
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    final tappable = onTap != null;
    final active = enabled && tappable;
    final dim = enabled ? 1.0 : 0.38;
    // 文字直接交给 LText，不先存进局部变量：UI 规则按参数流向发现副标题的上限，
    // 经过变量就追不到了。
    return Semantics(
      container: true,
      button: tappable,
      enabled: tappable ? enabled : null,
      label: subtitle == null
          ? localized(title)
          : '${localized(title)}, ${localized(subtitle!)}',
      onTap: active ? onTap : null,
      child: InkWell(
        onTap: active ? onTap : null,
        excludeFromSemantics: true,
        child: prism.ListRow(
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
          title: ExcludeSemantics(
            child: LText(
              title,
              style: prism.AppTextStyle.body.of(context).copyWith(
                    color: colors.onSurface.withValues(alpha: dim),
                  ),
            ),
          ),
          subtitle: subtitle == null
              ? null
              : ExcludeSemantics(
                  child: LText(
                    subtitle!,
                    style: prism.AppTextStyle.subheadline.of(context).copyWith(
                          color:
                              colors.onSurfaceVariant.withValues(alpha: dim),
                        ),
                  ),
                ),
          trailing: trailing,
        ),
      ),
    );
  }
}
