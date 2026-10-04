import '../bindings/bindings.dart';

/// Calculates the WCAG contrast ratio between [a] and [b].
///
/// The value is symmetric and ranges from 1.0 for identical colors to 21.0
/// for black on white.
double colorContrast(RgbColor a, RgbColor b) => bindings.colorContrast(a, b);

/// Calculates W3C relative luminance for [color].
///
/// The value ranges from 0.0 for black to 1.0 for white, using the WCAG
/// relative luminance definition.
double colorLuminance(RgbColor color) => bindings.colorLuminance(color);

/// Calculates perceived luminance for [color].
///
/// The value ranges from 0.0 for black to 1.0 for white. The terminal treats
/// a background as light when this value is greater than 0.5. This is not the
/// WCAG relative luminance metric and not the CIELAB lightness used by
/// [generateColorPalette].
double colorPerceivedLuminance(RgbColor color) {
  return bindings.colorPerceivedLuminance(color);
}

/// Returns the built-in default 256-color palette.
///
/// The palette contains the default 16 ANSI colors, the xterm 6x6x6 color
/// cube, and the grayscale ramp.
List<RgbColor> defaultColorPalette() => bindings.colorPaletteDefault();

/// Generates a 256-color palette using terminal palette interpolation.
///
/// [base], when provided, must contain exactly 256 colors; otherwise the
/// default palette is used. Indices 0 through 15 are always preserved from the
/// base palette. Entries in [skip] are also preserved from [base]; each index
/// must be between 0 and 255.
///
/// The 216-color cube at indices 16 through 231 is generated with trilinear
/// CIELAB interpolation. The grayscale ramp at indices 232 through 255 is
/// interpolated from [background] to [foreground].
///
/// For light themes, [harmonious] controls whether the generated palette keeps
/// the background-to-foreground orientation. When false, a light background
/// and dark foreground are swapped so the cube and ramp run dark-to-light.
List<RgbColor> generateColorPalette({
  List<RgbColor>? base,
  Set<int> skip = const {},
  required RgbColor background,
  required RgbColor foreground,
  bool harmonious = true,
}) {
  if (base != null && base.length != 256) {
    throw RangeError.value(base.length, 'base.length', 'must be 256');
  }
  for (final index in skip) {
    RangeError.checkValueInInterval(index, 0, 255, 'skip');
  }
  return bindings.colorPaletteGenerate(
    base: base,
    skip: skip,
    background: background,
    foreground: foreground,
    harmonious: harmonious,
  );
}

/// Parses a color string using terminal color syntax.
///
/// Accepts X11 color names matched ASCII case-insensitively, 3- or 6-digit
/// hex colors with or without a leading `#`, 9- or 12-digit hex colors with a
/// leading `#`, and XParseColor-style `rgb:<red>/<green>/<blue>` or
/// `rgbi:<red>/<green>/<blue>` values.
///
/// Leading and trailing spaces and tabs are ignored. Throws
/// [InvalidValueException] when [value] is not a valid color.
RgbColor parseColor(String value) => check(bindings.colorParse(value));

/// Parses a palette override in `INDEX=COLOR` form.
///
/// The index may be decimal or use a `0x`, `0o`, or `0b` prefix. Spaces and
/// tabs around the index and color are ignored. The color side accepts the
/// same syntax as [parseColor].
///
/// Throws [InvalidValueException] when [value] is not a valid palette entry,
/// including index overflow.
({int index, RgbColor color}) parsePaletteEntry(String value) {
  return check(bindings.colorParsePaletteEntry(value));
}

/// Parses an X11 color name using the embedded `rgb.txt` table.
///
/// Leading and trailing spaces and tabs are ignored. Matching is ASCII
/// case-insensitive. Hex values and `rgb:`/`rgbi:` values are not accepted.
///
/// Throws [InvalidValueException] when [name] is not a known X11 color name.
RgbColor parseX11ColorName(String name) => check(bindings.colorParseX11(name));

/// X11 color names recognized by the color parser.
///
/// Entries are returned in `rgb.txt` order. Aliases are separate entries, such
/// as `medium spring green` and `MediumSpringGreen`; [parseX11ColorName]
/// matches supported spellings case-insensitively.
List<X11ColorName> x11ColorNames() => bindings.colorX11Names();
