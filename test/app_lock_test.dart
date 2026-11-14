import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/app.dart';
import 'package:shun/application/app_lock.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/infrastructure/device_auth.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/app_lock_settings_screen.dart';
import 'package:shun/presentation/ui/prism_localizations.dart';
import 'package:shun/presentation/widgets/app_lock_gate.dart';
import 'package:package_info_plus/package_info_plus.dart';

// R46 应用锁的规则和页面。系统验证框、最近任务在设备上测（integration_test/r46_app_lock_test.dart）。

class FakeAuth implements DeviceAuth {
  var secure = true;
  var calls = 0;
  final titles = <String>[];
  bool? lastPinOnly;
  bool? lastAllowWeak;
  final protect = <bool>[];
  DeviceAuthOutcome next = const DeviceAuthOutcome(DeviceAuthResult.success);
  Completer<DeviceAuthOutcome>? hold;

  /// 验证框开着时发生的事（系统 PIN 页把 App 顶到后台）。
  void Function()? duringPrompt;

  @override
  set onActivityPaused(void Function(bool ownActivity)? callback) {}

  @override
  Future<bool> isDeviceSecure() async => secure;

  @override
  Future<DeviceAuthOutcome> authenticate({
    required String title,
    String? description,
    required bool pinOnly,
    required bool allowWeak,
  }) async {
    calls++;
    titles.add(title);
    lastPinOnly = pinOnly;
    lastAllowWeak = allowWeak;
    duringPrompt?.call();
    return hold?.future ?? next;
  }

  @override
  Future<void> setProtectRecents(bool enabled) async => protect.add(enabled);
}

void main() {
  group('什么时候锁', () {
    late FakeAuth auth;
    late DateTime now;
    var connected = false;

    AppLockController controllerWith(AppSettings settings) {
      final controller = AppLockController(
        auth: auth,
        settings: settings,
        hasConnectedTerminal: () => connected,
        now: () => now,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    /// 冷启动后先解锁一次，进入「开着用」的状态。
    Future<AppLockController> unlocked(AppSettings settings) async {
      final controller = controllerWith(settings);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(controller.state.obscured, isFalse);
      auth.calls = 0;
      return controller;
    }

    void leave(AppLockController controller, {bool ownActivity = false}) {
      controller.activityPaused(ownActivity);
      controller.lifecycleChanged(AppLifecycleState.paused);
    }

    const on = AppSettings(appLockEnabled: true);

    setUp(() {
      auth = FakeAuth();
      now = DateTime(2026, 10, 31, 12);
      connected = false;
    });

    test('没开：从头到尾不盖、不弹验证', () async {
      final controller = controllerWith(const AppSettings());
      expect(controller.state.obscured, isFalse);
      controller.activityPaused(false);
      controller.lifecycleChanged(AppLifecycleState.paused);
      expect(controller.state.obscured, isFalse);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 0);
      expect(controller.state.obscured, isFalse);
    });

    test('冷启动：第一帧就是锁着的，回到前台才弹验证', () async {
      final controller = controllerWith(on);
      expect(controller.state.locked, isTrue);
      await pumpEventQueue();
      expect(auth.calls, 0, reason: '后台恢复时没有界面能弹');
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
      expect(controller.state.locked, isFalse);
    });

    test('宽限期内回来不锁，到点就锁', () async {
      final controller = await unlocked(on);
      leave(controller);
      expect(controller.state.covered, isTrue, reason: '离开就盖上');
      now = now.add(const Duration(seconds: 59));
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 0);
      expect(controller.state.obscured, isFalse, reason: '没到点盖子揭掉');

      leave(controller);
      now = now.add(const Duration(seconds: 60));
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
      expect(controller.state.locked, isTrue);
    });

    test('立即：离开就要解锁', () async {
      final controller = await unlocked(
        on.copyWith(appLockGraceSeconds: 0),
      );
      leave(controller);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
    });

    test('从自己拉起的页面回来：立即也宽限 1 分钟，超了照锁', () async {
      final controller = await unlocked(
        on.copyWith(appLockGraceSeconds: 0),
      );
      leave(controller, ownActivity: true);
      now = now.add(const Duration(seconds: 30));
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 0);

      leave(controller, ownActivity: true);
      now = now.add(appLockOwnActivityGrace);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
    });

    test('终端连着不锁：只在有连着的终端时免', () async {
      final controller = await unlocked(
        on.copyWith(appLockGraceSeconds: 0, appLockSkipWhileConnected: true),
      );
      connected = true;
      leave(controller);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 0);
      expect(controller.state.obscured, isFalse);

      connected = false;
      leave(controller);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
    });

    test('手机时间往回拨：算过期', () async {
      final controller = await unlocked(
        on.copyWith(appLockGraceSeconds: 3600),
      );
      leave(controller);
      now = now.subtract(const Duration(minutes: 1));
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
    });

    test('下拉通知栏、弹框抢焦点（只有 inactive）：不盖不锁', () async {
      final controller = await unlocked(
        on.copyWith(appLockGraceSeconds: 0),
      );
      controller.lifecycleChanged(AppLifecycleState.inactive);
      expect(controller.state.obscured, isFalse);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 0);
    });

    test('取消验证：框消失时的 resumed 不再弹，不然用户退不出来', () async {
      final controller = controllerWith(on);
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
      expect(controller.state.locked, isTrue);
      controller.lifecycleChanged(AppLifecycleState.inactive);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
      expect(controller.state.locked, isTrue);
    });

    test('锁着退到后台再回来：再弹一次', () async {
      final controller = controllerWith(on);
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      leave(controller);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 2);
    });

    test('验证开着时系统 PIN 页把我们顶到后台：不算离开，不重复弹', () async {
      final controller = controllerWith(on);
      auth.hold = Completer<DeviceAuthOutcome>();
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
      leave(controller);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
      auth.hold!.complete(const DeviceAuthOutcome(DeviceAuthResult.success));
      await pumpEventQueue();
      expect(controller.state.obscured, isFalse);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1, reason: '解锁后紧跟着的 resumed 不能再锁');
    });

    test('验证失败：留着锁、显示系统给的原因；手机没屏幕锁了：放行', () async {
      final controller = controllerWith(on);
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.failed, '指纹不对');
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(controller.state.locked, isTrue);
      expect(controller.state.failure, '指纹不对');

      auth.next = const DeviceAuthOutcome(DeviceAuthResult.unavailable);
      await controller.unlock();
      expect(controller.state.obscured, isFalse);
    });

    test('应用内验证：PIN 页顶到后台再回来，不再锁一次、不再弹一次', () async {
      final controller = await unlocked(on.copyWith(appLockGraceSeconds: 0));
      auth.duringPrompt = () => leave(controller);
      final outcome = await controller.confirm('关闭应用锁');
      expect(outcome.result, DeviceAuthResult.success);
      expect(controller.state.obscured, isFalse);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
      expect(controller.state.obscured, isFalse);
    });

    test('应用内验证取消：1 分钟内回来不锁，先收到 resumed 还是先收到结果都一样', () async {
      final controller = await unlocked(on.copyWith(appLockGraceSeconds: 0));
      auth.duringPrompt = () => leave(controller);
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
      await controller.confirm('sudo');
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
      expect(controller.state.obscured, isFalse);

      auth.hold = Completer<DeviceAuthOutcome>();
      final pending = controller.confirm('sudo');
      await pumpEventQueue();
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(controller.state.obscured, isFalse);
      auth.hold!.complete(const DeviceAuthOutcome(DeviceAuthResult.canceled));
      await pending;
      expect(auth.calls, 2);
      expect(controller.state.obscured, isFalse);
    });

    test('应用内验证开着时按 HOME 走开太久：回来照样锁', () async {
      final controller = await unlocked(on.copyWith(appLockGraceSeconds: 0));
      auth.duringPrompt = () => leave(controller);
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
      await controller.confirm('sudo');
      auth.duringPrompt = null;
      now = now.add(appLockOwnActivityGrace);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(controller.state.locked, isTrue);
      expect(auth.calls, 2);
    });

    test('应用内验证和解锁不会同时弹', () async {
      final controller = controllerWith(on);
      auth.hold = Completer<DeviceAuthOutcome>();
      unawaited(controller.unlock());
      await pumpEventQueue();
      final outcome = await controller.confirm('sudo');
      expect(outcome.result, DeviceAuthResult.canceled);
      expect(auth.calls, 1);
      auth.hold!.complete(const DeviceAuthOutcome(DeviceAuthResult.success));
    });

    test('只有 Flutter 生命周期（画中画窗口被关掉）：也算离开，回来第一帧盖着', () async {
      final controller = await unlocked(on.copyWith(appLockGraceSeconds: 0));
      controller.lifecycleChanged(AppLifecycleState.paused);
      expect(controller.state.covered, isTrue);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
    });

    test('没开应用锁时应用内验证也能用（sudo 键）', () async {
      final controller = controllerWith(const AppSettings());
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
      final outcome = await controller.confirm('sudo');
      expect(outcome.result, DeviceAuthResult.canceled);
      expect(auth.calls, 1);
      expect(controller.state.obscured, isFalse);
    });

    test('平台通道没接上：留着锁，还能再试', () async {
      final throwing = AppLockController(
        auth: _MissingAuth(),
        settings: on,
        hasConnectedTerminal: () => false,
      );
      addTearDown(throwing.dispose);
      await throwing.unlock();
      expect(throwing.state.locked, isTrue);
      expect(throwing.state.authenticating, isFalse);
    });

    test('平台通道抛异常：留着锁，不放行', () async {
      final throwing = AppLockController(
        auth: _ThrowingAuth(),
        settings: on,
        hasConnectedTerminal: () => false,
      );
      addTearDown(throwing.dispose);
      await throwing.unlock();
      expect(throwing.state.locked, isTrue);
      expect(throwing.state.failure, 'busy');
    });

    test('用设置里的验证方式', () async {
      final controller = controllerWith(
        on.copyWith(appLockPinOnly: true, appLockAllowWeakBiometrics: true),
      );
      await controller.unlock();
      expect(auth.lastPinOnly, isTrue);
      expect(auth.lastAllowWeak, isTrue);
    });

    test('关掉应用锁：正盖着也马上揭开', () async {
      final controller = controllerWith(on);
      expect(controller.state.locked, isTrue);
      controller.settingsChanged(const AppSettings());
      expect(controller.state.obscured, isFalse);
    });
  });

  group('盖子', () {
    late FakeAuth auth;

    Future<ProviderContainer> pumpGate(
      WidgetTester tester,
      AppSettings settings,
    ) async {
      auth = FakeAuth()
        ..next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
      final container = ProviderContainer(overrides: [
        appLockControllerProvider.overrideWith(
          (ref) => AppLockController(
            auth: auth,
            settings: settings,
            hasConnectedTerminal: () => false,
          ),
        ),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => AppLockGate(child: child!),
          home: Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => tapped = true,
                  child: const Text('主机列表'),
                ),
                const TextField(key: ValueKey('draft'), autofocus: true),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
      return container;
    }

    setUp(() => tapped = false);

    testWidgets('锁着：底下的东西点不到、读屏念不到、键盘打不进去', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpGate(tester, const AppSettings(appLockEnabled: true));
      expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
      await tester.tap(find.text('主机列表'), warnIfMissed: false);
      await tester.pump();
      expect(tapped, isFalse);
      expect(find.bySemanticsLabel('主机列表'), findsNothing);
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      semantics.dispose();
    });

    testWidgets('取消后有解锁按钮；通过验证后底下的东西回来，还是原来那个', (tester) async {
      await pumpGate(tester, const AppSettings(appLockEnabled: true));
      final field = tester.state(find.byKey(const ValueKey('draft')));
      final unlock = find.byKey(const ValueKey('app-lock-unlock'));
      expect(unlock, findsOneWidget);
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.success);
      await tester.tap(unlock);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-cover')), findsNothing);
      expect(tester.state(find.byKey(const ValueKey('draft'))), same(field));
      await tester.tap(find.text('主机列表'));
      expect(tapped, isTrue);
    });

    testWidgets('离开时先收输入、回来恢复原焦点；真锁过也能恢复', (tester) async {
      final container = await pumpGate(tester, const AppSettings());
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
      final controller = container.read(appLockControllerProvider.notifier);
      controller.settingsChanged(
        const AppSettings(appLockEnabled: true, appLockGraceSeconds: 3600),
      );
      controller.activityPaused(false);
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
      expect(field.focusNode.hasFocus, isFalse, reason: '遮挡期间不保留 IME 连接');
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-cover')), findsNothing);
      expect(field.focusNode.hasFocus, isTrue);

      controller.settingsChanged(
        const AppSettings(appLockEnabled: true, appLockGraceSeconds: 0),
      );
      controller.activityPaused(false);
      await tester.pump();
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
      controller.lifecycleChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(controller.state.locked, isTrue);
      expect(field.focusNode.hasFocus, isFalse, reason: '锁着时键盘打不进去');
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.success);
      await controller.unlock();
      await tester.pump();
      await tester.pump();
      expect(field.focusNode.hasFocus, isTrue);
    });

    testWidgets('没开：没有盖子', (tester) async {
      await pumpGate(tester, const AppSettings());
      expect(find.byKey(const ValueKey('app-lock-cover')), findsNothing);
      await tester.tap(find.text('主机列表'));
      expect(tapped, isTrue);
    });

    testWidgets('只是离开时的遮罩：没有解锁按钮', (tester) async {
      final container = await pumpGate(
        tester,
        const AppSettings(appLockEnabled: true),
      );
      final controller = container.read(appLockControllerProvider.notifier);
      await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
      await tester.pump();
      await tester.pump();
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.success);
      await controller.unlock();
      await tester.pump();
      controller.activityPaused(false);
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
      expect(find.byKey(const ValueKey('app-lock-unlock')), findsNothing);
    });
  });

  group('设置页', () {
    late FakeAuth auth;
    late _MemoryRepository repository;

    Future<void> pumpPage(WidgetTester tester, AppSettings settings) async {
      auth = FakeAuth();
      repository = _MemoryRepository(settings);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          deviceAuthProvider.overrideWithValue(auth),
          vaultRepositoryProvider.overrideWithValue(repository),
        ],
        // 选项行弹的是 Prism 菜单，要 Prism 的文案；App 里由 ShunUiHost 提供。
        child: const MaterialApp(
          localizationsDelegates: [ShunPrismLocalizationsDelegate()],
          home: AppLockSettingsScreen(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    // 点整行就是拨开关（R86 起是公共开关行）。按 key 找行，不按开关的控件类型找。
    Finder switchOf(String key) => find.byKey(ValueKey(key));

    testWidgets('打开要先过验证，过了才存，子选项才出现', (tester) async {
      await pumpPage(tester, const AppSettings());
      expect(find.text('离开多久后锁'), findsNothing);
      await tester.tap(switchOf('app-lock-enabled'));
      await tester.pumpAndSettle();
      expect(auth.titles, ['打开应用锁']);
      expect(repository.stored.appLockEnabled, isTrue);
      expect(find.text('离开多久后锁'), findsOneWidget);
    });

    testWidgets('打开时取消验证：不存', (tester) async {
      await pumpPage(tester, const AppSettings());
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
      await tester.tap(switchOf('app-lock-enabled'));
      await tester.pumpAndSettle();
      expect(repository.stored.appLockEnabled, isFalse);
    });

    testWidgets('手机没屏幕锁：不让开，说清楚', (tester) async {
      await pumpPage(tester, const AppSettings());
      auth.secure = false;
      await tester.tap(switchOf('app-lock-enabled'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('手机没设屏幕锁'), findsOneWidget);
      expect(auth.calls, 0);
      expect(repository.stored.appLockEnabled, isFalse);
    });

    testWidgets('关掉也要过验证：取消就还开着', (tester) async {
      await pumpPage(tester, const AppSettings(appLockEnabled: true));
      auth.next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
      await tester.tap(switchOf('app-lock-enabled'));
      await tester.pumpAndSettle();
      expect(auth.titles, ['关闭应用锁']);
      expect(repository.stored.appLockEnabled, isTrue);

      auth.next = const DeviceAuthOutcome(DeviceAuthResult.success);
      await tester.tap(switchOf('app-lock-enabled'));
      await tester.pumpAndSettle();
      expect(repository.stored.appLockEnabled, isFalse);
    });

    testWidgets('子选项改了就存，不要验证', (tester) async {
      await pumpPage(tester, const AppSettings(appLockEnabled: true));
      await tester.tap(switchOf('app-lock-skip-connected'));
      await tester.pumpAndSettle();
      await tester.tap(switchOf('app-lock-pin-only'));
      await tester.pumpAndSettle();
      await tester.tap(switchOf('app-lock-weak'));
      await tester.pumpAndSettle();
      expect(repository.stored.appLockSkipWhileConnected, isTrue);
      expect(repository.stored.appLockPinOnly, isTrue);
      expect(repository.stored.appLockAllowWeakBiometrics, isTrue);
      expect(auth.calls, 0);

      await tester.tap(find.byKey(const ValueKey('app-lock-grace')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 分钟').last);
      await tester.pumpAndSettle();
      expect(repository.stored.appLockGraceSeconds, 300);
    });
  });

  test('设置存取：默认关、宽限 1 分钟，存了读得回来', () {
    const defaults = AppSettings();
    expect(defaults.appLockEnabled, isFalse);
    expect(defaults.appLockGraceSeconds, 60);
    final back = AppSettings.fromJson(const AppSettings(
      appLockEnabled: true,
      appLockGraceSeconds: 300,
      appLockSkipWhileConnected: true,
      appLockPinOnly: true,
      appLockAllowWeakBiometrics: true,
    ).toJson());
    expect(back.appLockEnabled, isTrue);
    expect(back.appLockGraceSeconds, 300);
    expect(back.appLockSkipWhileConnected, isTrue);
    expect(back.appLockPinOnly, isTrue);
    expect(back.appLockAllowWeakBiometrics, isTrue);
    // 旧版本存的设置没有这几项：默认关。
    expect(AppSettings.fromJson(const {}).appLockEnabled, isFalse);
  });

  testWidgets('整个 App：开了锁的人冷启动第一帧就是盖着的，返回键不弹底下的页', (tester) async {
    SharedPreferences.setMockInitialValues({
      'shun_settings_v1': '{"appLockEnabled":true}',
    });
    PackageInfo.setMockInitialValues(
      appName: 'shun',
      packageName: 'top.xdwa.shun',
      version: '1.4.7',
      buildNumber: '26',
      buildSignature: '',
    );
    const secureStorage =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null));
    final auth = FakeAuth()
      ..next = const DeviceAuthOutcome(DeviceAuthResult.canceled);
    final repository = await VaultRepository.open();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        deviceAuthProvider.overrideWithValue(auth),
      ],
      child: const ShunApp(),
    ));
    // 没有等任何异步：第一帧就要盖住。
    expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(auth.calls, 1);
    expect(find.byKey(const ValueKey('app-lock-unlock')), findsOneWidget);

    final popped = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        popped.add(call.method);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(popped, contains('SystemNavigator.pop'));
    expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
  });

  test('宽限标签：不认识的秒数显示默认', () {
    expect(appLockGraceLabel(300), '5 分钟');
    expect(appLockGraceLabel(7), '1 分钟');
  });
}

var tapped = false;

class _ThrowingAuth extends FakeAuth {
  @override
  Future<DeviceAuthOutcome> authenticate({
    required String title,
    String? description,
    required bool pinOnly,
    required bool allowWeak,
  }) async {
    throw PlatformException(code: 'busy', message: 'busy');
  }
}

class _MissingAuth extends FakeAuth {
  @override
  Future<DeviceAuthOutcome> authenticate({
    required String title,
    String? description,
    required bool pinOnly,
    required bool allowWeak,
  }) async {
    throw MissingPluginException('no channel');
  }
}

class _MemoryRepository implements VaultRepository {
  _MemoryRepository(this.stored);
  AppSettings stored;

  @override
  AppSettings loadSettingsPreview() => stored;

  @override
  Future<AppSettings> loadSettings() async => stored;

  @override
  Future<void> saveSettings(AppSettings settings) async => stored = settings;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
