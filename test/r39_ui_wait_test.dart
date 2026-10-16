import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/r39_ui.dart';

void main() {
  testWidgets('device wait observes publication after frames already settled',
      (tester) async {
    var saved = false;
    Future<void>.delayed(const Duration(milliseconds: 300), () => saved = true);
    await r39Frames(tester);
    expect(saved, isFalse, reason: 'Settled UI does not await pending IO');
    await r39WaitFor(tester, () => saved, reason: 'Save not published');
    expect(saved, isTrue);
  });

  testWidgets(
      'device wait has a bounded failure instead of silently proceeding',
      (tester) async {
    final start = tester.binding.clock.now();
    Object? failure;
    try {
      await r39WaitFor(tester, () => false,
          reason: 'Save never published',
          timeout: const Duration(milliseconds: 300));
    } on Object catch (error) {
      failure = error;
    }
    expect(failure, isA<TestFailure>());
    expect(tester.binding.clock.now().difference(start),
        const Duration(milliseconds: 300));
  });

  testWidgets('back helper works under the zh-CN locale ShunApp defaults to',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                              appBar: AppBar(title: const Text('detail'))))),
                  child: const Text('open')))),
    ));
    await tester.tap(find.text('open'));
    await r39Frames(tester);
    expect(find.byTooltip('返回'), findsOneWidget);
    // The device failure: pageBack searches for the English 'Back' tooltip.
    Object? failure;
    try {
      await tester.pageBack();
    } on TestFailure catch (error) {
      failure = error;
    }
    expect(failure, isA<TestFailure>());
    await r39Back(tester);
    expect(find.text('detail'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
