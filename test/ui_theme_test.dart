import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as p;
import 'package:shun/domain/models/settings.dart';
import 'package:shun/presentation/terminal/ghostty_terminal_view.dart';
import 'package:shun/presentation/theme.dart';
import 'package:shun/presentation/ui/material_compat.dart';
import 'package:shun/presentation/ui/prism_theme.dart';
import 'package:shun/presentation/widgets/form_gap.dart';

// R83 / UIM04：同一套主题设置只生成一个语义主题，Prism 和 Material 两种表示从它翻译。
// 这里只查映射本身；宿主里切换、终端同步、草稿与焦点的行为在 ui_host_test.dart 和
// terminal_detached_theme_test.dart。
void main() {
  final all = [
    for (final brightness in Brightness.values)
      ...ShunTheme.presets(brightness),
  ];

  test('124 套预设：Material 颜色角色与 Prism 逐个相同，页面/卡片/块/内嵌按 Prism 层级落位', () {
    expect(all, hasLength(124));
    for (final preset in all) {
      final ui = ShunUiTheme.resolve(preset.brightness, preset.id);
      final reason = '${preset.brightness.name}/${preset.id}';
      expect(ui.preset, same(preset), reason: reason);
      final colors = ui.colorScheme;
      final material = materialThemeFor(ui);
      expect(_roles(material.colorScheme), _prismRoles(colors), reason: reason);
      expect(ui.prismTheme.colorScheme, same(colors));

      // 预设的页面、卡片、主色、边框是主题身份，原样保留。
      expect(p.SurfaceLevel.page.colorOf(colors), preset.background,
          reason: reason);
      expect(p.SurfaceLevel.card.colorOf(colors), preset.card, reason: reason);
      expect(ui.prismTheme.scaffoldBackgroundColor, preset.background);
      expect(material.scaffoldBackgroundColor, preset.background);
      expect(material.appBarTheme.backgroundColor, preset.background);
      expect(material.cardTheme.color, preset.card);
      expect(colors.primary, preset.primary);
      expect(colors.outline, preset.border);
      // 终端底色（也是 OSC 11 的回答）读 surface：浅色是卡片，深色是页面。
      expect(
        colors.surface,
        preset.brightness == Brightness.dark ? preset.background : preset.card,
        reason: reason,
      );

      // 层次单调：深色往上越来越亮，浅色卡片最亮、往内越来越暗。
      final page = p.SurfaceLevel.page.colorOf(colors).tone;
      final card = p.SurfaceLevel.card.colorOf(colors).tone;
      final block = colors.surfaceContainerHigh.tone;
      final inset = p.SurfaceLevel.inset.colorOf(colors).tone;
      if (preset.brightness == Brightness.dark) {
        expect(page, lessThanOrEqualTo(card + 0.01), reason: reason);
        expect(card, lessThan(block), reason: reason);
        expect(block, lessThan(inset), reason: reason);
      } else {
        expect(card, greaterThanOrEqualTo(page - 0.01), reason: reason);
        expect(page, greaterThan(block), reason: reason);
        expect(block, greaterThan(inset), reason: reason);
      }
    }
  });

  test('正文、次要文字、错误色在页面和卡片上都够 4.5:1；本来就够的预设颜色原样保留', () {
    for (final preset in all) {
      final colors =
          ShunUiTheme.resolve(preset.brightness, preset.id).colorScheme;
      final reason = '${preset.brightness.name}/${preset.id}';
      for (final (role, color) in [
        ('onSurface', colors.onSurface),
        ('onSurfaceVariant', colors.onSurfaceVariant),
        ('error', colors.error),
      ]) {
        for (final background in [preset.background, preset.card]) {
          expect(_contrast(color, background), greaterThanOrEqualTo(4.5),
              reason: '$reason $role');
        }
      }
      if (_worst(preset.foreground, preset) >= 4.5) {
        expect(colors.onSurface, preset.foreground, reason: reason);
      }
      if (_worst(preset.error, preset) >= 4.5) {
        expect(colors.error, preset.error, reason: reason);
      }
      // 没够的只沿 HCT 色调挪：HCT 色相不变，换算成 HSL 色相在 0° 附近的红色上会漂几度
      // （11-06 实测 74 个被挪的颜色最大 6.0°）。超过 8° 说明不只是换了明暗。
      // 无彩色的灰黑白没有色相可比，跳过。
      for (final (given, used) in [
        (preset.foreground, colors.onSurface),
        (preset.error, colors.error),
      ]) {
        if (given != used && _chroma(given) > 8 && _chroma(used) > 8) {
          expect(_hueDistance(given, used), lessThan(8), reason: reason);
        }
        if (given != used) {
          // 浅色主题只会变暗、深色主题只会变亮。
          expect(
            used.tone > given.tone,
            preset.brightness == Brightness.dark,
            reason: reason,
          );
        }
      }
      final onPrimary =
          p.ThemeData.estimateBrightnessForColor(preset.primary) ==
                  Brightness.light
              ? const Color(0xFF000000)
              : const Color(0xFFFFFFFF);
      expect(colors.onPrimary, onPrimary, reason: reason);
      // R81 按亮度 0.46 分黑白。以后换判断可以，但哪一套的按钮字都不能比那时更淡。
      final before = preset.primary.computeLuminance() > 0.46
          ? const Color(0xFF000000)
          : const Color(0xFFFFFFFF);
      expect(
        _contrast(colors.onPrimary, preset.primary),
        greaterThanOrEqualTo(_contrast(before, preset.primary)),
        reason: reason,
      );
    }
  });

  test('字阶：Material 15 个角色都是 Prism AppTextStyle 的某一档，字体族同 Prism，终端仍是等宽', () {
    for (final brightness in Brightness.values) {
      final ui = ShunUiTheme.resolve(brightness, 'tokyo-night');
      final material = materialThemeFor(ui);
      final text = material.textTheme;
      final expected = <String, (TextStyle?, p.AppTextStyle, bool)>{
        'displayLarge': (text.displayLarge, p.AppTextStyle.display, false),
        'displayMedium': (text.displayMedium, p.AppTextStyle.display, false),
        'displaySmall': (text.displaySmall, p.AppTextStyle.largeTitle, false),
        'headlineLarge': (text.headlineLarge, p.AppTextStyle.largeTitle, false),
        'headlineMedium': (text.headlineMedium, p.AppTextStyle.title1, false),
        'headlineSmall': (text.headlineSmall, p.AppTextStyle.pageTitle, false),
        'titleLarge': (text.titleLarge, p.AppTextStyle.title2, false),
        'titleMedium': (text.titleMedium, p.AppTextStyle.callout, true),
        'titleSmall': (text.titleSmall, p.AppTextStyle.subheadline, true),
        'bodyLarge': (text.bodyLarge, p.AppTextStyle.callout, false),
        'bodyMedium': (text.bodyMedium, p.AppTextStyle.subheadline, false),
        'bodySmall': (text.bodySmall, p.AppTextStyle.caption1, false),
        'labelLarge': (text.labelLarge, p.AppTextStyle.subheadline, true),
        'labelMedium': (text.labelMedium, p.AppTextStyle.caption1, true),
        'labelSmall': (text.labelSmall, p.AppTextStyle.caption2, true),
      };
      for (final MapEntry(key: role, value: (style, step, emphasized))
          in expected.entries) {
        final family = (step.size < p.AppTextStyle.title3.size
                ? ui.prismTheme.bodyTextStyle
                : ui.prismTheme.displayTextStyle)
            .fontFamily;
        expect(style!.fontSize, step.size, reason: role);
        expect(style.height, step.leading / step.size, reason: role);
        expect(
            style.fontWeight, emphasized ? step.emphasizedWeight : step.weight,
            reason: role);
        expect(style.letterSpacing, 0, reason: role);
        expect(style.fontFamily, family, reason: role);
        expect(style.fontFamily, isNot('monospace'), reason: role);
        expect(style.color, ui.colorScheme.onSurface, reason: role);
      }
      // 终端的等宽字体不跟界面字体走。
      expect(terminalColorsFor(material.colorScheme).fontFamily, 'monospace');
    }
  });

  test('形状、弹层表面、密度都取 Prism 公开值；FormGap 仍是 20dp', () {
    for (final brightness in Brightness.values) {
      final ui = ShunUiTheme.resolve(brightness, 'tokyo-night');
      final colors = ui.colorScheme;
      final material = materialThemeFor(ui);
      expect(
        material.cardTheme.shape,
        p.AppShape.md.copyWith(side: BorderSide(color: colors.outlineVariant)),
      );
      final input = material.inputDecorationTheme;
      expect(
          (input.border! as OutlineInputBorder).borderRadius, p.AppRadius.md);
      expect((input.enabledBorder! as OutlineInputBorder).borderRadius,
          p.AppRadius.md);
      expect(input.fillColor, p.SurfaceLevel.card.colorOf(colors));
      expect(material.dialogTheme.shape, p.AppShape.all(p.AppCorner.alert));
      expect(material.bottomSheetTheme.shape, p.AppShape.top(p.AppCorner.xxl));
      expect(material.popupMenuTheme.shape, p.AppShape.md);
      expect(material.chipTheme.shape, p.AppShape.sm);
      // 弹窗/菜单在 floating 层，底部面板在抬起后的页面层，遮罩用 Prism 的暗度。
      final floating = p.SurfaceLevel.floatingOf(colors).colorOf(colors);
      expect(material.dialogTheme.backgroundColor, floating);
      expect(material.popupMenuTheme.color, floating);
      expect(material.canvasColor, floating);
      expect(material.bottomSheetTheme.backgroundColor,
          p.SurfaceLevel.page.colorOf(ui.prismTheme.elevated.colorScheme));
      expect(material.dialogTheme.barrierColor, colors.alertScrim);
      expect(material.bottomSheetTheme.modalBarrierColor, colors.modalScrim);
      expect(material.dividerTheme.color, colors.outlineVariant);
      expect(material.snackBarTheme.backgroundColor, colors.inverseSurface);
      expect(material.snackBarTheme.contentTextStyle?.color,
          colors.onInverseSurface);
      expect(
        material.visualDensity,
        VisualDensity(
          horizontal: ui.prismTheme.visualDensity.horizontal,
          vertical: ui.prismTheme.visualDensity.vertical,
        ),
      );
      expect(ui.prismTheme.tapTargetSize, p.TapTargetSize.padded);
      expect(material.materialTapTargetSize, MaterialTapTargetSize.padded);
    }
    expect(formFieldGap, 20);
    expect(const FormGap().height, 20);
  });

  test('展开动效用 Prism 公开时长，减少动画时直接到位；同一设置拿到同一个对象', () {
    final ui = ShunUiTheme.resolve(Brightness.light, 'snow');
    expect(ShunUiTheme.resolve(Brightness.light, 'snow'), same(ui));
    final normal = materialThemeFor(ui);
    final reduced = materialThemeFor(ui, reduceMotion: true);
    expect(materialThemeFor(ui), same(normal));
    expect(materialThemeFor(ui, reduceMotion: true), same(reduced));
    final style = normal.expansionTileTheme.expansionAnimationStyle!;
    expect(style.duration, p.UnfoldEntryTransition.duration);
    expect(style.curve, Curves.easeOutCubic);
    expect(style.reverseCurve, Curves.easeInCubic);
    expect(reduced.expansionTileTheme.expansionAnimationStyle,
        AnimationStyle.noAnimation);
    // 减少动画只影响动效，颜色、字阶、形状不变。
    expect(reduced.colorScheme, normal.colorScheme);
    expect(reduced.textTheme, normal.textTheme);
    expect(reduced.cardTheme, normal.cardTheme);
  });

  test('旧 uiThemeId：每个 ID 落回原预设；只在另一亮暗里有或认不出的 ID 走 snow/midnight；存储格式不变', () {
    for (final preset in all) {
      expect(ShunUiTheme.resolve(preset.brightness, preset.id).preset,
          same(preset));
    }
    expect(ShunUiTheme.resolve(Brightness.light, 'midnight').preset.id, 'snow');
    expect(ShunUiTheme.resolve(Brightness.dark, 'snow').preset.id, 'midnight');
    expect(ShunUiTheme.resolve(Brightness.light, '').preset.id, 'snow');
    expect(ShunUiTheme.resolve(Brightness.dark, 'gone').preset.id, 'midnight');
    const defaults = AppSettings();
    for (final brightness in Brightness.values) {
      expect(ShunUiTheme.resolve(brightness, defaults.uiThemeId).preset.id,
          'tokyo-night');
    }
    final stored = AppSettings.fromJson({
      'themeMode': 'system',
      'uiThemeId': 'no-such-theme',
      'customBackgroundEnabled': true,
      'customBackgroundPath': '/app/bg.png',
      'customBackgroundOpacity': 0.65,
      'terminalFontSize': 18,
    });
    // 读写不替用户改值：认不出的 ID 只在显示时落回，存着的还是原值。
    expect(stored.toJson()['uiThemeId'], 'no-such-theme');
    expect(stored.toJson()['themeMode'], 'system');
    expect(stored.toJson()['customBackgroundOpacity'], 0.65);
    expect(stored.toJson()['terminalFontSize'], 18);
  });
}

Map<String, Color> _roles(ColorScheme c) => {
      'primary': c.primary,
      'onPrimary': c.onPrimary,
      'primaryContainer': c.primaryContainer,
      'onPrimaryContainer': c.onPrimaryContainer,
      'primaryFixed': c.primaryFixed,
      'primaryFixedDim': c.primaryFixedDim,
      'onPrimaryFixed': c.onPrimaryFixed,
      'onPrimaryFixedVariant': c.onPrimaryFixedVariant,
      'secondary': c.secondary,
      'onSecondary': c.onSecondary,
      'secondaryContainer': c.secondaryContainer,
      'onSecondaryContainer': c.onSecondaryContainer,
      'secondaryFixed': c.secondaryFixed,
      'secondaryFixedDim': c.secondaryFixedDim,
      'onSecondaryFixed': c.onSecondaryFixed,
      'onSecondaryFixedVariant': c.onSecondaryFixedVariant,
      'tertiary': c.tertiary,
      'onTertiary': c.onTertiary,
      'tertiaryContainer': c.tertiaryContainer,
      'onTertiaryContainer': c.onTertiaryContainer,
      'tertiaryFixed': c.tertiaryFixed,
      'tertiaryFixedDim': c.tertiaryFixedDim,
      'onTertiaryFixed': c.onTertiaryFixed,
      'onTertiaryFixedVariant': c.onTertiaryFixedVariant,
      'error': c.error,
      'onError': c.onError,
      'errorContainer': c.errorContainer,
      'onErrorContainer': c.onErrorContainer,
      'surface': c.surface,
      'onSurface': c.onSurface,
      'surfaceDim': c.surfaceDim,
      'surfaceBright': c.surfaceBright,
      'surfaceContainerLowest': c.surfaceContainerLowest,
      'surfaceContainerLow': c.surfaceContainerLow,
      'surfaceContainer': c.surfaceContainer,
      'surfaceContainerHigh': c.surfaceContainerHigh,
      'surfaceContainerHighest': c.surfaceContainerHighest,
      'onSurfaceVariant': c.onSurfaceVariant,
      'outline': c.outline,
      'outlineVariant': c.outlineVariant,
      'shadow': c.shadow,
      'scrim': c.scrim,
      'inverseSurface': c.inverseSurface,
      'onInverseSurface': c.onInverseSurface,
      'inversePrimary': c.inversePrimary,
      'surfaceTint': c.surfaceTint,
    };

Map<String, Color> _prismRoles(p.ColorScheme c) => {
      'primary': c.primary,
      'onPrimary': c.onPrimary,
      'primaryContainer': c.primaryContainer,
      'onPrimaryContainer': c.onPrimaryContainer,
      'primaryFixed': c.primaryFixed,
      'primaryFixedDim': c.primaryFixedDim,
      'onPrimaryFixed': c.onPrimaryFixed,
      'onPrimaryFixedVariant': c.onPrimaryFixedVariant,
      'secondary': c.secondary,
      'onSecondary': c.onSecondary,
      'secondaryContainer': c.secondaryContainer,
      'onSecondaryContainer': c.onSecondaryContainer,
      'secondaryFixed': c.secondaryFixed,
      'secondaryFixedDim': c.secondaryFixedDim,
      'onSecondaryFixed': c.onSecondaryFixed,
      'onSecondaryFixedVariant': c.onSecondaryFixedVariant,
      'tertiary': c.tertiary,
      'onTertiary': c.onTertiary,
      'tertiaryContainer': c.tertiaryContainer,
      'onTertiaryContainer': c.onTertiaryContainer,
      'tertiaryFixed': c.tertiaryFixed,
      'tertiaryFixedDim': c.tertiaryFixedDim,
      'onTertiaryFixed': c.onTertiaryFixed,
      'onTertiaryFixedVariant': c.onTertiaryFixedVariant,
      'error': c.error,
      'onError': c.onError,
      'errorContainer': c.errorContainer,
      'onErrorContainer': c.onErrorContainer,
      'surface': c.surface,
      'onSurface': c.onSurface,
      'surfaceDim': c.surfaceDim,
      'surfaceBright': c.surfaceBright,
      'surfaceContainerLowest': c.surfaceContainerLowest,
      'surfaceContainerLow': c.surfaceContainerLow,
      'surfaceContainer': c.surfaceContainer,
      'surfaceContainerHigh': c.surfaceContainerHigh,
      'surfaceContainerHighest': c.surfaceContainerHighest,
      'onSurfaceVariant': c.onSurfaceVariant,
      'outline': c.outline,
      'outlineVariant': c.outlineVariant,
      'shadow': c.shadow,
      'scrim': c.scrim,
      'inverseSurface': c.inverseSurface,
      'onInverseSurface': c.onInverseSurface,
      'inversePrimary': c.inversePrimary,
      'surfaceTint': c.surfaceTint,
    };

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

double _worst(Color color, ShunThemePreset preset) => math.min(
      _contrast(color, preset.background),
      _contrast(color, preset.card),
    );

double _chroma(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl.saturation * (1 - (2 * hsl.lightness - 1).abs()) * 100;
}

double _hueDistance(Color a, Color b) {
  final distance =
      (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs() % 360;
  return math.min(distance, 360 - distance);
}
