import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/host_editor.dart';

// R41 / UX07 on a device: the real soft keyboard, a real touch and the real back key.
// Run it through tool/r41-device.py, which reads this test's output:
//   "R41 SHOT <name>"  -> adb screencap into the evidence directory
//   "R41 TAP <x> <y>"  -> adb shell input tap at those physical pixels
//   "R41 BACK"         -> one BACK key event (the test hides the IME first, so it
//                        reaches the app instead of just closing the keyboard)
// A widget-level tap cannot prove the IME is not covering the button; the adb tap
// lands on the keyboard if it is. The editor never persists anything itself, so
// this test writes nothing to the vault.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 默认测试期间设备上的真实触摸不会交给 App（只画调试圈），adb 的 tap 就白点了。
  binding.shouldPropagateDevicePointerEvents = true;

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() ready,
    String reason, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = tester.binding.clock.now().add(timeout);
    while (!ready() && tester.binding.clock.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ready(), isTrue, reason: reason);
  }

  Future<void> hold(WidgetTester tester, Duration duration) async {
    final until = tester.binding.clock.now().add(duration);
    while (tester.binding.clock.now().isBefore(until)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  Finder key(String value) => find.byKey(ValueKey(value));

  testWidgets('R41 UX07: keyboard up, real tap on save; real back asks first',
      (tester) async {
    final repository = await VaultRepository.open();
    HostProfile? editing;
    HostProfile? result;
    var closed = false;
    await tester.pumpWidget(ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  closed = false;
                  result = null;
                  // Same options as the vault screen opens the editor with.
                  result = await showModalBottomSheet<HostProfile>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    enableDrag: false,
                    builder: (_) => HostEditor(host: editing),
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final view = tester.view;
    debugPrint('R41 VIEW ${view.physicalSize.width.round()}x'
        '${view.physicalSize.height.round()} dpr=${view.devicePixelRatio}');

    // 1. New host. The last field keeps focus, so the IME stays up.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(field('名称'), 'r41-device');
    await tester.enterText(field('主机名 / IP'), 'r41.invalid');
    await tester.enterText(field('用户名'), 'fixture');
    await waitFor(tester, () => view.viewInsets.bottom > 0,
        'the soft keyboard must be up for this check to mean anything');
    await hold(tester, const Duration(seconds: 1));
    final dpr = view.devicePixelRatio;
    final keyboardTop =
        (view.physicalSize.height - view.viewInsets.bottom) / dpr;
    final save = tester.getRect(key('host-editor-save'));
    debugPrint('R41 GEOMETRY keyboardTop=${keyboardTop.toStringAsFixed(1)} '
        'saveBottom=${save.bottom.toStringAsFixed(1)}');
    expect(save.bottom, lessThanOrEqualTo(keyboardTop));
    debugPrint('R41 SHOT keyboard-new-host');
    await hold(tester, const Duration(seconds: 3));
    debugPrint('R41 TAP ${(save.center.dx * dpr).round()} '
        '${(save.center.dy * dpr).round()}');
    await waitFor(tester, () => closed,
        'a real touch on save above the keyboard must save and close');
    expect(result?.hostname, 'r41.invalid');
    expect(view.viewInsets.bottom, greaterThanOrEqualTo(0));
    debugPrint('R41 PASS keyboard-save');

    // 2. Existing host with an unsaved edit: the real back key must ask first.
    editing = result;
    await hold(tester, const Duration(seconds: 1));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(field('名称'), 'r41-device-renamed');
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await waitFor(tester, () => view.viewInsets.bottom == 0, 'IME hidden');
    await hold(tester, const Duration(seconds: 1));
    debugPrint('R41 BACK');
    await waitFor(tester, () => find.text('放弃没保存的改动？').evaluate().isNotEmpty,
        'system back with unsaved edits must ask before leaving');
    expect(closed, isFalse);
    await tester.pumpAndSettle();
    debugPrint('R41 SHOT back-asks');
    await hold(tester, const Duration(seconds: 3));
    await tester.tap(key('host-editor-keep-editing'));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsOneWidget);
    expect(find.text('r41-device-renamed'), findsOneWidget);
    await tester.tap(key('host-editor-cancel'));
    await tester.pumpAndSettle();
    await tester.tap(key('host-editor-discard'));
    await waitFor(tester, () => closed, 'discard closes the editor');
    expect(result, isNull, reason: 'discarded edits are not returned');
    debugPrint('R41 PASS back-confirm');
  });
}
