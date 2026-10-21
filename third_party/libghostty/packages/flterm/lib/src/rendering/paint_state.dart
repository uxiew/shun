import 'dart:typed_data';
import 'dart:ui';

import 'package:libghostty/libghostty.dart'
    show RenderStateCursor, TerminalColors;

import '../foundation.dart' show CellMetrics, TerminalTheme;
import 'atlas/atlas.dart';
import 'contrast.dart';

/// Mutable state shared by frame preparation and painters for one surface.
///
/// The terminal surface owns and mutates this object. Frame builders write
/// paint-ready values during synchronization, while painters only read them.
///
/// Contains grid dimensions, device pixel ratio, resolved terminal
/// colors, cursor state, IME preedit state, and faint text opacity.
final class PaintState {
  TerminalTheme theme;
  CellMetrics metrics;

  var rows = 0;
  var cols = 0;
  var blinkVisible = true;

  /// Scale between Flutter's logical-pixel canvas and the physical
  /// pixels libghostty uses for size reports and Kitty graphics.
  var devicePixelRatio = 1.0;

  late int terminalForegroundArgb;
  late int terminalBackgroundArgb;
  final terminalPaletteArgb = Uint32List(256);

  /// Alpha byte (0-255) applied to faint text foregrounds.
  int faintAlpha;

  var viewportOffset = 0;

  var cursor = const RenderStateCursor();
  var cursorWide = false;
  var cursorFocused = true;
  var cursorColorArgb = 0xFFFFFFFF;
  AtlasEntry? cursorAtlasEntry;
  final cursorGlyphPaint = Paint();

  /// Whether preedit text currently replaces cells at the cursor row.
  ///
  /// Cursor painting reads this to avoid drawing the normal terminal cursor
  /// over the active composing range.
  var preeditActive = false;

  /// shun: 调过对比度的前景，键是（前景 RGB，背景 RGB）。同一屏就那几种颜色，算一次记住；
  /// 换主题（最低对比度可能变）时清空。
  final _contrasted = <int, int>{};

  PaintState(this.theme, this.metrics)
    : faintAlpha = (theme.faintOpacity * 255).ceil() {
    terminalForegroundArgb = theme.foreground.toARGB32();
    terminalBackgroundArgb = theme.background.toARGB32();
    _updateThemePalette();
  }

  void updateTheme(TerminalTheme newTheme) {
    theme = newTheme;
    faintAlpha = (newTheme.faintOpacity * 255).ceil();
    _contrasted.clear();
    _updateThemePalette();
  }

  /// shun: 把前景 [foregroundArgb] 调到在 [backgroundArgb] 上至少有
  /// [TerminalTheme.minimumContrast] 的对比度，透明度（淡色字的 alpha）保留。
  /// 最低对比度是 1 时原样返回。
  int ensureContrast(int foregroundArgb, int backgroundArgb) {
    final minimum = theme.minimumContrast;
    if (minimum <= 1.0) return foregroundArgb;
    final key =
        ((foregroundArgb & 0xFFFFFF) << 24) | (backgroundArgb & 0xFFFFFF);
    var rgb = _contrasted[key];
    if (rgb == null) {
      // 程序不停换真彩色时（渐变动画）别无限涨。
      if (_contrasted.length >= 4096) _contrasted.clear();
      rgb = contrastedRgb(
        foregroundArgb & 0xFFFFFF,
        backgroundArgb & 0xFFFFFF,
        minimum,
      );
      _contrasted[key] = rgb;
    }
    return (foregroundArgb & 0xFF000000) | rgb;
  }

  /// Updates resolved terminal colors.
  ///
  /// Returns true when any color changed so cached paint data containing
  /// packed ARGB values can be rebuilt.
  bool updateTerminalColors(TerminalColors colors) {
    var changed = false;
    final foreground = colors.foreground.toArgb32;
    final background = colors.background.toArgb32;
    if (terminalForegroundArgb != foreground) {
      terminalForegroundArgb = foreground;
      changed = true;
    }
    if (terminalBackgroundArgb != background) {
      terminalBackgroundArgb = background;
      changed = true;
    }
    final palette = colors.palette;
    for (var i = 0; i < terminalPaletteArgb.length; i++) {
      final color = palette[i].toArgb32;
      if (terminalPaletteArgb[i] == color) continue;
      terminalPaletteArgb[i] = color;
      changed = true;
    }
    return changed;
  }

  void _updateThemePalette() {
    final palette = theme.palette;
    for (var i = 0; i < terminalPaletteArgb.length; i++) {
      terminalPaletteArgb[i] = palette[i].toARGB32();
    }
  }
}
