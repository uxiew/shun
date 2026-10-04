import 'package:meta/meta.dart';

/// A terminal cell color: [DefaultColor], [RgbColor], or [PaletteColor].
///
/// ```dart
/// switch (cell.foreground) {
///   case DefaultColor():
///     print('default');
///   case RgbColor(:final r, :final g, :final b):
///     print('rgb($r, $g, $b)');
///   case PaletteColor(:final index):
///     print('palette($index)');
/// }
/// ```
@immutable
sealed class CellColor {
  const CellColor();
}

/// An RGB color with 8-bit components (0-255).
///
/// Used both as a cell color in rendered output and as the type for terminal
/// color configuration (foreground, background, cursor, palette).
///
/// ```dart
/// const red = RgbColor(255, 0, 0);
/// terminal.foreground = red;
/// ```
final class RgbColor extends CellColor {
  /// The red component in the inclusive range 0-255.
  final int r;

  /// The green component in the inclusive range 0-255.
  final int g;

  /// The blue component in the inclusive range 0-255.
  final int b;

  const RgbColor(this.r, this.g, this.b);

  @override
  int get hashCode => Object.hash(RgbColor, r, g, b);

  /// Converts to a 32-bit ARGB int with full opacity.
  int get toArgb32 => 0xFF000000 | (r << 16) | (g << 8) | b;

  @override
  bool operator ==(Object other) =>
      other is RgbColor && other.r == r && other.g == g && other.b == b;

  @override
  String toString() => 'RgbColor($r, $g, $b)';
}

/// The terminal's default foreground or background color.
///
/// Indicates no explicit color was set by an SGR sequence, so the terminal
/// should use its configured default.
final class DefaultColor extends CellColor {
  const DefaultColor();

  @override
  int get hashCode => (DefaultColor).hashCode;

  @override
  bool operator ==(Object other) => other is DefaultColor;

  @override
  String toString() => 'DefaultColor()';
}

/// A color referenced by palette index (0-255).
///
/// Resolve against the terminal's active palette to obtain RGB values.
final class PaletteColor extends CellColor {
  /// The palette entry in the inclusive range 0-255.
  final int index;

  const PaletteColor(this.index);

  @override
  int get hashCode => Object.hash(PaletteColor, index);

  @override
  bool operator ==(Object other) =>
      other is PaletteColor && other.index == index;

  @override
  String toString() => 'PaletteColor($index)';
}

/// An X11 color name recognized by libghostty's color parser.
@immutable
final class X11ColorName {
  /// Canonical color name.
  final String name;

  /// RGB value associated with [name].
  final RgbColor color;

  const X11ColorName({required this.name, required this.color});

  @override
  int get hashCode => Object.hash(name, color);

  @override
  bool operator ==(Object other) =>
      other is X11ColorName && other.name == name && other.color == color;
}

/// Standard ANSI terminal color palette indices (0-15).
///
/// Provides named constants for the 8 standard and 8 bright colors
/// defined by the terminal color palette.
extension type const NamedColor._(int index) implements int {
  const NamedColor.black() : index = 0;

  const NamedColor.red() : index = 1;

  const NamedColor.green() : index = 2;

  const NamedColor.yellow() : index = 3;

  const NamedColor.blue() : index = 4;

  const NamedColor.magenta() : index = 5;

  const NamedColor.cyan() : index = 6;

  const NamedColor.white() : index = 7;

  const NamedColor.brightBlack() : index = 8;

  const NamedColor.brightRed() : index = 9;

  const NamedColor.brightGreen() : index = 10;

  const NamedColor.brightYellow() : index = 11;

  const NamedColor.brightBlue() : index = 12;

  const NamedColor.brightMagenta() : index = 13;

  const NamedColor.brightCyan() : index = 14;

  const NamedColor.brightWhite() : index = 15;
}
