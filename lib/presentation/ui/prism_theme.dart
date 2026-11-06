import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../theme.dart';

/// 一套主题设置（浅/深 + uiThemeId）解析出的唯一语义主题（R83）。
///
/// Prism 部件直接用 [prismTheme]；还没迁到 Prism 的 Material 页面，以及读 Material 主题的
/// 终端配色、锁罩，用 material_compat.dart 从同一个对象翻译出的主题。两边颜色角色逐个相同，
/// 所以 Prism 页面、Material 页面和终端（远端问背景色 OSC 11 时的回答）看到的是同一套颜色。
///
/// 预设的六个颜色是主题的身份：页面、卡片、主色、边框原样用。只有正文、次要文字、错误色在
/// 页面或卡片上不到 4.5:1 时，沿 HCT 色调往远离底色的方向挪到刚好够读（色相、彩度不变），
/// 见 [_readable]。存着的 uiThemeId 不改，也不迁移任何数据。
@immutable
final class ShunUiTheme {
  const ShunUiTheme._(
    this.preset,
    this.platform,
    this.colorScheme,
    this.prismTheme,
  );

  factory ShunUiTheme._create(ShunThemePreset preset, TargetPlatform platform) {
    final colors = _colorSchemeFor(preset);
    return ShunUiTheme._(
      preset,
      platform,
      colors,
      prism.ThemeData(
        colorScheme: colors,
        platform: platform,
        // 深色下底部面板、侧栏、弹出菜单整体抬一层（prism 的 ElevatedSurfaceTheme），
        // 浅色不抬：浅色的面板本来就落在比页面亮的卡片色上。
        elevatedColorScheme:
            preset.brightness == Brightness.dark ? colors.elevated : null,
      ),
    );
  }

  /// 同一预设、同一平台只建一次。设置没变时宿主重建拿到同一个对象：prism 的 ThemeData 没有 ==，
  /// 按对象身份判断要不要通知，每次新建会让读主题的整棵树跟着重建。
  /// 认不出的 uiThemeId 照旧落到 midnight / snow（[ShunTheme.resolve]），存着的值不动。
  static ShunUiTheme resolve(Brightness brightness, String id) {
    final preset = ShunTheme.resolve(brightness, id);
    final platform = defaultTargetPlatform;
    return _cache[(preset, platform)] ??= ShunUiTheme._create(preset, platform);
  }

  static final _cache = <(ShunThemePreset, TargetPlatform), ShunUiTheme>{};

  final ShunThemePreset preset;
  final TargetPlatform platform;

  /// Prism 与 Material 共用的颜色角色。
  final prism.ColorScheme colorScheme;
  final prism.ThemeData prismTheme;

  Brightness get brightness => preset.brightness;
}

/// 正文、次要文字、错误提示在页面和卡片上的最低对比度（WCAG AA 正文）。
const _textContrast = 4.5;

/// 次要文字（副标题、提示）= 正文往卡片色退 30%，再保证够读。
const _mutedMix = 0.3;

/// 深色每往上一层（卡片 → 块 → 内嵌）亮多少 HCT 色调。prism 自己的深色种子色板里卡片、块、内嵌
/// 是 15/21/27，一层 6；这里照它的步子从预设的卡片色往上走。
const _darkStep = 6.0;

/// 浅色每往下一层（页面 → 块高 → 内嵌）暗多少。prism 浅色种子色板里页面、高、最高是 94/92/90，一层 2。
const _lightStep = 2.0;

prism.ColorScheme _colorSchemeFor(ShunThemePreset preset) {
  final dark = preset.brightness == Brightness.dark;
  final page = preset.background;
  final card = preset.card;
  final text = _readable(preset.foreground, page, card, lighten: dark);
  final muted = _readable(
    Color.lerp(text, card, _mutedMix)!,
    page,
    card,
    lighten: dark,
  );
  final error = _readable(preset.error, page, card, lighten: dark);
  // 容器色（选中的分段/芯片、提示条、错误底）用 prism 自己的种子算法：它保证每个容器和对应的
  // on 色互相读得清；主色、错误色、表面、文字下面全部按预设覆盖。
  final seeded = prism.seededColorScheme(
    seedColor: preset.primary,
    brightness: preset.brightness,
    style: prism.ColorStyle.vivid,
  );
  // prism 的表面层级（prism_ui surface.dart 的 SurfaceLevel）：浅色页面 = surfaceContainer、
  // 卡片 = surfaceBright；深色页面 = surface、卡片 = surfaceContainer。预设的页面、卡片按这个放，
  // Prism 的页面/卡片/块/内嵌和 Material 的 Scaffold/Card 就落在同一组颜色上。
  // surface 因此是浅色的卡片、深色的页面：终端底色和 OSC 11 的回答读的就是它（terminalColorsFor）。
  return seeded.copyWith(
    primary: preset.primary,
    onPrimary: _onColor(preset.primary),
    secondary: preset.primary,
    onSecondary: _onColor(preset.primary),
    surfaceTint: preset.primary,
    error: error,
    onError: _onColor(error),
    surface: dark ? page : card,
    onSurface: text,
    onSurfaceVariant: muted,
    surfaceDim: dark ? page : page.shiftTone(-3 * _lightStep),
    surfaceBright: dark ? card.shiftTone(2 * _darkStep) : card,
    // 深色最低一层比页面再暗一点（M3 深色 surface 6、最低 4）。
    surfaceContainerLowest: dark ? page.shiftTone(-2) : card,
    surfaceContainerLow: Color.lerp(page, card, 0.5),
    surfaceContainer: dark ? card : page,
    surfaceContainerHigh:
        dark ? card.shiftTone(_darkStep) : page.shiftTone(-_lightStep),
    surfaceContainerHighest:
        dark ? card.shiftTone(2 * _darkStep) : page.shiftTone(-2 * _lightStep),
    outline: preset.border,
    // 分隔线、卡片描边用边框色往卡片退一半：原来直接用边框色，浅色主题下分隔线偏重（R81 目检）。
    outlineVariant: Color.lerp(preset.border, card, 0.5),
    inverseSurface: text,
    onInverseSurface: page,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
  );
}

/// 主色、错误色上的字用黑还是白：prism 公开的明暗估计（和 Flutter 同一个函数，亮度约 0.34 以上用黑字）。
/// Prism 的按钮、分段控件只读这里定的 onPrimary，自己不算。原来按 0.46 分界，60 套预设的按钮字不到
/// 4.5:1，现在 36 套：都是中等亮度的主色配白字（最低 2.74:1），R81 时就是白字。改成「黑白里对比更高的」
/// 能全部到 4.5:1，但默认 Snow 等 37 套的按钮字和开关圆点会变黑；这是外观取舍，留给 R96 定。
Color _onColor(Color color) =>
    prism.ThemeData.estimateBrightnessForColor(color) == Brightness.light
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);

/// [color] 在页面和卡片上都够 [_textContrast] 就原样返回；不够就沿 HCT 色调往远离底色的方向
/// （深色主题变亮、浅色主题变暗）挪到刚好够读，色相和彩度不变。
/// 124 套预设里正文不够的有 4 套浅色（base16-flat 只有 3.03:1），错误色不够的有 70 套。
Color _readable(
  Color color,
  Color page,
  Color card, {
  required bool lighten,
}) {
  double worst(Color value) =>
      math.min(_contrast(value, page), _contrast(value, card));
  if (worst(color) >= _textContrast) return color;
  Color shifted(double delta) => color.shiftTone(lighten ? delta : -delta);
  // 往这个方向挪得越多对比越高，二分找最小的够用挪动；挪到底（纯黑/纯白）一定够。
  var short = 0.0;
  var enough = lighten ? 100 - color.tone : color.tone;
  for (var i = 0; i < 12; i++) {
    final middle = (short + enough) / 2;
    if (worst(shifted(middle)) >= _textContrast) {
      enough = middle;
    } else {
      short = middle;
    }
  }
  return shifted(enough);
}

/// WCAG 2 对比度。
double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}
