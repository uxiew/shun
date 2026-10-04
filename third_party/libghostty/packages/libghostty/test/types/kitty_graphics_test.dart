import 'package:libghostty/libghostty.dart';
import 'package:test/test.dart';

void main() {
  group('KittyPlacementRenderInfo', () {
    KittyPlacementRenderInfo create({int pixelWidth = 16}) =>
        KittyPlacementRenderInfo(
          pixelWidth: pixelWidth,
          pixelHeight: 32,
          gridCols: 2,
          gridRows: 2,
          viewportCol: -1,
          viewportRow: 3,
          viewportVisible: true,
          sourceX: 1,
          sourceY: 2,
          sourceWidth: 8,
          sourceHeight: 16,
        );

    group('offscreen', () {
      test('has no visible geometry', () {
        const info = KittyPlacementRenderInfo.offscreen();

        expect(info.viewportVisible, isFalse);
        expect(info.pixelWidth, 0);
        expect(info.pixelHeight, 0);
        expect(info.gridCols, 0);
        expect(info.gridRows, 0);
      });
    });

    group('equality', () {
      test('compares equal values structurally', () {
        final first = create();
        final second = create();

        expect(first, second);
      });

      test('produces equal hashes for equal values', () {
        final first = create();
        final second = create();

        expect(first.hashCode, second.hashCode);
      });

      test('distinguishes changed values', () {
        final first = create();
        final second = create(pixelWidth: 17);

        expect(first, isNot(second));
      });
    });
  });

  group('KittyPlacement', () {
    KittyPlacement create({int imageId = 42}) => KittyPlacement(
      imageId: imageId,
      placementId: 7,
      isVirtual: false,
      xOffset: 1,
      yOffset: 2,
      sourceX: 3,
      sourceY: 4,
      sourceWidth: 5,
      sourceHeight: 6,
      columns: 2,
      rows: 3,
      z: -1,
      renderInfo: const KittyPlacementRenderInfo.offscreen(),
    );

    group('equality', () {
      test('compares equal values structurally', () {
        final first = create();
        final second = create();

        expect(first, second);
      });

      test('produces equal hashes for equal values', () {
        final first = create();
        final second = create();

        expect(first.hashCode, second.hashCode);
      });

      test('distinguishes changed values', () {
        final first = create();
        final second = create(imageId: 43);

        expect(first, isNot(second));
      });
    });
  });
}
