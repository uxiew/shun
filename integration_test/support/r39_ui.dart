import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

Finder r39Key(String value) => find.byKey(ValueKey(value));

Future<void> r39Frames(WidgetTester tester) =>
    tester.pumpAndSettle(const Duration(milliseconds: 100));

/// Settled frames do not imply that Android secure-storage writes have finished.
/// Wait for the observable result, using the binding clock in both test modes.
Future<void> r39WaitFor(WidgetTester tester, bool Function() ready,
    {required String reason,
    Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = tester.binding.clock.now().add(timeout);
  while (!ready() && tester.binding.clock.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: reason);
}

/// ShunApp defaults to zh-CN, where the AppBar back tooltip is 「返回」.
/// WidgetTester.pageBack only looks for the English 'Back' tooltip (or a
/// Cupertino button), so on the real app it finds nothing and fails.
Future<void> r39Back(WidgetTester tester) async {
  final back = find.byType(BackButton);
  expect(back, findsOneWidget, reason: 'One AppBar back button expected');
  await tester.tap(back);
  await r39Frames(tester);
}

Future<void> r39Tap(WidgetTester tester, Finder finder,
    {bool settle = true}) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 240,
        scrollable: find.byType(Scrollable).first, maxScrolls: 30);
  }
  await tester.ensureVisible(finder);
  await r39Frames(tester);
  await tester.tap(finder);
  if (settle) await r39Frames(tester);
}

Future<void> r39Type(WidgetTester tester, Finder finder, String value) async {
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await r39Frames(tester);
}

Future<void> r39HideKeyboard(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  await r39Frames(tester);
}

/// File gates work even before flutter drive attaches to a cold-started engine.
/// Only safe gate names go into logs; callback contents never do.
Future<void> r39Gate(WidgetTester tester, String name) async {
  final support = await getApplicationSupportDirectory();
  final root = Directory('${support.path}/r39');
  await File('${root.path}/gate').writeAsString(name, flush: true);
  final ack = File('${root.path}/ack-$name');
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (!await ack.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('R39 host did not acknowledge $name');
    }
    // External clients may own the foreground; do not wait for a Flutter frame
    // that Android is allowed to suspend until the host brings us back.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await r39Frames(tester);
  expect(tester.takeException(), isNull);
}

Future<void> r39Select(WidgetTester tester, String type) async {
  await r39Tap(tester, find.byTooltip('添加连接'));
  await r39Tap(tester, r39Key('connection-type-$type'));
}
