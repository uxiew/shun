import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/connection_lifecycle.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/tmux/tmux_target.dart';
import 'package:netcatty_mobile/infrastructure/ssh/connection_platform_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_login_watch.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/transport/proxy_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

// R22：连接生命周期。假的 SshService 和假的平台（保活服务、锁屏、网络），时钟由测试拨。
// 真实 OpenSSH、模拟器上的同类场景见 evidence/R22.md。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });

  late _Service service;
  late _Platform platform;
  late ProviderContainer container;
  late SessionController controller;
  late DateTime clock;

  Future<void> settle([int turns = 3]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> start({
    Map<String, Object> preferences = const {},
    List<HostProfile> hosts = const [],
    Duration leaseAfter = credentialLease,
  }) async {
    SharedPreferences.setMockInitialValues(preferences);
    final repository = await VaultRepository.open();
    service = _Service();
    platform = _Platform();
    clock = DateTime(2026, 10, 8, 12);
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sshServiceProvider.overrideWithValue(service),
      sessionControllerProvider.overrideWith(
        (ref) => SessionController(
          ref.watch(sshServiceProvider),
          ref.watch(vaultControllerProvider.notifier),
          ref,
          platform: platform,
          now: () => clock,
          leaseAfter: leaseAfter,
        ),
      ),
    ]);
    final vault = container.read(vaultControllerProvider.notifier);
    await vault.ready();
    for (final host in hosts) {
      await vault.upsertHost(host);
    }
    controller = container.read(sessionControllerProvider.notifier);
    await settle();
  }

  HostProfile hostWith(
          {String password = 'pw-1', String hostname = 'web.example.com'}) =>
      HostProfile.create(
        id: 'h1',
        label: 'web',
        hostname: hostname,
        username: 'root',
      )..data['password'] = password;

  Future<bool> accept(HostProfile _, String __, String ___) async => true;

  /// 连上一个标签：路线照主机现算（带密码），会话是假的。
  Future<_Session> connected(HostProfile host) async {
    final connecting = controller.connect(host, accept);
    await settle();
    final call = service.calls.last;
    final session = _Session(call.sessionId, host,
        routePlan: call.routePlan ??
            resolveRoutePlan(host,
                hosts: [host], proxyProfiles: const [], keys: const []));
    call.result.complete(session);
    expect(await connecting, isTrue);
    await settle(); // 保活请求是排队异步发的
    return session;
  }

  ActiveTerminalSession tab(String id) =>
      controller.state.sessions.singleWhere((value) => value.id == id);

  group('断线后的自动恢复（docs/07：同一路线的网络错误、2 分钟窗口）', () {
    tearDown(() => container.dispose());

    test('网络错误按退避重试；窗口过了停下，等回前台或用户', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final old = await connected(host);
      old.drop();
      await settle();
      // 断线当场就试第一次（恢复用 restore，不跑启动命令）。
      expect(service.calls.last.purpose, ConnectionPurpose.restore);
      expect(controller.state.recovering, {old.id});
      service.calls.last.result.completeError(const SocketException('down'));
      await settle();
      expect(tab(old.id).restoreHold, isNull, reason: '网络错误还在窗口里，接着试');

      final calls = service.calls.length;
      await controller.runRecoveryPass();
      expect(service.calls.length, calls, reason: '退避时间没到不试');
      clock = clock.add(const Duration(seconds: 2));
      // 这一轮会等那次（挂着的）连接出结果，不 await。
      unawaited(controller.runRecoveryPass());
      await settle();
      expect(service.calls.length, calls + 1);
      service.calls.last.result.completeError(const SocketException('down'));
      await settle();

      clock = clock.add(recoveryWindow + const Duration(seconds: 1));
      await controller.runRecoveryPass();
      expect(service.calls.length, calls + 1, reason: '窗口过了不再试');
      final hold = tab(old.id).restoreHold!;
      expect(hold.kind, RestoreHoldKind.untilForeground);
      expect(hold.message, contains('2 分钟内没恢复上'));
      expect(controller.state.recovering, isEmpty);

      // 回到前台再给一轮。
      controller.setBackgrounded(true);
      controller.setBackgrounded(false);
      await settle();
      expect(service.calls.length, calls + 2);
      expect(tab(old.id).restoreHold, isNull);
      service.calls.last.result.complete(_Session(old.id, host));
      await settle();
      expect(tab(old.id).connected, isTrue);
      expect(controller.state.recovering, isEmpty);
    });

    test('密码错、指纹被拒、路线配置错：一次都不重试，写明原因等用户', () async {
      final host = hostWith();
      await start(hosts: [host]);
      for (final error in <Object>[
        SSHAuthFailError('denied'),
        SSHAuthAbortError('hostkey', SSHHostkeyError('rejected')),
        const RouteConfigException('配置不对'),
        const ProxyHandshakeException('SOCKS5 代理认证失败：用户名或密码不对'),
      ]) {
        final old = await connected(host);
        old.drop();
        await settle();
        final calls = service.calls.length;
        service.calls.last.result.completeError(error);
        await settle();
        final hold = tab(old.id).restoreHold;
        expect(hold?.kind, RestoreHoldKind.untilUser, reason: '$error');
        clock = clock.add(const Duration(minutes: 1));
        await controller.runRecoveryPass();
        expect(service.calls.length, calls, reason: '$error 不该再试');
        await controller.close(0);
      }
    });

    test('后台且手机锁着：不重新登录，等解锁回到 App；回来后自动恢复', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final old = await connected(host);
      controller.setBackgrounded(true);
      platform.locked = true;
      final calls = service.calls.length;
      old.drop();
      await settle();
      expect(service.calls.length, calls, reason: '锁着屏不在后台登录（SEC07）');
      final hold = tab(old.id).restoreHold!;
      expect(hold.kind, RestoreHoldKind.untilForeground);
      expect(hold.message, contains('手机锁着'));
      expect(platform.requests.last, isNull, reason: '没有连着、在恢复的会话了，保活服务不该还开着');

      platform.locked = false;
      controller.setBackgrounded(false);
      await settle();
      expect(service.calls.length, calls + 1);
      expect(service.calls.last.purpose, ConnectionPurpose.restore);
    });

    test('后台、手机没锁：照常在后台恢复', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final old = await connected(host);
      controller.setBackgrounded(true);
      final calls = service.calls.length;
      old.drop();
      await settle();
      expect(service.calls.length, calls + 1);
      controller.setBackgrounded(false);
    });
  });

  group('网络变化（LIFE03）', () {
    tearDown(() => container.dispose());

    test('换网后逐条探活：活着的不动，死了的走恢复', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final alive = await connected(host);
      final dead = await connected(host);
      dead.failPing = true;
      final calls = service.calls.length;
      platform.emit(const NetworkChanged(NetworkStatus(
          available: true, id: 'cell-2', transports: {'cellular'})));
      await settle(6);
      expect(alive.connected, isTrue, reason: '不因网络通知无条件断开');
      expect(alive.aborted, isFalse);
      expect(dead.connected, isFalse);
      expect(dead.pingTimeouts.single, networkProbeTimeout);
      expect(service.calls.length, calls + 1);
      expect(service.calls.last.sessionId, dead.id);
    });

    test('同一张网只是能力变了：不探', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final session = await connected(host);
      platform.emit(const NetworkChanged(NetworkStatus(
          available: true,
          id: 'wifi-1',
          transports: {'wifi'},
          validated: false)));
      await settle();
      expect(session.pingTimeouts, isEmpty);
    });

    test('没网时不白试；网络回来马上试，窗口重新起算', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final old = await connected(host);
      platform.emit(const NetworkChanged(NetworkStatus(available: false)));
      await settle();
      expect(controller.state.networkAvailable, isFalse);
      final calls = service.calls.length;
      old.drop();
      await settle();
      expect(service.calls.length, calls, reason: '没网不试');
      clock = clock.add(const Duration(minutes: 5));
      await controller.runRecoveryPass();
      expect(service.calls.length, calls);
      expect(tab(old.id).restoreHold, isNull, reason: '没网的那段不算进窗口');

      platform.emit(const NetworkChanged(
          NetworkStatus(available: true, id: 'wifi-1', transports: {'wifi'})));
      await settle();
      expect(service.calls.length, calls + 1);
    });
  });

  group('通知「全部断开」与系统停服务（LIFE02、LIFE05）', () {
    tearDown(() => container.dispose());

    test('当前这一代的「全部断开」：先让恢复失效，再断开全部；不复活', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final a = await connected(host);
      final b = await connected(host);
      b.drop();
      await settle();
      final restoring = service.calls.last;
      final generation = platform.requests.last!.generation;

      platform.emit(KeepAliveStopRequested(generation));
      await settle();
      expect(restoring.attempt.isCancelled, isTrue, reason: '进行中的恢复先失效');
      expect(a.aborted, isTrue);
      expect(controller.state.sessions, hasLength(2), reason: '标签留着写明原因');
      for (final session in controller.state.sessions) {
        expect(session.connected, isFalse);
        expect(session.restoreHold?.kind, RestoreHoldKind.untilUser);
      }
      expect(platform.requests.last, isNull, reason: '保活服务停了');

      // 恢复迟到的成功不能把标签顶回来。
      final late = _Session(b.id, host);
      restoring.result.complete(late);
      await settle();
      expect(late.closedByUser, isTrue);
      final calls = service.calls.length;
      platform.emit(const NetworkChanged(NetworkStatus(
          available: true, id: 'cell-9', transports: {'cellular'})));
      clock = clock.add(const Duration(seconds: 30));
      await controller.runRecoveryPass();
      expect(service.calls.length, calls, reason: '网络事件也不能让它复活');
    });

    test('上一代服务迟到的「全部断开」和「被停」：不理', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final session = await connected(host);
      final generation = platform.requests.last!.generation;
      platform.emit(KeepAliveStopRequested(generation - 1));
      platform.emit(KeepAliveStopped(generation + 5, 'system'));
      await settle();
      expect(session.connected, isTrue);
      expect(session.aborted, isFalse);
    });

    test('后台时服务被系统停了：全部断开、不在后台重开服务', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final session = await connected(host);
      controller.setBackgrounded(true);
      final generation = platform.requests.last!.generation;
      final requests = platform.requests.length;
      platform.emit(KeepAliveStopped(generation, 'system'));
      await settle();
      expect(session.connected, isFalse);
      expect(tab(session.id).restoreHold?.kind, RestoreHoldKind.untilUser);
      expect(platform.requests.skip(requests).whereType<KeepAliveRequest>(),
          isEmpty,
          reason: '后台不把服务再开起来');
      controller.setBackgrounded(false);
      await settle();
      expect(tab(session.id).connected, isFalse,
          reason: '回到前台也不自动连：要用户点「重新连接」');
    });

    test('前台时服务被停：会话不动，服务按新一代重开', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final session = await connected(host);
      final generation = platform.requests.last!.generation;
      platform.emit(KeepAliveStopped(generation, 'system'));
      await settle();
      expect(session.connected, isTrue);
      expect(platform.requests.last!.generation, greaterThan(generation));
    });
  });

  group('保活服务开关和通知内容', () {
    tearDown(() => container.dispose());

    test('有连着、在恢复的才开；通知写各有几个；全停了就关', () async {
      final host = hostWith();
      await start(hosts: [host]);
      expect(platform.requests, isEmpty);
      final a = await connected(host);
      expect(platform.requests.last!.title, contains('1 个连着'));
      final b = await connected(host);
      expect(platform.requests.last!.title, contains('2 个连着'));
      final generation = platform.requests.last!.generation;
      b.drop();
      await settle();
      expect(platform.requests.last!.title, contains('1 个连着，1 个在恢复'));
      expect(platform.requests.last!.generation, generation,
          reason: '服务一直开着时只换内容，不换代');
      service.calls.last.result.completeError(SSHAuthFailError('denied'));
      await settle();
      expect(platform.requests.last!.title, isNot(contains('在恢复')));
      expect(platform.requests.last!.title, contains('1 个连着，1 个停了，要你处理'));
      await controller.close(
          controller.state.sessions.indexWhere((value) => value.id == a.id));
      await settle();
      expect(platform.requests.last, isNull, reason: '只剩一个停着等用户的标签：没有要保的东西');
    });

    test('锁屏时断掉、等回到 App 的标签也写进通知（LIFE07 真机上只写了「2 个连着」）', () async {
      final host = hostWith();
      await start(hosts: [host]);
      await connected(host);
      final b = await connected(host);
      await connected(host);
      controller.setBackgrounded(true);
      platform.locked = true;
      b.drop();
      await settle();
      expect(platform.requests.last!.title, 'xwshun 终端：2 个连着，1 个等回到 App 再恢复');
    });
  });

  group('凭据副本的租期（SEC07）', () {
    tearDown(() => container.dispose());

    test('后台满租期清掉冻结路线里的密码；恢复时按保险库补回，形状一样才用', () async {
      final host = hostWith(password: 'pw-1');
      await start(hosts: [host], leaseAfter: const Duration(milliseconds: 30));
      final old = await connected(host);
      expect(old.routePlan!.target.host.password, 'pw-1');
      controller.setBackgrounded(true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(old.routePlan!.secretsForgotten, isTrue);
      expect(old.routePlan!.target.host.password, isNull);

      // 期间只改了密码（身份没变）：按保险库现在的密码连。
      await container
          .read(vaultControllerProvider.notifier)
          .upsertHost(hostWith(password: 'pw-2'));
      controller.setBackgrounded(false);
      old.drop();
      await settle(6);
      final plan = service.calls.last.routePlan!;
      expect(plan.secretsForgotten, isFalse);
      expect(plan.target.host.password, 'pw-2');
    });

    test('断线期间地址改了：自动恢复不换路线，停下等用户', () async {
      final host = hostWith();
      await start(hosts: [host], leaseAfter: const Duration(milliseconds: 30));
      final old = await connected(host);
      controller.setBackgrounded(true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await container
          .read(vaultControllerProvider.notifier)
          .upsertHost(hostWith(hostname: 'other.example.com'));
      final calls = service.calls.length;
      old.drop();
      await settle(6);
      expect(service.calls.length, calls, reason: '没有拿新地址去连');
      final hold = tab(old.id).restoreHold!;
      expect(hold.kind, RestoreHoldKind.untilUser);
      expect(hold.message, contains('改过'));
      controller.setBackgrounded(false);
    });

    test('手机睡着时 Timer 不走：回前台按墙上时钟核，过了租期先清掉、恢复按保险库重取（LIFE07 真机撞出）', () async {
      final host = hostWith(password: 'pw-1');
      await start(hosts: [host]);
      final old = await connected(host);
      controller.setBackgrounded(true);
      await settle();
      // 墙上时钟过了 11 分钟，但 CPU 一直睡着：10 分钟的 Timer 没到点。
      clock = clock.add(const Duration(minutes: 11));
      expect(old.routePlan!.secretsForgotten, isFalse);
      await container
          .read(vaultControllerProvider.notifier)
          .upsertHost(hostWith(password: 'pw-2'));
      controller.setBackgrounded(false);
      expect(old.routePlan!.secretsForgotten, isTrue, reason: '回前台前先按墙上时钟核租期');
      old.drop();
      await settle(6);
      expect(service.calls.last.routePlan!.target.host.password, 'pw-2',
          reason: '恢复用的是保险库现在的密码，不是冻结在内存里的那份');
    });

    test('后台每一轮恢复前也按墙上时钟核租期', () async {
      final host = hostWith();
      await start(hosts: [host]);
      final old = await connected(host);
      controller.setBackgrounded(true);
      await settle();
      clock = clock.add(const Duration(minutes: 9));
      await controller.runRecoveryPass();
      expect(old.routePlan!.secretsForgotten, isFalse, reason: '还没满 10 分钟');
      clock = clock.add(const Duration(minutes: 2));
      await controller.runRecoveryPass();
      expect(old.routePlan!.secretsForgotten, isTrue);
      controller.setBackgrounded(false);
    });

    test('回到前台就取消租期：前台不清', () async {
      final host = hostWith();
      await start(hosts: [host], leaseAfter: const Duration(milliseconds: 30));
      final old = await connected(host);
      controller.setBackgrounded(true);
      controller.setBackgrounded(false);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(old.routePlan!.secretsForgotten, isFalse);
    });
  });

  group('App 被系统结束后放回标签（LIFE02、LIFE05）', () {
    tearDown(() => container.dispose());

    final target = TmuxTarget(
      hostKey: 'web.example.com:22',
      unixUser: 'root',
      uid: 0,
      socket: const TmuxSocketSpec.standard(),
      server: const TmuxServerIdentity(
          socketPath: '/tmp/tmux-0/default', pid: 41, startTime: 1700000000),
      sessionId: r'$3',
      sessionCreated: 1700000100,
      displayName: 'work',
    );

    test('开着的标签记进存储：没有密码；关掉的标签移出', () async {
      final host = hostWith(password: 'secret-pw');
      await start(hosts: [host]);
      final session = await connected(host);
      await settle();
      final saved = (await SharedPreferences.getInstance())
          .getString('xwshun.r22.restorableTabs')!;
      expect(saved, contains(session.id));
      expect(saved, isNot(contains('secret-pw')));
      await controller.close(0);
      await settle();
      expect(
          (await SharedPreferences.getInstance())
              .getString('xwshun.r22.restorableTabs'),
          isNull);
    });

    test('放回来的标签：断开、写明原因、不自动连、不开保活；点了才按 restore 连', () async {
      final host = hostWith();
      await start(
        hosts: [host],
        preferences: {
          'xwshun.r22.restorableTabs': jsonEncode([
            RestorableTab(id: 'tab-1', hostId: 'h1', label: 'web').toJson(),
            RestorableTab(
                    id: 'tab-2',
                    hostId: 'h1',
                    label: 'tmux: work',
                    tmux: target)
                .toJson(),
            RestorableTab(id: 'tab-3', hostId: 'gone', label: 'x').toJson(),
          ]),
        },
      );
      await settle(6);
      final tabs = controller.state.sessions;
      expect(tabs.map((value) => value.id), ['tab-1', 'tab-2'],
          reason: '主机删了的不放回');
      for (final value in tabs) {
        expect(value.connected, isFalse, reason: '状态不假 Active');
        expect(value.restored, isTrue);
        expect(value.restoreHold?.kind, RestoreHoldKind.untilUser);
      }
      expect(service.calls, isEmpty, reason: '不自动连');
      expect(platform.requests.whereType<KeepAliveRequest>(), isEmpty);
      expect(tabs[1].host.password, isNull, reason: 'tmux 标签的主机拷贝里不留密码');

      unawaited(controller.reconnect('tab-2', verifyHostKey: accept));
      await settle(6);
      final call = service.calls.single;
      expect(call.purpose, ConnectionPurpose.restore);
      expect(call.tmuxAttach!.sameAs(target), isTrue);
      expect(call.routePlan!.target.endpoint.authority, target.hostKey);
      expect(call.verifyHostKey, same(accept), reason: '用界面给的指纹核对');
    });

    test('放回来的 tmux 标签：主机地址改了就不附着', () async {
      final host = hostWith(hostname: 'moved.example.com');
      await start(
        hosts: [host],
        preferences: {
          'xwshun.r22.restorableTabs': jsonEncode([
            RestorableTab(
                    id: 'tab-2',
                    hostId: 'h1',
                    label: 'tmux: work',
                    tmux: target)
                .toJson(),
          ]),
        },
      );
      await settle(6);
      await controller.reconnect('tab-2', verifyHostKey: accept);
      await settle();
      expect(service.calls, isEmpty);
      expect(tab('tab-2').restoreHold!.message, contains('地址改过'));
    });

    test('存储里读坏的条目整条丢掉，不变成普通 shell 标签', () {
      expect(
          RestorableTab.fromJson({
            'id': 't',
            'hostId': 'h',
            'label': 'x',
            'tmux': {
              ...target.toJson(),
              'socketKind': 'path',
              'socketValue': 'rel/x'
            },
          }),
          isNull);
      expect(RestorableTab.fromJson({'id': 't'}), isNull);
      expect(TmuxTarget.fromJson(target.toJson())!.sameAs(target), isTrue);
    });
  });

  group('哪些错自动恢复会重试', () {
    test('只认同一路线上的网络错误', () {
      for (final error in <Object>[
        const SocketException('refused'),
        TimeoutException('slow'),
        const ConnectStageException('tcp'),
        SSHAuthAbortError('closed before auth'),
        const ProxyHandshakeException('代理握手超时', transient: true),
        RouteHopException(1, 'hop', const SocketException('x')),
      ]) {
        expect(isTransientConnectionError(error), isTrue, reason: '$error');
      }
      for (final error in <Object>[
        SSHAuthFailError('denied'),
        SSHAuthAbortError('hostkey', SSHHostkeyError('rejected')),
        const ProxyHandshakeException('认证失败'),
        const RouteConfigException('bad'),
        const TailscaleCheckNeedsUser(),
        StateError('unknown'),
        RouteHopException(0, 'hop', SSHAuthFailError('denied')),
      ]) {
        expect(isTransientConnectionError(error), isFalse, reason: '$error');
      }
    });
  });

  group('路线去掉凭据', () {
    test('只留形状；形状含入口、每跳地址、用户名、认证方式、私钥 ID', () {
      final jump = HostProfile.create(
          id: 'j', label: 'jump', hostname: 'jump.example.com', username: 'ops')
        ..data['password'] = 'jump-pw';
      final target = hostWith()
        ..data['hostChain'] = {
          'hostIds': ['j']
        }
        ..data['proxyConfig'] = {
          'type': 'socks5',
          'host': '127.0.0.1',
          'port': 1080,
          'username': 'u',
          'password': 'proxy-pw',
        };
      final plan = resolveRoutePlan(target,
          hosts: [jump, target], proxyProfiles: const [], keys: const []);
      final forgotten = plan.withoutSecrets();
      expect(forgotten.secretsForgotten, isTrue);
      expect(forgotten.shape, plan.shape);
      expect((forgotten.entry as ProxyEntry).password, isNull);
      expect(forgotten.hops.map((hop) => hop.host.password), [null, null]);
      expect(plan.target.host.password, 'pw-1', reason: '原路线不受影响');

      final other = resolveRoutePlan(
          hostWith()
            ..data['hostChain'] = {
              'hostIds': ['j']
            },
          hosts: [jump],
          proxyProfiles: const [],
          keys: const []);
      expect(other.shape, isNot(plan.shape), reason: '去掉代理就是另一条路线');
    });
  });
}

class _Platform extends NoConnectionPlatform {
  final _events = StreamController<ConnectionPlatformEvent>.broadcast();
  final requests = <KeepAliveRequest?>[];
  bool locked = false;

  void emit(ConnectionPlatformEvent event) => _events.add(event);

  @override
  Stream<ConnectionPlatformEvent> get events => _events.stream;

  @override
  Future<KeepAliveResult> setKeepAlive(KeepAliveRequest? request) async {
    requests.add(request);
    return KeepAliveResult(started: request != null);
  }

  @override
  Future<bool> isDeviceLocked() async => locked;

  @override
  Future<NetworkStatus> currentNetwork() async => const NetworkStatus(
      available: true, id: 'wifi-1', transports: {'wifi'}, validated: true);
}

class _Call {
  _Call(this.sessionId, this.attempt, this.purpose, this.routePlan,
      this.tmuxAttach, this.verifyHostKey);
  final String sessionId;
  final ConnectionAttempt attempt;
  final ConnectionPurpose purpose;
  final RoutePlan? routePlan;
  final TmuxTarget? tmuxAttach;
  final HostKeyVerifier verifyHostKey;
  final result = Completer<ActiveTerminalSession>();
}

class _Service extends SshService {
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
    required TerminalSessionAdapter terminal,
    ConnectionPurpose purpose = ConnectionPurpose.fresh,
    ConnectionAttempt? attempt,
    TmuxTarget? tmuxAttach,
  }) {
    final call = _Call(
        sessionId, attempt!, purpose, routePlan, tmuxAttach, verifyHostKey);
    calls.add(call);
    return call.result.future;
  }
}

class _Session extends ActiveTerminalSession {
  _Session(String id, HostProfile host, {super.routePlan})
      : super(
          id: id,
          host: host,
          terminal: GhosttyTerminalAdapter(),
          verifyHostKey: (_, __, ___) async => true,
          keyboardInteractive: null,
        );

  final _done = Completer<void>();
  bool aborted = false;
  bool failPing = false;
  final pingTimeouts = <Duration>[];

  void drop() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> ping({Duration timeout = const Duration(seconds: 8)}) async {
    pingTimeouts.add(timeout);
    if (failPing) throw const SocketException('ping failed');
  }

  @override
  void abort() {
    aborted = true;
    super.abort();
  }
}
