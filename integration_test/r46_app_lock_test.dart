// R46 设备验证：真的系统 PIN 框、真的退后台，真 SSH。只用 tool/r46-app-lock.py 跑，它设锁屏 PIN、按测试打的 `R46 ACTION=<动作>`
// 去按 HOME、输 PIN、截图，跑完清掉。冷启动在脚本里另外测：flutter test 收尾会卸载 App，接不上这里的数据。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/app_lock.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/settings_screen.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';

const _raw = String.fromEnvironment('SHUN_FIXTURE');
final Map<String, dynamic> fixture =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

void report(String key, Object? value) => debugPrint('R46 $key=$value');
void action(String name) => debugPrint('R46 ACTION=$name');

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> until(WidgetTester tester, bool Function() condition,
    {required String what,
    Duration timeout = const Duration(seconds: 60)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('R46 应用锁', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester, 1500);

    AppLockState lock() => container.read(appLockControllerProvider);
    final settings = container.read(settingsControllerProvider.notifier);
    final sessions = container.read(sessionControllerProvider.notifier);
    final host = HostProfile({
      'id': 'r46',
      'label': 'R46-SENTINEL',
      'hostname': '127.0.0.1',
      'port': fixture['edgePort'],
      'username': fixture['user'],
      'password': fixture['password'],
      'authMethod': 'password',
      'protocol': 'ssh',
    });
    await container.read(vaultControllerProvider.notifier).upsertHost(host);
    await settle(tester);
    expect(lock().obscured, isFalse);

    // 从设置页打开：要过一次系统验证。
    container.read(homeTabProvider.notifier).state = 4;
    await settle(tester);
    final entry = find.byKey(const ValueKey('settings-app-lock'));
    await tester.scrollUntilVisible(entry, 240,
        scrollable: find
            .descendant(
                of: find.byType(SettingsScreen),
                matching: find.byType(Scrollable))
            .first);
    await settle(tester);
    await tester.tap(entry);
    await settle(tester);
    // R86：点整行就是拨开关，按 key 找行，不按开关控件类型找。
    await tester.tap(find.byKey(const ValueKey('app-lock-enabled')));
    action('pin');
    await until(
      tester,
      () => container.read(settingsControllerProvider).appLockEnabled,
      what: '打开应用锁',
    );
    report('enabled', true);
    await settle(tester);
    await tester.tap(find.byType(BackButton));
    await settle(tester);
    container.read(homeTabProvider.notifier).state = 0;
    await settle(tester);
    expect(find.text('R46-SENTINEL'), findsWidgets);

    // 立即锁：离开就盖上，回来弹验证；取消后留在锁屏。
    await settings.edit((s) => s.copyWith(appLockGraceSeconds: 0));
    action('home-recents-return');
    await until(tester, () => lock().covered, what: '离开时盖上');
    report('coveredOnLeave', true);
    await until(tester, () => lock().authenticating, what: '回来弹验证');
    report('promptOnReturn', true);
    action('cancel');
    await until(tester, () => !lock().authenticating, what: '取消验证');
    await settle(tester, 1500);
    expect(lock().locked, isTrue);
    expect(lock().authenticating, isFalse, reason: '取消后不能自己又弹');
    expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
    report('stayedLockedAfterCancel', true);
    action('shot-locked');
    await settle(tester, 2500);
    await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
    await until(tester, () => lock().authenticating, what: '点解锁');
    action('pin');
    await until(tester, () => !lock().obscured, what: '输 PIN 解锁');
    await settle(tester);
    expect(find.byKey(const ValueKey('app-lock-cover')), findsNothing);
    expect(find.text('R46-SENTINEL'), findsWidgets);
    report('unlocked', true);
    action('shot-unlocked');
    await settle(tester, 2500);

    // 宽限期内回来：不锁，不弹。
    await settings.edit((s) => s.copyWith(appLockGraceSeconds: 300));
    action('home-return');
    await until(tester, () => lock().covered, what: '离开时盖上');
    await until(tester, () => !lock().obscured, what: '宽限期内揭开');
    expect(lock().locked, isFalse);
    report('graceKeptUnlocked', true);
    await settle(tester);

    // 终端连着不锁：开着选项时回来不锁。
    expect(await sessions.connect(host, (_, __, ___) async => true), isTrue);
    await settle(tester);
    await settings.edit((s) => s.copyWith(
          appLockGraceSeconds: 0,
          appLockSkipWhileConnected: true,
        ));
    action('home-return');
    await until(tester, () => lock().covered, what: '离开时盖上');
    await until(tester, () => !lock().obscured, what: '连着时不锁');
    expect(lock().locked, isFalse);
    report('skipWhileConnected', true);
    await settle(tester);

    // 关掉选项：锁上，而且锁着时连接不断。
    await settings.edit((s) => s.copyWith(appLockSkipWhileConnected: false));
    action('home-return');
    await until(tester, () => lock().covered, what: '离开时盖上');
    await until(tester, () => lock().authenticating, what: '弹验证');
    final session = container.read(sessionControllerProvider).sessions.single;
    expect(session.connected, isTrue);
    report('connectionSurvivesLock', true);
    action('pin');
    await until(tester, () => !lock().obscured, what: '输 PIN 解锁');
    await settle(tester);
    expect(session.connected, isTrue);

    // 画中画那窗是用户要看的：立即锁也不盖。回到全屏也不锁。入口只在终端页，从别的页进窗口太小会布局溢出。
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester);
    final pipButton =
        find.byKey(const ValueKey('terminal-action-picture-in-picture'));
    // 这台存了密码，多了 sudo 键：窄屏上画中画挤进「…」（手册第 9 节）。
    if (pipButton.evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
      await settle(tester, 500);
    }
    await tester.tap(pipButton);
    await until(
      tester,
      () => container.read(terminalPictureInPictureProvider),
      what: '进画中画',
    );
    await settle(tester, 2500);
    expect(lock().obscured, isFalse);
    report('pipNotCovered', true);
    action('shot-pip');
    await settle(tester, 2500);
    expect(lock().obscured, isFalse);
    action('open-app');
    await until(
      tester,
      () => tester.binding.lifecycleState == AppLifecycleState.resumed,
      what: '回到全屏',
    );
    await settle(tester, 1500);
    expect(lock().obscured, isFalse);
    expect(lock().authenticating, isFalse);
    report('pipReturnNotLocked', true);
    await sessions.close(0);
    await settle(tester);

    // 直接用 PIN。
    await settings.edit((s) => s.copyWith(appLockPinOnly: true));
    action('home-return');
    await until(tester, () => lock().authenticating, what: '弹 PIN');
    action('pin');
    await until(tester, () => !lock().obscured, what: '输 PIN 解锁');
    report('pinOnly', true);
    await settings.edit((s) => s.copyWith(appLockPinOnly: false));
    await settle(tester);

    // 关掉要过验证。设成立即时，PIN 页顶到后台再回来不能再锁一次（真 bug，单测的假验证测不出来）。
    container.read(homeTabProvider.notifier).state = 4;
    await settle(tester);
    await tester.scrollUntilVisible(entry, 240,
        scrollable: find
            .descendant(
                of: find.byType(SettingsScreen),
                matching: find.byType(Scrollable))
            .first);
    await settle(tester);
    await tester.tap(entry);
    await settle(tester);
    // R86：点整行就是拨开关，按 key 找行，不按开关控件类型找。
    await tester.tap(find.byKey(const ValueKey('app-lock-enabled')));
    action('pin');
    await until(
      tester,
      () => !container.read(settingsControllerProvider).appLockEnabled,
      what: '关掉应用锁',
    );
    await settle(tester, 4000);
    expect(lock().obscured, isFalse);
    expect(lock().authenticating, isFalse);
    report('turnedOffWithoutSecondPrompt', true);
  }, skip: fixture.isEmpty, timeout: const Timeout(Duration(minutes: 8)));
}
