/// shun: [TerminalTheme.minimumContrast] 上游只声明、渲染从来没用。这里按 WCAG 的对比度算法把前景往黑或白
/// 挪到刚好够，挪多少按比例混，不像 Ghostty 那样直接换成纯黑纯白：黄字还是偏黄，只是变深。
library;

import 'dart:math' as math;

/// 0–255 的 sRGB 分量换成线性光，预先算好：二分查找里每步要算一次亮度。
final _linear = List<double>.unmodifiable([
  for (var i = 0; i < 256; i++) _toLinear(i / 255),
]);

double _toLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// [rgb] 是 0xRRGGBB，返回 WCAG 相对亮度（0 黑，1 白）。
double relativeLuminance(int rgb) =>
    0.2126 * _linear[(rgb >> 16) & 0xFF] +
    0.7152 * _linear[(rgb >> 8) & 0xFF] +
    0.0722 * _linear[rgb & 0xFF];

/// 两个亮度的对比度，1（一样）到 21（黑对白）。
double contrastRatio(double a, double b) =>
    a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);

int _mix(int from, int to, double t) {
  int channel(int shift) {
    final a = (from >> shift) & 0xFF;
    final b = (to >> shift) & 0xFF;
    return (a + (b - a) * t).round().clamp(0, 255);
  }

  return (channel(16) << 16) | (channel(8) << 8) | channel(0);
}

/// 前景 [foreground] 在背景 [background] 上对比度不到 [minimum] 时，往黑或白（哪个离背景远往哪个）
/// 混到刚好够；纯黑纯白都不够时给那个极端色。两个参数和返回值都是 0xRRGGBB。
int contrastedRgb(int foreground, int background, double minimum) {
  final bg = relativeLuminance(background);
  if (contrastRatio(relativeLuminance(foreground), bg) >= minimum) {
    return foreground;
  }
  final towardWhite = contrastRatio(1, bg) >= contrastRatio(0, bg);
  final target = towardWhite ? 0xFFFFFF : 0x000000;
  if (contrastRatio(towardWhite ? 1 : 0, bg) < minimum) return target;
  // 一开始不够，混到底一定够。中间对比度可能先降后升（前景比背景亮、却往黑挪），但「够不够」
  // 只从不够变成够一次，二分查找成立。
  var low = 0.0;
  var high = 1.0;
  for (var i = 0; i < 12; i++) {
    final mid = (low + high) / 2;
    final mixed = _mix(foreground, target, mid);
    if (contrastRatio(relativeLuminance(mixed), bg) >= minimum) {
      high = mid;
    } else {
      low = mid;
    }
  }
  return _mix(foreground, target, high);
}
