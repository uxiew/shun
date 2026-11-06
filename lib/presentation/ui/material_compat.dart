import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'prism_theme.dart';

final _themes = <(ShunUiTheme, bool), ThemeData>{};

/// 没迁到 Prism 的 Material 部件看到的主题，以及读 Material 主题的终端配色、锁罩（R83）。
///
/// 这里只翻译 [ShunUiTheme]，不定义自己的值：颜色角色逐个照抄，字阶取 Prism 的 AppTextStyle，
/// 形状取 Prism 的 AppShape，密度和点击区取 Prism 按平台给的值。要改外观先改 prism_theme.dart；
/// 只在这里改，Material 页面和 Prism 页面就分成两套。
///
/// [reduceMotion] 是系统的「移除动画」（MediaQuery.disableAnimations，Prism 的 motionDuration
/// 也看它）：开着时展开/收起直接到位。同一组参数只建一次，宿主重建拿到同一个对象。
ThemeData materialThemeFor(ShunUiTheme ui, {bool reduceMotion = false}) =>
    _themes[(ui, reduceMotion)] ??= _build(ui, reduceMotion: reduceMotion);

ThemeData _build(ShunUiTheme ui, {required bool reduceMotion}) {
  final colors = ui.colorScheme;
  final prismTheme = ui.prismTheme;
  final card = prism.SurfaceLevel.card.colorOf(colors);
  // 弹窗、菜单落在 prism 的 floating 层（浅色卡片、深色块），底部面板是抬起后的页面层。
  final floating = prism.SurfaceLevel.floatingOf(colors).colorOf(colors);
  final sheet =
      prism.SurfaceLevel.page.colorOf(prismTheme.elevated.colorScheme);
  final text = _textTheme(prismTheme);
  return ThemeData(
    brightness: colors.brightness,
    useMaterial3: true,
    platform: prismTheme.platform,
    colorScheme: _colorScheme(colors),
    textTheme: text,
    scaffoldBackgroundColor: prismTheme.scaffoldBackgroundColor,
    canvasColor: floating,
    cardColor: card,
    dividerColor: colors.outlineVariant,
    visualDensity: VisualDensity(
      horizontal: prismTheme.visualDensity.horizontal,
      vertical: prismTheme.visualDensity.vertical,
    ),
    materialTapTargetSize:
        prismTheme.tapTargetSize == prism.TapTargetSize.padded
            ? MaterialTapTargetSize.padded
            : MaterialTapTargetSize.shrinkWrap,
    // 底栏留给 R85 换成 Prism 导航，这里只把颜色接到同一组表面上，高度和选中底色照旧。
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: card,
      indicatorColor: colors.primary.withValues(alpha: 0.2),
      height: 68,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: prismTheme.scaffoldBackgroundColor,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      // 按预设页面和卡片同色的有 11 套（Pure White、GitHub 等），描边不能去掉。
      shape: prism.AppShape.md.copyWith(
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: card,
      border: OutlineInputBorder(
        borderRadius: prism.AppRadius.md,
        borderSide: BorderSide(color: colors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: prism.AppRadius.md,
        borderSide: BorderSide(color: colors.outline),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: sheet,
      modalBackgroundColor: sheet,
      surfaceTintColor: Colors.transparent,
      shape: prism.AppShape.top(prism.AppCorner.xxl),
      modalBarrierColor: colors.modalScrim,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: floating,
      surfaceTintColor: Colors.transparent,
      shape: prism.AppShape.all(prism.AppCorner.alert),
      barrierColor: colors.alertScrim,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: floating,
      surfaceTintColor: Colors.transparent,
      shape: prism.AppShape.md,
    ),
    chipTheme: const ChipThemeData(shape: prism.AppShape.sm),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.inverseSurface,
      contentTextStyle: text.bodyMedium!.copyWith(
        color: colors.onInverseSurface,
      ),
    ),
    // 展开/收起走 prism 列表展开的公开时长和曲线（UnfoldEntryTransition）。
    expansionTileTheme: ExpansionTileThemeData(
      expansionAnimationStyle: reduceMotion
          ? AnimationStyle.noAnimation
          : AnimationStyle(
              duration: prism.UnfoldEntryTransition.duration,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            ),
    ),
  );
}

/// Material 的 15 个字阶各取字号最接近的 Prism AppTextStyle（iOS Dynamic Type 那一套），
/// 整个 App 只用 Prism 的这几档字号。Material 的 14 没有对应档，归到 Prism 用得最多的 15
/// （subheadline：按钮、分段、列表副标题）。标题和标签的字重用 Prism 的强调字重。
/// 字体族和 Prism 一样按字号分正文/大字两种系统字体；终端的等宽字体不在这里，见 terminalColorsFor。
/// 系统字号放大照旧走 MediaQuery 的 TextScaler，这里只给基准字号。
TextTheme _textTheme(prism.ThemeData theme) {
  TextStyle step(prism.AppTextStyle style, {bool emphasized = false}) {
    final base = style.size < prism.AppTextStyle.title3.size
        ? theme.bodyTextStyle
        : theme.displayTextStyle;
    return TextStyle(
      fontFamily: base.fontFamily,
      fontFamilyFallback: base.fontFamilyFallback,
      fontSize: style.size,
      height: style.leading / style.size,
      fontWeight: emphasized ? style.emphasizedWeight : style.weight,
      letterSpacing: 0,
    );
  }

  return TextTheme(
    displayLarge: step(prism.AppTextStyle.display),
    displayMedium: step(prism.AppTextStyle.display),
    displaySmall: step(prism.AppTextStyle.largeTitle),
    headlineLarge: step(prism.AppTextStyle.largeTitle),
    headlineMedium: step(prism.AppTextStyle.title1),
    headlineSmall: step(prism.AppTextStyle.pageTitle),
    titleLarge: step(prism.AppTextStyle.title2),
    titleMedium: step(prism.AppTextStyle.callout, emphasized: true),
    titleSmall: step(prism.AppTextStyle.subheadline, emphasized: true),
    bodyLarge: step(prism.AppTextStyle.callout),
    bodyMedium: step(prism.AppTextStyle.subheadline),
    bodySmall: step(prism.AppTextStyle.caption1),
    labelLarge: step(prism.AppTextStyle.subheadline, emphasized: true),
    labelMedium: step(prism.AppTextStyle.caption1, emphasized: true),
    labelSmall: step(prism.AppTextStyle.caption2, emphasized: true),
  );
}

ColorScheme _colorScheme(prism.ColorScheme colors) => ColorScheme(
      brightness: colors.brightness,
      primary: colors.primary,
      onPrimary: colors.onPrimary,
      primaryContainer: colors.primaryContainer,
      onPrimaryContainer: colors.onPrimaryContainer,
      primaryFixed: colors.primaryFixed,
      primaryFixedDim: colors.primaryFixedDim,
      onPrimaryFixed: colors.onPrimaryFixed,
      onPrimaryFixedVariant: colors.onPrimaryFixedVariant,
      secondary: colors.secondary,
      onSecondary: colors.onSecondary,
      secondaryContainer: colors.secondaryContainer,
      onSecondaryContainer: colors.onSecondaryContainer,
      secondaryFixed: colors.secondaryFixed,
      secondaryFixedDim: colors.secondaryFixedDim,
      onSecondaryFixed: colors.onSecondaryFixed,
      onSecondaryFixedVariant: colors.onSecondaryFixedVariant,
      tertiary: colors.tertiary,
      onTertiary: colors.onTertiary,
      tertiaryContainer: colors.tertiaryContainer,
      onTertiaryContainer: colors.onTertiaryContainer,
      tertiaryFixed: colors.tertiaryFixed,
      tertiaryFixedDim: colors.tertiaryFixedDim,
      onTertiaryFixed: colors.onTertiaryFixed,
      onTertiaryFixedVariant: colors.onTertiaryFixedVariant,
      error: colors.error,
      onError: colors.onError,
      errorContainer: colors.errorContainer,
      onErrorContainer: colors.onErrorContainer,
      surface: colors.surface,
      onSurface: colors.onSurface,
      surfaceDim: colors.surfaceDim,
      surfaceBright: colors.surfaceBright,
      surfaceContainerLowest: colors.surfaceContainerLowest,
      surfaceContainerLow: colors.surfaceContainerLow,
      surfaceContainer: colors.surfaceContainer,
      surfaceContainerHigh: colors.surfaceContainerHigh,
      surfaceContainerHighest: colors.surfaceContainerHighest,
      onSurfaceVariant: colors.onSurfaceVariant,
      outline: colors.outline,
      outlineVariant: colors.outlineVariant,
      shadow: colors.shadow,
      scrim: colors.scrim,
      inverseSurface: colors.inverseSurface,
      onInverseSurface: colors.onInverseSurface,
      inversePrimary: colors.inversePrimary,
      surfaceTint: colors.surfaceTint,
    );
