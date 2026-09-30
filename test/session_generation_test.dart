import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

// R08：连接代次（generation）与取消。用假的 SshService 精确控制「结果什么时候到」，
// 真实 OpenSSH 上的同类场景在 integration_ssh_fixture_test.dart 的 R08 组。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });

  late _ScriptedSshService service;
  late ProviderContainer container;
  late SessionController controller;

  Future<void> start({_GatedVaultController? vault}) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    service = _ScriptedSshService();
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sshServiceProvider.overrideWithValue(service),
      if (vault != null)
        vaultControllerProvider
            .overrideWith((ref) => vault..attach(repository)),
    ]);
    controller = container.read(sessionControllerProvider.notifier);
    await container.read(vaultControllerProvider.notifier).ready();
  }

  /// 让排队的 microtask 和一轮事件循环跑完。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  final host = HostProfile.create(
    id: 'h1',
    label: 'web',
    hostname: 'web.example.com',
    username: 'root',
  );
  Future<bool> accept(HostProfile _, String __, String ___) async => true;

  group('NET09 代次隔离：迟到的结果不能复活旧连接', () {
    setUp(() => start());
    tearDown(() => container.dispose());

    test('连接→取消→再连：旧尝试迟到的成功被关掉，不进标签；新连接正常', () async {
      final first = controller.connect(host, accept);
      await settle();
      final oldPending = controller.state.pendingConnections.single;
      final oldCall = service.calls.single;

      controller.cancelPendingConnection(oldPending.id);
      expect(oldCall.attempt.isCancelled, isTrue,
          reason: '取消必须让交给 SshService 的那次尝试失效，它才会关掉已建好的 socket');
      expect(controller.state.pendingConnections, isEmpty);

      final second = controller.connect(host, accept);
      await settle();
      final newCall = service.calls.last;
      expect(
          newCall.attempt.generation, greaterThan(oldCall.attempt.generation));

      // 旧尝试的阶段事件和成功结果都迟到了。
      oldCall.attempt.report(const ConnectionStage(ConnectionStep.shell));
      final late = _FakeSession(oldCall.sessionId, host);
      oldCall.result.complete(late);
      expect(await first, isFalse, reason: '被取消的连接不能向界面报「已连接」');
      expect(late.closedByUser, isTrue, reason: '迟到的成功必须被关掉');
      expect(controller.state.sessions, isEmpty);
      expect(controller.state.pendingConnections.single.stage, isNull,
          reason: '旧尝试的阶段事件不能写到新尝试的等待界面上');

      final fresh = _FakeSession(newCall.sessionId, host);
      newCall.result.complete(fresh);
      expect(await second, isTrue);
      expect(controller.state.sessions, [same(fresh)]);
      expect(fresh.closedByUser, isFalse);
      expect(controller.state.pendingConnections, isEmpty);
    });

    test('旧尝试迟到的失败不会把新尝试标成失败，也不写全局错误', () async {
      final first = controller.connect(host, accept);
      await settle();
      final oldCall = service.calls.single;
      controller.cancelPendingConnection(
          controller.state.pendingConnections.single.id);
      unawaited(controller.connect(host, accept));
      await settle();

      oldCall.result.completeError(StateError('旧连接的网络错误'));
      await first; // 取消的尝试不向调用方抛错
      final pending = controller.state.pendingConnections.single;
      expect(pending.phase, PendingConnectionPhase.connecting);
      expect(controller.state.error, isNull);
    });

    test('等保险库解锁时就取消：一次拨号都不发起', () async {
      container.dispose();
      final vault = _GatedVaultController();
      await start(vault: vault);
      vault.gate = Completer<VaultData>();

      final connecting = controller.connect(host, accept);
      await settle();
      controller.cancelPendingConnection(
          controller.state.pendingConnections.single.id);
      vault.gate!.complete(VaultData.empty());
      expect(await connecting, isFalse);
      expect(service.calls, isEmpty, reason: '取消后不能先连上再关');
      expect(controller.state.pendingConnections, isEmpty);
    });

    test('阶段按顺序显示；取消之后不再更新', () async {
      unawaited(controller.connect(host, accept));
      await settle();
      final call = service.calls.single;
      final id = controller.state.pendingConnections.single.id;

      call.attempt.report(const ConnectionStage(ConnectionStep.dial,
          label: 'web', detail: 'web.example.com:22'));
      expect(controller.state.pendingConnections.single.stage!.step,
          ConnectionStep.dial);
      call.attempt.report(
          const ConnectionStage(ConnectionStep.handshake, label: 'web'));
      expect(controller.state.pendingConnections.single.stage!.step,
          ConnectionStep.handshake);

      controller.cancelPendingConnection(id);
      call.attempt.report(const ConnectionStage(ConnectionStep.shell));
      expect(call.attempt.stage!.step, ConnectionStep.handshake,
          reason: '取消后的上报被丢弃');
      call.result.completeError(const ConnectionCancelledException());
    });
  });

  group('恢复连接的代次', () {
    setUp(() => start());
    tearDown(() => container.dispose());

    Future<_FakeSession> connected() async {
      final connecting = controller.connect(host, accept);
      await settle();
      final call = service.calls.last;
      final session = _FakeSession(call.sessionId, host);
      call.result.complete(session);
      await connecting;
      return session;
    }

    test('恢复进行中关掉标签：恢复出来的新连接被关掉，不会顶替进已关的标签', () async {
      final old = await connected();
      old.drop();
      await settle();
      expect(old.connected, isFalse);
      expect(old.aborted, isTrue, reason: '断线时这一代的网络资源立刻释放');

      final restoring = controller.reconnectDisconnected();
      await settle();
      final restoreCall = service.calls.last;
      expect(restoreCall.purpose, ConnectionPurpose.restore);

      await controller.close(0);
      expect(restoreCall.attempt.isCancelled, isTrue);
      final late = _FakeSession(old.id, host);
      restoreCall.result.complete(late);
      await restoring;
      expect(late.closedByUser, isTrue);
      expect(controller.state.sessions, isEmpty);
    });

    test('恢复成功：旧连接断开输出并释放；新连接顶替同一个标签', () async {
      final old = await connected();
      old.drop();
      await settle();
      final restoring = controller.reconnectDisconnected();
      await settle();
      final call = service.calls.last;
      final replacement = _FakeSession(old.id, host);
      call.result.complete(replacement);
      await restoring;
      expect(controller.state.sessions, [same(replacement)]);
      expect(old.outputDetached, isTrue,
          reason: '新旧连接共用 terminal，旧通道迟到的字节不能写进新画面');
    });

    test('恢复沿用标签原来冻结的路线，不按保险库里改过的配置重算', () async {
      final plan = resolveRoutePlan(host,
          hosts: [host], proxyProfiles: const [], keys: const []);
      final connecting = controller.connect(host, accept);
      await settle();
      final call = service.calls.last;
      final old = _FakeSession(call.sessionId, host, routePlan: plan);
      call.result.complete(old);
      await connecting;

      old.drop();
      await settle();
      unawaited(controller.reconnectDisconnected());
      await settle();
      expect(service.calls.last.routePlan, same(plan));
      service.calls.last.result
          .completeError(const ConnectionCancelledException());
    });

    test('已被替换的旧连接迟到的断线事件，不会把新连接标成断开', () async {
      final old = await connected();
      old.failPing = true;
      controller.setBackgrounded(true); // 切后台立刻做一轮保活：ping 失败 → 标断开 → 恢复
      await settle();
      final call = service.calls.last;
      expect(call.purpose, ConnectionPurpose.restore);
      final replacement = _FakeSession(old.id, host);
      call.result.complete(replacement);
      await settle();
      await settle();
      expect(controller.state.sessions, [same(replacement)]);

      old.drop(); // 旧连接的 done 这时才到
      await settle();
      expect(replacement.connected, isTrue);
      expect(controller.state.sessions, [same(replacement)]);
      controller.setBackgrounded(false);
    });
  });

  group('关闭与释放', () {
    setUp(() => start());

    test('关标签时另一个连接恰好连上：新连接不会被旧快照抹掉', () async {
      final first = controller.connect(host, accept);
      await settle();
      final a = _FakeSession(service.calls.last.sessionId, host);
      service.calls.last.result.complete(a);
      await first;

      final second = controller.connect(host, accept);
      await settle();
      final b = _FakeSession(service.calls.last.sessionId, host);
      final closing = controller.close(0);
      service.calls.last.result.complete(b);
      await closing;
      await second;
      expect(controller.state.sessions, [same(b)]);
      expect(a.closedByUser, isTrue);
      container.dispose();
    });

    test('controller 销毁：进行中的尝试失效，已建立的连接全部关闭，迟到结果也被关', () async {
      final first = controller.connect(host, accept);
      await settle();
      final a = _FakeSession(service.calls.last.sessionId, host);
      service.calls.last.result.complete(a);
      await first;
      final pending = controller.connect(host, accept);
      await settle();
      final call = service.calls.last;

      container.dispose();
      expect(call.attempt.isCancelled, isTrue);
      expect(a.closedByUser, isTrue);
      final late = _FakeSession(call.sessionId, host);
      call.result.complete(late);
      await pending;
      expect(late.closedByUser, isTrue);
    });
  });
}

class _Call {
  _Call(this.sessionId, this.attempt, this.purpose, this.routePlan);
  final String sessionId;
  final ConnectionAttempt attempt;
  final ConnectionPurpose purpose;
  final RoutePlan? routePlan;
  final result = Completer<ActiveTerminalSession>();
}

/// 每次 connect 都挂起，由测试决定结果什么时候、以什么形式到达。
class _ScriptedSshService extends SshService {
  final calls = <_Call>[];

  @override
  Future<ActiveTerminalSession> connect({
    required String sessionId,
    required HostProfile host,
    List<HostProfile> hosts = const [],
    List<SshKeyProfile> keys = const [],
    List<ProxyProfile> proxyProfiles = const [],
    RoutePlan? routePlan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    Terminal? terminal,
    ConnectionPurpose purpose = ConnectionPurpose.fresh,
    ConnectionAttempt? attempt,
  }) {
    final call = _Call(sessionId, attempt!, purpose, routePlan);
    calls.add(call);
    return call.result.future;
  }
}

class _FakeSession extends ActiveTerminalSession {
  _FakeSession(String id, HostProfile host, {super.routePlan})
      : super(
          id: id,
          host: host,
          terminal: Terminal(),
          verifyHostKey: (_, __, ___) async => true,
          keyboardInteractive: null,
        );

  final _done = Completer<void>();
  bool aborted = false;
  bool outputDetached = false;
  bool failPing = false;

  void drop() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> ping({Duration timeout = const Duration(seconds: 8)}) async {
    if (failPing) throw const SocketException('ping failed');
  }

  @override
  void abort() {
    aborted = true;
    super.abort();
  }

  /// 真实关闭要等网络（旧代码 await 了 telnet 的 close）。这里也让出一次事件循环，
  /// 「先 await 关闭、再写回之前拍的标签快照」那种竞态才会暴露。
  @override
  Future<void> close() async {
    await super.close();
    await Future<void>.delayed(Duration.zero);
  }

  @override
  void detachOutput() {
    outputDetached = true;
    super.detachOutput();
  }
}

class _GatedVaultController extends VaultController {
  _GatedVaultController() : super(_NullRepository());

  Completer<VaultData>? gate;
  VaultRepository? _real;

  void attach(VaultRepository repository) => _real = repository;

  @override
  Future<VaultData> ready() async {
    final pending = gate;
    if (pending != null) return pending.future;
    return _real!.loadVault();
  }
}

class _NullRepository implements VaultRepository {
  @override
  VaultData? loadVaultPreview() => null;

  @override
  Future<VaultData> loadVault() async => VaultData.empty();

  @override
  Set<String> get unreadableSecrets => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
