import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/server_stats.dart';
import 'package:shun/infrastructure/ssh/server_monitor_service.dart';
import 'package:shun/presentation/widgets/server_network_chart.dart';

void main() {
  final start = DateTime(2026, 9, 6, 12);
  List<ServerStats> readings() {
    final parser = ServerMonitorService();
    return [
      parser.parse('NET=0 0', sampledAt: start),
      parser.parse('NET=92160 184320',
          sampledAt: start.add(const Duration(seconds: 90))),
      parser.parse('NET=276480 552960',
          sampledAt: start.add(const Duration(minutes: 3))),
    ];
  }

  Widget app(List<ServerStats> data,
          {double width = 320, bool stale = false, ThemeData? theme}) =>
      MaterialApp(
          theme: theme,
          home: Scaffold(
              body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                      width: width,
                      child:
                          ServerNetworkChart(samples: data, stale: stale)))));

  Color? legendColor(WidgetTester tester, String key) => (tester
          .widget<Container>(find.descendant(
              of: find.byKey(ValueKey(key)), matching: find.byType(Container)))
          .decoration! as BoxDecoration)
      .color;

  testWidgets('R91 图例跟主题色一致；断开前的数据标出来并变淡', (tester) async {
    for (final theme in [
      ThemeData(),
      ThemeData(brightness: Brightness.dark),
    ]) {
      final colors = theme.colorScheme;
      await tester.pumpWidget(app(readings(), theme: theme));
      await tester.pumpAndSettle();
      expect(find.text('接收'), findsOneWidget);
      expect(find.text('发送'), findsOneWidget);
      expect(legendColor(tester, 'network-legend-rx'), colors.primary);
      expect(legendColor(tester, 'network-legend-tx'), colors.tertiary);
      expect(find.byKey(const ValueKey('network-chart-stale')), findsNothing);

      await tester.pumpWidget(app(readings(), theme: theme, stale: true));
      expect(find.byKey(const ValueKey('network-chart-stale')), findsOneWidget);
      expect(legendColor(tester, 'network-legend-rx'),
          colors.primary.withValues(alpha: .45));
      expect(legendColor(tester, 'network-legend-tx'),
          colors.tertiary.withValues(alpha: .45));
      // 断开后还能按住看断开前的读数。
      final rect = tester
          .getRect(find.byKey(const ValueKey('network-chart-touch-area')));
      final gesture = await tester.startGesture(rect.center);
      await tester.pump();
      expect(
          find.byKey(const ValueKey('network-chart-tooltip')), findsOneWidget);
      await gesture.up();
      await tester.pump();
    }
  });

  test('traffic totals format large counters without long GB strings', () {
    expect(formatTrafficBytes(0), '0 B');
    expect(formatTrafficBytes(1024), '1.0 KB');
    expect(formatTrafficBytes(1024 * 1024 * 1024 * 1024), '1.0 TB');
  });

  testWidgets('axis, immediate touch, drag, frozen samples and release',
      (tester) async {
    final samples = readings();
    await tester.pumpWidget(app(samples));
    expect(find.text('12:00:00'), findsOneWidget);
    expect(find.text('12:01:30'), findsOneWidget);
    expect(find.text('12:03:00'), findsOneWidget);
    final rect =
        tester.getRect(find.byKey(const ValueKey('network-chart-touch-area')));
    final gesture = await tester.startGesture(rect.center);
    await tester.pump();
    expect(find.byKey(const ValueKey('network-chart-tooltip')), findsOneWidget);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-time')))
            .data,
        '12:01:30');
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-rx')))
            .data,
        '1.0 KB/s');
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-tx')))
            .data,
        '2.0 KB/s');
    await gesture.moveTo(Offset(rect.right - 1, rect.center.dy));
    await tester.pump();
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-time')))
            .data,
        '12:03:00');
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-rx')))
            .data,
        '2.0 KB/s');
    final newer = ServerMonitorService().parse('NET=500000 800000',
        sampledAt: start.add(const Duration(minutes: 4)));
    await tester.pumpWidget(app([...samples, newer]));
    expect(find.text('12:04:00'), findsNothing);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-time')))
            .data,
        '12:03:00');
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('network-chart-tooltip')), findsNothing);
    expect(find.text('12:04:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single sample and cancelled touch work on a narrow chart',
      (tester) async {
    await tester.pumpWidget(app([readings().last], width: 220));
    final rect =
        tester.getRect(find.byKey(const ValueKey('network-chart-touch-area')));
    final gesture =
        await tester.startGesture(Offset(rect.left + 1, rect.center.dy));
    await tester.pump();
    final tooltip =
        tester.getRect(find.byKey(const ValueKey('network-chart-tooltip')));
    expect(tooltip.left, greaterThanOrEqualTo(rect.left));
    expect(tooltip.right, lessThanOrEqualTo(rect.right));
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-time')))
            .data,
        '12:03:00');
    await gesture.cancel();
    await tester.pump();
    expect(find.byKey(const ValueKey('network-chart-tooltip')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(app([]));
    expect(find.text('暂无详细数据'), findsOneWidget);
  });

  testWidgets('stale chart wraps its legend at large text sizes',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(app(readings(), width: 220, stale: true));
    final receive =
        tester.getRect(find.byKey(const ValueKey('network-legend-rx')));
    final stale =
        tester.getRect(find.byKey(const ValueKey('network-chart-stale')));
    expect(stale.top, greaterThanOrEqualTo(receive.bottom));
    expect(tester.takeException(), isNull);
  });
}
