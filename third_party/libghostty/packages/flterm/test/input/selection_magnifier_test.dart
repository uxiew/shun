import 'package:flterm/src/input/selection_magnifier.dart'
    show SelectionCupertinoMagnifier, SelectionMagnifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('SelectionMagnifier', () {
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

    Future<void> pumpCupertino(
      WidgetTester tester, {
      Color filmColor = const Color(0x141D1F21),
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              SelectionCupertinoMagnifier(
                magnifierInfo: magnifierInfo,
                filmColor: filmColor,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('uses native-sized borderless iOS presentation', (
      tester,
    ) async {
      await pumpCupertino(tester);
      final magnifier = tester.widget<RawMagnifier>(find.byType(RawMagnifier));
      final shape = magnifier.decoration.shape as RoundedRectangleBorder;

      expect(magnifier.size, const Size(115, 85));
      expect(magnifier.magnificationScale, 1.5);
      expect(shape.side, BorderSide.none);
    });

    testWidgets('applies the terminal film color on iOS', (tester) async {
      const filmColor = Color(0x14224466);

      await pumpCupertino(tester, filmColor: filmColor);
      final magnifier = tester.widget<RawMagnifier>(find.byType(RawMagnifier));

      expect((magnifier.child! as ColoredBox).color, filmColor);
    });

    testWidgets('tracks the iOS pointer position within one frame', (
      tester,
    ) async {
      await pumpCupertino(tester);
      final before = tester.getTopLeft(find.byType(RawMagnifier));

      magnifierInfo.value = const MagnifierInfo(
        globalGesturePosition: Offset(124, 158),
        caretRect: Rect.fromLTWH(123, 142, 2, 16),
        fieldBounds: Rect.fromLTWH(0, 0, 200, 220),
        currentLineBoundaries: Rect.fromLTWH(0, 142, 200, 16),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        tester.getTopLeft(find.byType(RawMagnifier)),
        before.translate(24, 0),
      );
    });

    testWidgets('keeps handles inside the adaptive Android lens', (
      tester,
    ) async {
      late TextMagnifierConfiguration configuration;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Builder(
            builder: (context) {
              configuration = SelectionMagnifier.adaptive(
                context,
                Colors.black,
              );
              return const SizedBox();
            },
          ),
        ),
      );

      expect(configuration.shouldDisplayHandlesInMagnifier, isTrue);
    });

    testWidgets('keeps handles inside the adaptive iOS lens', (tester) async {
      late TextMagnifierConfiguration configuration;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Builder(
            builder: (context) {
              configuration = SelectionMagnifier.adaptive(
                context,
                Colors.black,
              );
              return const SizedBox();
            },
          ),
        ),
      );

      expect(configuration.shouldDisplayHandlesInMagnifier, isTrue);
    });
  });
}
