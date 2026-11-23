import 'package:prism_ui/icons/icons.dart';

/// 底栏五个入口的图形（24 格），给 Prism 的浮动底栏用：它只收 Glyph，选中时自己填实、做形变，
/// Material 的 IconData 放不进去。Prism 自带的只有通用界面符号，这五个是 shun 自己画的。
abstract final class ShunNavGlyphs {
  static const hosts = Glyph([
    GlyphBox(3.5, 4, 20.5, 11, 2.6),
    GlyphBox(3.5, 13, 20.5, 20, 2.6),
    GlyphCircle(7.5, 7.5, 1.1, role: GlyphRole.detail, solid: true),
    GlyphCircle(7.5, 16.5, 1.1, role: GlyphRole.detail, solid: true),
  ]);

  static const terminal = Glyph([
    GlyphBox(3, 4.5, 21, 19.5, 3.4),
    GlyphPolyline([
      GlyphVertex(7.2, 9.4),
      GlyphVertex(10, 12, 0.4),
      GlyphVertex(7.2, 14.6),
    ], role: GlyphRole.detail),
    GlyphPolyline([
      GlyphVertex(12.4, 14.8),
      GlyphVertex(16.4, 14.8),
    ], role: GlyphRole.detail),
  ]);

  static const files = Glyph([
    GlyphPolyline([
      GlyphVertex(3, 5.6, 2),
      GlyphVertex(9.4, 5.6, 1),
      GlyphVertex(11.4, 8.2, 0.8),
      GlyphVertex(21, 8.2, 2.2),
      GlyphVertex(21, 19, 2.2),
      GlyphVertex(3, 19, 2.2),
    ], closed: true),
  ]);

  static const snippets = Glyph([
    GlyphPolyline([
      GlyphVertex(7.6, 7.4),
      GlyphVertex(3.2, 12, 0.5),
      GlyphVertex(7.6, 16.6),
    ], role: GlyphRole.line),
    GlyphPolyline([
      GlyphVertex(16.4, 7.4),
      GlyphVertex(20.8, 12, 0.5),
      GlyphVertex(16.4, 16.6),
    ], role: GlyphRole.line),
    GlyphPolyline([
      GlyphVertex(13.7, 5.2),
      GlyphVertex(10.3, 18.8),
    ], role: GlyphRole.line),
  ]);

  static const settings = Glyph([
    GlyphPolyline([
      GlyphVertex(9.64, 5.73, 0.6),
      GlyphVertex(10.17, 2.98, 0.9),
      GlyphVertex(13.83, 2.98, 0.9),
      GlyphVertex(14.36, 5.73, 0.6),
      GlyphVertex(16.25, 6.82, 0.6),
      GlyphVertex(18.89, 5.91, 0.9),
      GlyphVertex(20.72, 9.07, 0.9),
      GlyphVertex(18.61, 10.91, 0.6),
      GlyphVertex(18.61, 13.09, 0.6),
      GlyphVertex(20.72, 14.93, 0.9),
      GlyphVertex(18.89, 18.09, 0.9),
      GlyphVertex(16.25, 17.18, 0.6),
      GlyphVertex(14.36, 18.27, 0.6),
      GlyphVertex(13.83, 21.02, 0.9),
      GlyphVertex(10.17, 21.02, 0.9),
      GlyphVertex(9.64, 18.27, 0.6),
      GlyphVertex(7.75, 17.18, 0.6),
      GlyphVertex(5.11, 18.09, 0.9),
      GlyphVertex(3.28, 14.93, 0.9),
      GlyphVertex(5.39, 13.09, 0.6),
      GlyphVertex(5.39, 10.91, 0.6),
      GlyphVertex(3.28, 9.07, 0.9),
      GlyphVertex(5.11, 5.91, 0.9),
      GlyphVertex(7.75, 6.82, 0.6),
    ], closed: true),
    GlyphCircle(12, 12, 2.9, role: GlyphRole.detail),
  ]);

  static const all = [hosts, terminal, files, snippets, settings];
}
