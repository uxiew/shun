import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/connection_diagnosis.dart';
import 'package:shun/application/connection_events.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/connection_probe_sheet.dart';

// R25：「测试连接」也进连接记录。只记保存过的主机；关掉弹层算取消。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HostProfile host(String id) => HostProfile({
        'id': id,
        'label': id,
        'hostname': '$id.example',
        'port': 22,
        'username': 'ops',
        'password': 'pw',
        'authMethod': 'password',
        'protocol': 'ssh',
      });

  late ProviderContainer container;

  Future<void> open(
    WidgetTester tester,
    HostProfile target,
    _ScriptedProbe probe,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sshServiceProvider.overrideWithValue(probe),
      connectionEventStoreProvider
          .overrideWithValue(MemoryConnectionEventStore()),
    ]);
    addTearDown(container.dispose);
    final vault = container.read(vaultControllerProvider.notifier);
    await vault.ready();
    await vault.upsertHost(host('saved'));
    await container.read(connectionEventLogProvider.notifier).ready;
    final plan =
        resolveRoutePlan(target, hosts: const [], proxyProfiles: const []);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: ConnectionProbeSheet(
            host: target,
            plan: plan,
            verifyHostKey: (_, __, ___) async => true,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  List<ConnectionEvent> events() => container.read(connectionEventLogProvider);

  testWidgets('保存过的主机：失败记一条「测试连接 · 失败」，阶段和分类都在', (tester) async {
    final probe = _ScriptedProbe(fail: SSHAuthFailError('nope'));
    await open(tester, host('saved'), probe);
    probe.finish();
    await tester.pumpAndSettle();
    final event = events().single;
    expect(event.kind, ConnectionEventKind.probe);
    expect(event.hostId, 'saved');
    expect(event.outcome, ConnectionOutcome.failed);
    expect(event.failure, ConnectionFailureKind.authFailed);
    expect(event.failureHop, 0);
    expect(event.stages.map((s) => s.step),
        [ConnectionStep.dial, ConnectionStep.handshake]);
  });

  testWidgets('关掉弹层：这次记成取消', (tester) async {
    final probe = _ScriptedProbe();
    await open(tester, host('saved'), probe);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(events().single.outcome, ConnectionOutcome.cancelled);
  });

  testWidgets('还没保存的新主机不记：没有哪一页看得到它', (tester) async {
    final probe = _ScriptedProbe();
    await open(tester, host('draft'), probe);
    probe.finish();
    await tester.pumpAndSettle();
    expect(events(), isEmpty);
  });
}

/// 不联网的测试连接：报两个阶段后等 [finish]，再按 [fail] 失败或成功。
class _ScriptedProbe extends SshService {
  _ScriptedProbe({this.fail});

  final Object? fail;
  final _done = Completer<void>();

  void finish() => _done.complete();

  @override
  Future<ProbeOutcome> probe({
    required HostProfile host,
    List<HostProfile> hosts = const [],
    List<SshKeyProfile> keys = const [],
    List<ProxyProfile> proxyProfiles = const [],
    RoutePlan? routePlan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required ConnectionAttempt attempt,
  }) async {
    attempt.report(ConnectionStage(ConnectionStep.dial, label: host.label));
    attempt
        .report(ConnectionStage(ConnectionStep.handshake, label: host.label));
    await attempt.waitFor(_done.future);
    if (fail case final error?) {
      throw RouteHopException(0, 'x', error);
    }
    return const ProbeOutcome(tty: '/dev/pts/1');
  }
}
