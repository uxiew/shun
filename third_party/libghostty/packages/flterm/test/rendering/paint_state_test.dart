import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PaintState', () {
    final theme = TerminalTheme.dark();
    const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

    group('constructor', () {
      test('computes derived fields from theme', () {
        final state = PaintState(theme, metrics);

        expect(state.theme, theme);
        expect(state.metrics, metrics);
        expect(state.faintAlpha, (theme.faintOpacity * 255).ceil());
        expect(state.terminalForegroundArgb, theme.foreground.toARGB32());
        expect(state.terminalBackgroundArgb, theme.background.toARGB32());
      });
    });

    group('updateTheme', () {
      test('recomputes derived fields', () {
        final state = PaintState(theme, metrics);
        final light = TerminalTheme.light();

        state.updateTheme(light);

        expect(state.theme, light);
        expect(state.faintAlpha, (light.faintOpacity * 255).ceil());
      });

      test('faintAlpha reflects new faintOpacity', () {
        final state = PaintState(theme, metrics);

        state.updateTheme(theme.copyWith(faintOpacity: 0.0));
        expect(state.faintAlpha, 0);

        state.updateTheme(theme.copyWith(faintOpacity: 1.0));
        expect(state.faintAlpha, 255);
      });
    });

    group('ensureContrast (shun)', () {
      test('is a no-op at the default minimum of 1', () {
        final state = PaintState(theme, metrics);

        expect(state.ensureContrast(0xFFFFFFFF, 0xFFFFFFFF), 0xFFFFFFFF);
      });

      test('adjusts the color and keeps the faint alpha', () {
        final state = PaintState(theme.copyWith(minimumContrast: 3), metrics);

        final adjusted = state.ensureContrast(0x80F0C674, 0xFFFFFFFF);

        expect(adjusted >>> 24, 0x80);
        expect(adjusted & 0xFFFFFF, isNot(0xF0C674));
      });

      test('follows a theme change', () {
        final state = PaintState(theme.copyWith(minimumContrast: 3), metrics);
        final before = state.ensureContrast(0xFFF0C674, 0xFFFFFFFF);

        state.updateTheme(theme);

        expect(before, isNot(0xFFF0C674));
        expect(state.ensureContrast(0xFFF0C674, 0xFFFFFFFF), 0xFFF0C674);
      });
    });

    group('mutable state', () {
      test('starts with default frame state', () {
        final state = PaintState(theme, metrics);

        expect(state.rows, 0);
        expect(state.cols, 0);
        expect(state.blinkVisible, isTrue);
        expect(state.viewportOffset, 0);
        expect(state.cursorWide, isFalse);
        expect(state.cursorFocused, isTrue);
      });
    });
  });
}
