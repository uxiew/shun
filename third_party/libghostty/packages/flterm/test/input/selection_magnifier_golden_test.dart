@Tags(['golden'])
library;

import 'package:flterm/src/input/selection_magnifier.dart'
    show SelectionCupertinoMagnifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../rendering/helpers/font_loader.dart' show loadBundledFonts;

void main() {
  group('SelectionMagnifier golden', () {
    final sceneKey = GlobalKey();
    late ValueNotifier<MagnifierInfo> magnifierInfo;

    setUp(() {
      magnifierInfo = ValueNotifier(
        const MagnifierInfo(
          globalGesturePosition: Offset(100, 158),
          caretRect: Rect.fromLTWH(99, 142, 2, 16),
          fieldBounds: Rect.fromLTWH(0, 0, 200, 220),
          currentLineBoundaries: Rect.fromLTWH(0, 142, 200, 16),
        ),
      );
      addTearDown(magnifierInfo.dispose);
    });

    Future<void> pumpSubject(
      WidgetTester tester, {
      required TargetPlatform platform,
      required Widget magnifier,
    }) async {
      await loadBundledFonts();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(200, 220);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: RepaintBoundary(
            key: sceneKey,
            child: ColoredBox(
              color: const Color(0xFFF3F3F3),
              child: Stack(
                children: [
                  const Positioned(
                    left: 12,
                    right: 12,
                    top: 128,
                    height: 52,
                    child: ColoredBox(
                      color: Color(0xFF102A43),
                      child: Center(
                        child: Text(
                          'FLTERM LOUPE',
                          style: TextStyle(
                            color: Color(0xFFFFE082),
                            fontFamily: 'JetBrains Mono',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            height: 1,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Positioned(
                    left: 99,
                    top: 142,
                    width: 2,
                    height: 16,
                    child: ColoredBox(color: Color(0xFF4DD0E1)),
                  ),
                  magnifier,
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    group('Android', () {
      testWidgets('magnifies high-contrast terminal text', (tester) async {
        await pumpSubject(
          tester,
          platform: TargetPlatform.android,
          magnifier: TextMagnifier(magnifierInfo: magnifierInfo),
        );

        await expectLater(
          find.byKey(sceneKey),
          matchesGoldenFile('goldens/selection_magnifier_android.png'),
        );
      });
    });

    group('iOS', () {
      testWidgets('magnifies high-contrast terminal text by 1.5×', (
        tester,
      ) async {
        await pumpSubject(
          tester,
          platform: TargetPlatform.iOS,
          magnifier: SelectionCupertinoMagnifier(
            magnifierInfo: magnifierInfo,
            filmColor: const Color(0x14102A43),
          ),
        );

        await expectLater(
          find.byKey(sceneKey),
          matchesGoldenFile('goldens/selection_magnifier_ios.png'),
        );
      });
    });
  });
}
