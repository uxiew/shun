import 'package:flterm/src/foundation/surface_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SurfaceGeometry', () {
    SurfaceMeasurement measurement({
      int cols = 80,
      int rows = 24,
      double cellWidth = 8,
      double cellHeight = 16,
      double paddingLeft = 4,
      double paddingRight = 4,
      double paddingTop = 2,
      double paddingBottom = 2,
      double devicePixelRatio = 2,
    }) => SurfaceMeasurement(
      cols: cols,
      rows: rows,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      paddingLeft: paddingLeft,
      paddingRight: paddingRight,
      paddingTop: paddingTop,
      paddingBottom: paddingBottom,
      devicePixelRatio: devicePixelRatio,
    );

    group('tryFrom', () {
      test('normalizes logical measurements to physical pixels', () {
        final geometry = SurfaceGeometry.tryFrom(measurement());

        expect(
          (
            cellWidth: geometry?.cellWidthPx,
            cellHeight: geometry?.cellHeightPx,
            screenWidth: geometry?.screenWidth,
            screenHeight: geometry?.screenHeight,
          ),
          (cellWidth: 16, cellHeight: 32, screenWidth: 1296, screenHeight: 776),
        );
      });

      test('rejects an empty grid', () {
        final geometry = SurfaceGeometry.tryFrom(measurement(cols: 0));

        expect(geometry, isNull);
      });

      test('rejects a grid beyond the native limit', () {
        final geometry = SurfaceGeometry.tryFrom(measurement(rows: 0x10000));

        expect(geometry, isNull);
      });

      test('rejects a non-positive cell size', () {
        final geometry = SurfaceGeometry.tryFrom(measurement(cellWidth: 0));

        expect(geometry, isNull);
      });

      test('rejects a non-finite cell size', () {
        final geometry = SurfaceGeometry.tryFrom(
          measurement(cellHeight: double.nan),
        );

        expect(geometry, isNull);
      });

      test('rejects negative padding', () {
        final geometry = SurfaceGeometry.tryFrom(measurement(paddingTop: -1));

        expect(geometry, isNull);
      });

      test('rejects a non-positive device pixel ratio', () {
        final geometry = SurfaceGeometry.tryFrom(
          measurement(devicePixelRatio: 0),
        );

        expect(geometry, isNull);
      });

      test('rejects a cell that rounds to zero physical pixels', () {
        final geometry = SurfaceGeometry.tryFrom(
          measurement(cellWidth: 0.1, devicePixelRatio: 1),
        );

        expect(geometry, isNull);
      });

      test('rejects a physical measurement beyond the mouse limit', () {
        final geometry = SurfaceGeometry.tryFrom(
          measurement(paddingRight: 0x100000000),
        );

        expect(geometry, isNull);
      });

      test('rejects a screen extent beyond the mouse limit', () {
        final geometry = SurfaceGeometry.tryFrom(
          measurement(
            cols: 0xffff,
            cellWidth: 0x10002,
            paddingLeft: 0,
            paddingRight: 0,
            paddingTop: 0,
            paddingBottom: 0,
            devicePixelRatio: 1,
          ),
        );

        expect(geometry, isNull);
      });
    });

    group('equality', () {
      test('compares normalized measurements by value', () {
        final first = SurfaceGeometry.tryFrom(measurement());
        final second = SurfaceGeometry.tryFrom(measurement());

        expect(first, second);
      });

      test('produces equal hashes for equal measurements', () {
        final first = SurfaceGeometry.tryFrom(measurement());
        final second = SurfaceGeometry.tryFrom(measurement());

        expect(first.hashCode, second.hashCode);
      });
    });
  });
}
