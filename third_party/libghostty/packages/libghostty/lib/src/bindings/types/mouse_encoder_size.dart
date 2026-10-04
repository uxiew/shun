/// Renderer size context for mouse encoder pixel-to-cell coordinate conversion.
///
/// Describes the rendered terminal geometry used to convert surface-space
/// pixel positions into encoded cell coordinates. Pass to
/// [MouseEncoder.setSize] whenever the terminal grid dimensions or cell size
/// change.
///
/// [cellWidth] and [cellHeight] must be non-zero.
class MouseEncoderSize {
  /// Full screen width in pixels.
  final int screenWidth;

  /// Full screen height in pixels.
  final int screenHeight;

  /// Cell width in pixels. Must be non-zero.
  final int cellWidth;

  /// Cell height in pixels. Must be non-zero.
  final int cellHeight;

  /// Top padding in pixels.
  final int paddingTop;

  /// Bottom padding in pixels.
  final int paddingBottom;

  /// Left padding in pixels.
  final int paddingLeft;

  /// Right padding in pixels.
  final int paddingRight;

  const MouseEncoderSize({
    required this.screenWidth,
    required this.screenHeight,
    required this.cellWidth,
    required this.cellHeight,
    this.paddingTop = 0,
    this.paddingBottom = 0,
    this.paddingLeft = 0,
    this.paddingRight = 0,
  });
}
