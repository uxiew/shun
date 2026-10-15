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
}
