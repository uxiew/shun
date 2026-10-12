import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/presentation/widgets/connection_route_editor.dart';

Future<void> tapRoute(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> createRouteProxy(WidgetTester tester,
    {String host = '127.0.0.1', String port = '1080', String? password}) async {
  await tapRoute(
      tester,
      find.byKey(ValueKey(
          find.byKey(const ValueKey('route-add-proxy')).evaluate().isNotEmpty
              ? 'route-add-proxy'
              : 'route-change-proxy')));
  await tapRoute(tester, find.byKey(const ValueKey('proxy-create')));
  await tester.enterText(
      find.byKey(const ValueKey('proxy-label')), 'test-proxy');
  await tester.enterText(find.byKey(const ValueKey('proxy-host')), host);
  await tester.enterText(find.byKey(const ValueKey('proxy-port')), port);
  if (password != null) {
    await tester.enterText(
        find.widgetWithText(TextFormField, '代理密码（可选）'), password);
  }
  await tapRoute(tester, find.byKey(const ValueKey('proxy-save')));
  expect(find.byType(ConnectionRouteEditor), findsOneWidget);
}

Future<void> addRouteJump(WidgetTester tester, String label) async {
  await tapRoute(
      tester,
      find.descendant(
          of: find.byType(ConnectionRouteEditor),
          matching: find.byType(DropdownButtonFormField<String>)));
  await tapRoute(tester, find.text(label).last);
  expect(tester.takeException(), isNull);
}
