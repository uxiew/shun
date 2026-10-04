import '../../ffi/libghostty_enums.g.dart';
import 'aliases.dart';
import 'color.dart';

/// Response data for device attributes queries (DA1/DA2/DA3).
///
/// Return from the [Terminal.onDeviceAttributes] callback to respond to
/// CSI c, CSI > c, or CSI = c queries. The terminal reads whichever
/// sub-struct matches the request type.
class DeviceAttributesResponse {
  /// Primary device attributes (DA1). Response to CSI c.
  final DeviceAttributesPrimary primary;

  /// Secondary device attributes (DA2). Response to CSI > c.
  final DeviceAttributesSecondary secondary;

  /// Tertiary device attributes (DA3). Response to CSI = c.
  final DeviceAttributesTertiary tertiary;

  const DeviceAttributesResponse({
    this.primary = const DeviceAttributesPrimary(),
    this.secondary = const DeviceAttributesSecondary(),
    this.tertiary = const DeviceAttributesTertiary(),
  });
}

/// Primary device attributes (DA1) response data.
///
/// Response format: CSI ? Pp ; Ps... c
/// where Pp is the conformance level and Ps are feature codes.
class DeviceAttributesPrimary {
  /// Conformance level (Pp parameter). For example, 62 for VT220.
  final int conformanceLevel;

  /// DA1 feature codes (Ps parameters).
  final List<int> features;

  const DeviceAttributesPrimary({
    this.conformanceLevel = 62,
    this.features = const [],
  });
}

/// Secondary device attributes (DA2) response data.
///
/// Response format: CSI > Pp ; Pv ; Pc c
class DeviceAttributesSecondary {
  /// Terminal type identifier (Pp). For example, 1 for VT220.
  final int deviceType;

  /// Firmware/patch version number (Pv).
  final int firmwareVersion;

  /// ROM cartridge registration number (Pc). Always 0 for emulators.
  final int romCartridge;

  const DeviceAttributesSecondary({
    this.deviceType = 1,
    this.firmwareVersion = 0,
    this.romCartridge = 0,
  });
}

/// Tertiary device attributes (DA3) response data.
///
/// Response format: DCS ! | D...D ST (DECRPTUI).
class DeviceAttributesTertiary {
  /// Unit ID encoded as 8 uppercase hex digits in the response.
  final int unitId;

  const DeviceAttributesTertiary({this.unitId = 0});
}

/// Scrollbar position and dimensions for the terminal viewport.
///
/// Provides the information needed to render a scrollbar widget.
class Scrollbar {
  /// Total scrollable area in rows (active grid + scrollback).
  final int total;

  /// Current viewport offset from the top in rows.
  final int offset;

  /// Number of visible rows in the viewport.
  final int visible;

  const Scrollbar({
    required this.total,
    required this.offset,
    required this.visible,
  });
}

/// A parsed SGR (Select Graphic Rendition) attribute.
///
/// Switch on [tag] to determine the attribute type, then access the
/// relevant field ([color], [paletteIndex], [underlineStyle]).
/// Attributes without data (e.g. bold, italic) are identified by [tag]
/// alone.
///
/// ```dart
/// for (final attr in parser.parse([1, 38, 2, 255, 0, 0])) {
///   switch (attr.tag) {
///     case .directColorFg:
///       print('fg: ${attr.color}');
///     case .bold:
///       print('bold');
///     default:
///       break;
///   }
/// }
/// ```
class SgrAttribute {
  /// The attribute type.
  final SgrAttributeTag tag;

  /// RGB color for direct color attributes ([SgrAttributeTag.directColorFg],
  /// [SgrAttributeTag.directColorBg], [SgrAttributeTag.underlineColor]).
  /// Null for non-color attributes.
  final RgbColor? color;

  /// Palette index for indexed color attributes ([SgrAttributeTag.fg8],
  /// [SgrAttributeTag.bg8], [SgrAttributeTag.fg256],
  /// [SgrAttributeTag.bg256], etc.). Zero for non-indexed attributes.
  final int paletteIndex;

  /// Full SGR parameter list when [tag] is [SgrAttributeTag.unknown].
  /// Empty for recognized attributes.
  final List<int> unknownFull;

  /// Partial parameter list where parsing stopped when [tag] is
  /// [SgrAttributeTag.unknown]. Empty for recognized attributes.
  final List<int> unknownPartial;

  /// Underline style when [tag] is [SgrAttributeTag.underline].
  /// [UnderlineStyle.none] for other attributes.
  final UnderlineStyle underlineStyle;

  const SgrAttribute({
    required this.tag,
    this.color,
    this.paletteIndex = 0,
    this.unknownFull = const [],
    this.unknownPartial = const [],
    this.underlineStyle = UnderlineStyle.none,
  });
}

/// SGR style applied to a terminal cell.
///
/// Combines text attributes (bold, italic, etc.), foreground/background
/// colors, and underline style/color. All attributes default to off,
/// colors default to [DefaultColor], and underline defaults to
/// [UnderlineStyle.none].
class Style {
  /// Whether bold (SGR 1) is active.
  final bool bold;

  /// Whether italic (SGR 3) is active.
  final bool italic;

  /// Whether faint/dim (SGR 2) is active.
  final bool faint;

  /// Whether blink (SGR 5/6) is active.
  final bool blink;

  /// Whether inverse/reverse video (SGR 7) is active.
  final bool inverse;

  /// Whether invisible (SGR 8) is active.
  final bool invisible;

  /// Whether overline (SGR 53) is active.
  final bool overline;

  /// Whether strikethrough (SGR 9) is active.
  final bool strikethrough;

  /// Foreground color. [DefaultColor] when no color is explicitly set.
  final CellColor foreground;

  /// Background color. [DefaultColor] when no color is explicitly set.
  final CellColor background;

  /// Underline style: none, single, double, curly, dotted, or dashed.
  final UnderlineStyle underline;

  /// Underline color, or null when using the foreground color.
  final CellColor? underlineColor;

  const Style({
    this.bold = false,
    this.italic = false,
    this.faint = false,
    this.blink = false,
    this.inverse = false,
    this.invisible = false,
    this.overline = false,
    this.strikethrough = false,
    this.foreground = const DefaultColor(),
    this.background = const DefaultColor(),
    this.underline = UnderlineStyle.none,
    this.underlineColor,
  });
}

/// Resolved terminal colors from the render state.
///
/// Contains the effective foreground, background, cursor color, and the
/// full 256-color palette after applying any OSC overrides. Access via
/// [RenderState.colors].
class TerminalColors {
  /// Cursor color, or null if no explicit cursor color is set. When null,
  /// the renderer should choose its own cursor color.
  final RgbColor? cursor;

  /// Effective foreground color.
  final RgbColor foreground;

  /// Effective background color.
  final RgbColor background;

  /// The active 256-color palette with OSC 4 overrides applied.
  final List<RgbColor> palette;

  const TerminalColors({
    this.cursor,
    required this.foreground,
    required this.background,
    required this.palette,
  });
}

/// Terminal size in cells and pixels for XTWINOPS size query responses.
///
/// Return from the [Terminal.onSize] callback to respond to CSI 14/16/18 t
/// queries.
class TerminalSizeInfo {
  /// Terminal height in cells.
  final int rows;

  /// Terminal width in cells.
  final int columns;

  /// Width of a single cell in pixels.
  final int cellWidth;

  /// Height of a single cell in pixels.
  final int cellHeight;

  const TerminalSizeInfo({
    required this.rows,
    required this.columns,
    required this.cellWidth,
    required this.cellHeight,
  });
}
