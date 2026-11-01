import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/presentation/widgets/connection_route_editor.dart';

Future<void> tapRoute(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 「高级」默认收起（F39）。已经开着就什么也不做。
Future<void> openAdvanced(WidgetTester tester) async {
  if (find.byKey(const ValueKey('advanced-organize')).evaluate().isNotEmpty) {
    return;
  }
  await tapRoute(tester, find.byKey(const ValueKey('advanced-all')));
}

/// 连接路径在「高级」的第一组。
Future<void> openRouteEditor(WidgetTester tester) async {
  bool shown() =>
      find.byType(ConnectionRouteEditor).evaluate().isNotEmpty ||
      find.byKey(const ValueKey('telnet-direct-only')).evaluate().isNotEmpty;
  // 导入页没有「高级」，路线编辑器一直摆着。
  if (shown()) return;
  await openAdvanced(tester);
  if (shown()) return;
  await tapRoute(tester, find.byKey(const ValueKey('advanced-route')));
}

/// 在表单顶上的「连接类型」里换一个。[type] 是面板里显示的名字：SSH、Mosh、Telnet、插件名。
Future<void> chooseConnectionType(WidgetTester tester, String type) async {
  await tapRoute(tester, find.byKey(const ValueKey('host-protocol')));
  await tapRoute(tester, find.byKey(ValueKey('connection-type-$type')));
}

Future<void> createRouteProxy(WidgetTester tester,
    {String host = '127.0.0.1', String port = '1080', String? password}) async {
  await openRouteEditor(tester);
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
  await openRouteEditor(tester);
  await tapRoute(
      tester,
      find.descendant(
          of: find.byType(ConnectionRouteEditor),
          matching: find.byType(DropdownButtonFormField<String>)));
  await tapRoute(tester, find.text(label).last);
  expect(tester.takeException(), isNull);
}
