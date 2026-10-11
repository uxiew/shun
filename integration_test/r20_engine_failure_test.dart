// R20 设备验证（TER12、GST05）：安装包里的 Ghostty 原生库没了，App 照实说引擎起不来，不拿别的引擎凑合。
//
// 这不是 CI 测试，也不能用 flutter test 直接跑：要先编出这个测试的 APK、从里面删掉 libghostty.so、重新签名，
// 再用 flutter drive 装这个包跑。全部步骤在 tool/r20-engine-failure.sh，测试环境要开着（连接那一步要一台真 sshd）。
// 输出以 "R20 " 开头的行作为证据。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/connection_diagnosis.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/terminal_engine.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';

const _ssh = String.fromEnvironment('R17_SSH');

void r20(String key, Object? value) => debugPrint('R20 $key=$value');

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 截图：打出 "R20 SHOT=<名字>" 后停 2.5 秒，让电脑那边用 adb screencap 截下来。
Future<void> shot(WidgetTester tester, String name) async {
  debugPrint('R20 SHOT=$name');
  await settle(tester, 2500);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('原生库不在：App 照常启动；设置页写出原话；连接如实失败、不拨号、不换引擎', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester);
    r20('fail.appStarted', true);

    // 设置 → 外观与终端 → 终端引擎：还没开过终端；点「检查」才真去建一个。
    container.read(homeTabProvider.notifier).state = 4;
    await settle(tester);
    final tile = find.byKey(const ValueKey('terminal-engine-status'));
    await tester.scrollUntilVisible(tile, 300,
        scrollable: find.byType(Scrollable).first);
    await settle(tester);
    r20('fail.beforeCheck',
        container.read(terminalEngineStatusProvider).effective ?? 'null');
    await tester.tap(find.byKey(const ValueKey('terminal-engine-check')));
    await settle(tester);
    final status = container.read(terminalEngineStatusProvider);
    final failureText = find.byKey(const ValueKey('terminal-engine-failure'));
    r20('fail.status',
        'requested=${status.requested} effective=${status.effective} started=${status.started}');
    r20('fail.reason', jsonEncode('${status.failure}'));
    r20('fail.tileShown', failureText.evaluate().isNotEmpty);
    await shot(tester, 'fail-settings');
    expect(status.effective, isNull, reason: '没有别的引擎顶上');
    expect(status.failure, isNotNull);
    expect(failureText, findsOneWidget);

    // 连一台真 sshd：引擎在拨号之前就建不起来，连接如实失败，卡片写清是引擎的事。
    if (_ssh.isNotEmpty) {
      final config = jsonDecode(_ssh) as Map<String, dynamic>;
      container.read(homeTabProvider.notifier).state = 1;
      await settle(tester);
      final controller = container.read(sessionControllerProvider.notifier);
      Object? error;
      try {
        await controller.connect(
          HostProfile({
            'id': 'r20-fail',
            'label': 'r20-fail',
            'hostname': '127.0.0.1',
            'port': config['port'],
            'username': config['user'],
            'password': config['password'],
            'authMethod': 'password',
            'protocol': 'ssh',
            '_ephemeralTerminal': true,
          }),
          (_, __, fingerprint) async => fingerprint == config['fingerprint'],
        );
      } catch (e) {
        error = e;
      }
      await settle(tester, 1000);
      final pending = controller.state.pendingConnections;
      r20('fail.connectError', jsonEncode('$error'));
      r20('fail.sessions', controller.state.sessions.length);
      r20('fail.pending',
          pending.map((p) => '${p.phase.name}: ${p.error}').join(' | '));
      r20('fail.hint', jsonEncode(error == null ? null : connectionHint(error)));
      await shot(tester, 'fail-connect');
      expect(error, isA<TerminalEngineUnavailableException>());
      expect(controller.state.sessions, isEmpty, reason: '没有用别的引擎开出标签');
      expect(pending.single.phase, PendingConnectionPhase.failed);
      expect(connectionHint(error!), contains('没有别的引擎可换'));
    }
  });
}
