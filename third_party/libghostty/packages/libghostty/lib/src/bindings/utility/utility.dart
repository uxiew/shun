import 'dart:typed_data';

import '../../generated/libghostty_enums.g.dart';
import '../../types/types.dart';

abstract interface class UtilityBindings {
  int buildInfo(BuildInfo data);
  bool buildInfoBool(BuildInfo data);
  String buildInfoString(BuildInfo data);

  double colorContrast(RgbColor a, RgbColor b);
  double colorLuminance(RgbColor color);
  List<RgbColor> colorPaletteDefault();
  List<RgbColor> colorPaletteGenerate({
    List<RgbColor>? base,
    Set<int> skip = const {},
    required RgbColor background,
    required RgbColor foreground,
    required bool harmonious,
  });
  RgbColor colorParse(String value);
  ({int index, RgbColor color}) colorParsePaletteEntry(String value);
  RgbColor colorParseX11(String name);
  double colorPerceivedLuminance(RgbColor color);

  String colorSchemeReportEncode(ColorScheme scheme);
  List<X11ColorName> colorX11Names();
  String focusEncode(FocusEvent event);
  String modeReportEncode(int mode, ModeReportState state);

  Uint8List pasteEncode(String data, {required bool bracketed});
  bool pasteIsSafe(String data);

  String sizeReportEncode(
    SizeReportStyle style,
    int rows,
    int columns,
    int cellWidth,
    int cellHeight,
  );
  Style styleDefault();
  bool styleIsDefault(Style style);

  int unicodeCodepointWidth(int codepoint);
  ({int consumed, int width}) unicodeGraphemeWidth(List<int> codepoints);
}
