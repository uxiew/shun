part of 'terminal.dart';

/// Image storage associated with a terminal's active screen, exposing the
/// images and placements stored via the
/// [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
///
/// Obtained via [KittyGraphics.of]. The handle is borrowed from the
/// terminal and is invalidated by any mutating terminal call
/// ([Terminal.write], [Terminal.reset], [Terminal.resize]); re-read via
/// [of] after such operations rather than retaining the previous value.
///
/// Before any images are stored, Kitty graphics must be enabled on the
/// terminal by setting a non-zero [Terminal.kittyImageStorageLimit]. PNG
/// payloads additionally require a decoder installed via
/// [LibGhostty.setPngDecoder].
///
/// ```dart
/// final kitty = KittyGraphics.of(terminal);
/// if (kitty == null) return;
/// for (final placement in kitty.placements()) {
///   if (!placement.renderInfo.viewportVisible) continue;
///   final image = kitty.image(placement.imageId);
///   if (image == null) continue;
///   // draw `image.pixelData` cropped to `placement.renderInfo.source*`
///   // at grid cell (renderInfo.viewportCol, renderInfo.viewportRow).
/// }
/// ```
@immutable
final class KittyGraphics {
  final int _handle;
  final Terminal _terminal;

  const KittyGraphics._(this._handle, this._terminal);

  /// Returns the Kitty graphics image storage for [terminal]'s active
  /// screen, or null when Kitty graphics are disabled in the native
  /// library build.
  static KittyGraphics? of(Terminal terminal) {
    final handle = bindings.kittyGraphicsGet(terminal._handle);
    return handle == 0 ? null : KittyGraphics._(handle, terminal);
  }

  /// Storage-wide generation stamp for image content and placement changes.
  ///
  /// A changed value means the placement set or image data may be stale. If
  /// the value is unchanged since a previous query, the placement set and all
  /// image data are identical, so placement iteration and image staleness
  /// checks can be skipped.
  ///
  /// Geometry can still change when this value is unchanged, for example when
  /// scrolling or resizing moves placements through the viewport. Recompute
  /// placement [RenderInfo] on frames where terminal geometry or scroll state
  /// may have changed.
  ///
  /// Generation stamps are unique and monotonically increasing process-wide.
  /// Zero means the storage has never been mutated and is empty.
  int get generation => check(bindings.kittyGraphicsGetGeneration(_handle));

  /// Looks up an image by its Kitty graphics [imageId].
  ///
  /// Returns null when no image with that id is stored or when Kitty
  /// graphics are disabled in the native library build. The returned
  /// [KittyImage] handle is borrowed from the storage and is invalidated
  /// by any mutating terminal call.
  KittyImage? image(int imageId) {
    final handle = bindings.kittyGraphicsImage(_handle, imageId);
    if (handle == 0) return null;
    return KittyImage._(handle);
  }

  /// Snapshots every placement currently stored, optionally filtered by
  /// z-layer.
  ///
  /// Each [Placement] captures placement metadata and resolved render
  /// geometry at the time of this call. The snapshot data is stable
  /// across subsequent terminal mutations, but the image referenced via
  /// [Placement.imageId] is not; resolve it with [image] afresh when you
  /// need pixel bytes after a mutation.
  ///
  /// Passing a [layer] other than [KittyPlacementLayer.all] installs a
  /// z-layer filter on the iterator so placements outside the requested
  /// layer are skipped. See [KittyPlacementLayer] for the bucket
  /// boundaries.
  ///
  /// Throws [OutOfMemoryException] if the iterator allocation fails.
  List<Placement> placements({KittyPlacementLayer layer = .all}) {
    final iterator = check(bindings.kittyGraphicsPlacementIteratorNew());
    try {
      checkCode(bindings.kittyGraphicsGetPlacements(_handle, iterator));
      if (layer != KittyPlacementLayer.all) {
        checkCode(
          bindings.kittyGraphicsPlacementIteratorSetLayer(iterator, layer),
        );
      }
      final out = <Placement>[];
      while (bindings.kittyGraphicsPlacementNext(iterator)) {
        final raw = check(bindings.kittyGraphicsPlacementGet(iterator));
        final imageHandle = bindings.kittyGraphicsImage(_handle, raw.imageId);
        final RenderInfo renderInfo;
        if (imageHandle == 0) {
          renderInfo = const RenderInfo._offscreen();
        } else {
          final (code, info) = bindings.kittyGraphicsPlacementRenderInfo(
            iterator,
            imageHandle,
            _terminal._handle,
          );
          renderInfo = code == .success ? ._(info) : const ._offscreen();
        }
        out.add(Placement._(raw, renderInfo));
      }
      return out;
    } finally {
      bindings.kittyGraphicsPlacementIteratorFree(iterator);
    }
  }
}

/// Snapshot of a single Kitty graphics placement.
///
/// A placement pins an image (or a region of one) to a location in the
/// terminal grid. Fields mirror the raw placement data; use [renderInfo]
/// for resolved pixel/grid geometry that accounts for the terminal's
/// current viewport.
///
/// Snapshots are stable across subsequent terminal mutations: [renderInfo]
/// reflects the geometry at the time the enclosing [KittyGraphics.placements]
/// call ran. Resolve [imageId] to a live [KittyImage] via
/// [KittyGraphics.image] when pixel bytes are needed.
@immutable
final class Placement {
  /// Image id this placement references. Pass to [KittyGraphics.image] to
  /// resolve to a [KittyImage].
  final int imageId;

  /// Placement id assigned by the protocol, or zero when the placement
  /// was created without an explicit id.
  final int placementId;

  /// Whether this is a virtual (Unicode placeholder) placement.
  ///
  /// Virtual placements are anchored to specific cells via Unicode
  /// placeholder characters and do not participate in the normal
  /// rendering flow; consumers typically handle them specially.
  final bool isVirtual;

  /// Pixel offset from the left edge of the anchor cell.
  final int xOffset;

  /// Pixel offset from the top edge of the anchor cell.
  final int yOffset;

  /// Requested source rectangle x origin in pixels. Zero means "use the
  /// full image width"; see [RenderInfo.sourceX] for the resolved value.
  final int sourceX;

  /// Requested source rectangle y origin in pixels. Zero means "use the
  /// full image height"; see [RenderInfo.sourceY] for the resolved value.
  final int sourceY;

  /// Requested source rectangle width in pixels, or zero to use the full
  /// image width.
  final int sourceWidth;

  /// Requested source rectangle height in pixels, or zero to use the
  /// full image height.
  final int sourceHeight;

  /// Requested number of grid columns the placement occupies, or zero to
  /// derive from the image size.
  final int columns;

  /// Requested number of grid rows the placement occupies, or zero to
  /// derive from the image size.
  final int rows;

  /// Z-index controlling compositing order. Follows the Kitty protocol
  /// convention: negative values draw below text, non-negative above.
  /// See [KittyPlacementLayer] for the finer BELOW_BG / BELOW_TEXT /
  /// ABOVE_TEXT buckets.
  final int z;

  /// Resolved rendering geometry at the time of capture.
  final RenderInfo renderInfo;

  Placement._(RawPlacement raw, this.renderInfo)
    : imageId = raw.imageId,
      placementId = raw.placementId,
      isVirtual = raw.isVirtual,
      xOffset = raw.xOffset,
      yOffset = raw.yOffset,
      sourceX = raw.sourceX,
      sourceY = raw.sourceY,
      sourceWidth = raw.sourceWidth,
      sourceHeight = raw.sourceHeight,
      columns = raw.columns,
      rows = raw.rows,
      z = raw.z;
}

/// Resolved rendering geometry for a [Placement].
///
/// Combines rendered pixel size, grid extent, viewport-relative position,
/// and a resolved source rectangle (with zero-sized dimensions expanded
/// and bounds clamped to the image) into a single snapshot.
///
/// When [viewportVisible] is false, the placement is either fully
/// off-screen or virtual, and [viewportCol]/[viewportRow] may contain
/// meaningless values. Embedders should skip painting in that case.
/// For placements that scroll partially above the viewport, [viewportRow]
/// (and occasionally [viewportCol]) can be negative; embedders render the
/// full destination rectangle and rely on the canvas clip to hide the
/// off-screen portion.
@immutable
final class RenderInfo {
  /// Rendered width in pixels, accounting for the source rectangle,
  /// requested [Placement.columns]/[Placement.rows], and aspect ratio.
  final int pixelWidth;

  /// Rendered height in pixels.
  final int pixelHeight;

  /// Number of grid columns the placement occupies. When the placement
  /// specifies explicit [Placement.columns], that value is returned;
  /// otherwise the size is derived from pixel dimensions and cell
  /// geometry.
  final int gridCols;

  /// Number of grid rows the placement occupies.
  final int gridRows;

  /// Viewport-relative column of the placement's top-left corner. May be
  /// negative when the placement has scrolled partially above the
  /// top-left of the viewport.
  final int viewportCol;

  /// Viewport-relative row of the placement's top-left corner. May be
  /// negative for placements that have scrolled partially above the
  /// viewport's top row.
  final int viewportRow;

  /// Whether the placement is at least partially visible in the viewport
  /// and is not a virtual placement.
  final bool viewportVisible;

  /// Resolved source rectangle x origin in pixels, clamped to image
  /// bounds. Ready for direct use in texture sampling.
  final int sourceX;

  /// Resolved source rectangle y origin in pixels.
  final int sourceY;

  /// Resolved source rectangle width in pixels. A zero
  /// [Placement.sourceWidth] is expanded to the full image width here.
  final int sourceWidth;

  /// Resolved source rectangle height in pixels. A zero
  /// [Placement.sourceHeight] is expanded to the full image height here.
  final int sourceHeight;

  const RenderInfo._offscreen()
    : pixelWidth = 0,
      pixelHeight = 0,
      gridCols = 0,
      gridRows = 0,
      viewportCol = 0,
      viewportRow = 0,
      viewportVisible = false,
      sourceX = 0,
      sourceY = 0,
      sourceWidth = 0,
      sourceHeight = 0;

  RenderInfo._(RawPlacementRenderInfo raw)
    : pixelWidth = raw.pixelWidth,
      pixelHeight = raw.pixelHeight,
      gridCols = raw.gridCols,
      gridRows = raw.gridRows,
      viewportCol = raw.viewportCol,
      viewportRow = raw.viewportRow,
      viewportVisible = raw.viewportVisible,
      sourceX = raw.sourceX,
      sourceY = raw.sourceY,
      sourceWidth = raw.sourceWidth,
      sourceHeight = raw.sourceHeight;
}

/// A single image stored under the Kitty graphics protocol.
///
/// Obtained via [KittyGraphics.image]. The handle is borrowed from the
/// terminal's image storage: every accessor reads live data and is
/// invalidated by any mutating terminal call ([Terminal.write],
/// [Terminal.reset], [Terminal.resize]). Read the values you need
/// immediately and do not retain a [KittyImage] across mutations.
///
/// [pixelData] is the exception: it copies the bytes into a Dart-owned
/// [Uint8List], so the returned buffer remains valid after mutations.
@immutable
final class KittyImage {
  final int _handle;

  const KittyImage._(this._handle);

  /// Image id assigned by the Kitty graphics protocol.
  int get id => check(bindings.kittyGraphicsImageGetId(_handle));

  /// Image number assigned by the protocol, or zero when unset.
  int get number => check(bindings.kittyGraphicsImageGetNumber(_handle));

  /// Image width in pixels.
  int get width => check(bindings.kittyGraphicsImageGetWidth(_handle));

  /// Image height in pixels.
  int get height => check(bindings.kittyGraphicsImageGetHeight(_handle));

  /// Pixel format of [pixelData].
  KittyImageFormat get format {
    return check(bindings.kittyGraphicsImageGetFormat(_handle));
  }

  /// Compression of [pixelData].
  KittyImageCompression get compression {
    return check(bindings.kittyGraphicsImageGetCompression(_handle));
  }

  /// Generation stamp for this image's pixel contents.
  ///
  /// A changed value means cached texture data for this image id is stale, even
  /// when dimensions, format, and byte length are unchanged. This catches
  /// same-sized retransmissions that size heuristics cannot detect.
  ///
  /// Generation stamps are unique and monotonically increasing process-wide and
  /// use the same sequence as [KittyGraphics.generation]. Stored images never
  /// have generation zero, so zero can be used as an empty cache sentinel.
  int get generation =>
      check(bindings.kittyGraphicsImageGetGeneration(_handle));

  /// Raw pixel bytes, copied into a Dart-owned buffer so the list remains
  /// valid after subsequent terminal mutations.
  ///
  /// Stored images are already decoded and decompressed before they reach this
  /// API. PNG payloads are decoded through the callback installed via
  /// [LibGhostty.setPngDecoder] and exposed here as RGBA.
  Uint8List get pixelData {
    return check(bindings.kittyGraphicsImageGetPixelData(_handle));
  }
}
