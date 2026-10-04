import '../bindings/bindings.dart';

/// Returns the terminal display width of [codepoint] in grid cells.
///
/// The width is 0, 1, or 2 and matches terminal text layout. Zero-width
/// codepoints include C0/C1 control characters, nonspacing and enclosing
/// combining marks, default-ignorable codepoints such as ZWJ, ZWNJ, variation
/// selectors, and surrogate codepoints. Wide codepoints include East Asian
/// Wide/Fullwidth codepoints, emoji with default emoji presentation, and
/// regional indicators. Invalid codepoints beyond U+10FFFF return width 1.
///
/// This measures one codepoint only. It does not account for grapheme-cluster
/// rules such as emoji variation selectors, ZWJ sequences, combining marks, or
/// skin tone modifiers. Use [unicodeGraphemeWidth] for cluster-accurate widths
/// when terminal mode 2027 is enabled.
int unicodeCodepointWidth(int codepoint) {
  RangeError.checkNotNegative(codepoint, 'codepoint');
  return bindings.unicodeCodepointWidth(codepoint);
}

/// Measures the first grapheme cluster in [codepoints].
///
/// Returns the number of codepoints consumed and the terminal cell width of
/// that cluster. An empty list returns `(consumed: 0, width: 0)`.
///
/// This uses the same segmentation and width rules as terminal grapheme
/// clustering mode 2027. It accounts for emoji variation selectors,
/// ZWJ sequences, combining marks, and skin tone modifiers. When mode 2027 is
/// disabled, terminal layout is predicted by summing [unicodeCodepointWidth]
/// for each codepoint instead.
///
/// This is not a streaming API. The provided list must contain a complete
/// first grapheme cluster, or the logical end of the string. If input arrives
/// in chunks, keep buffering while this function consumes every available
/// codepoint and the stream may still continue, because a later codepoint
/// could extend the cluster and change its width.
///
/// Codepoints beyond U+10FFFF consume one codepoint and have width 1. Control
/// characters are not printed through the terminal text path; passing them
/// here returns a stable, bounded result but does not model control-sequence
/// processing.
({int consumed, int width}) unicodeGraphemeWidth(List<int> codepoints) {
  for (final codepoint in codepoints) {
    RangeError.checkNotNegative(codepoint, 'codepoints');
  }
  return bindings.unicodeGraphemeWidth(codepoints);
}
