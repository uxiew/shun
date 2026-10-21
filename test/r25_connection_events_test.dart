import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/connection_diagnosis.dart';
import 'package:shun/application/connection_events.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/transport/proxy_transport.dart';

// R25 / UX10、SEC12：本地连接记录只存受限元数据，按上限修剪，用时取尝试自己的单调时钟。
void main() {
  final now = DateTime.utc(2026, 10, 21, 12);

  ConnectionEvent event(String host, {DateTime? at, int? n}) => ConnectionEvent(
        hostId: host,
        at: at ?? now,
        kind: ConnectionEventKind.open,
        attempt: n,
      );

  group('修剪', () {
    test('每台主机只留最新 200 条，别的主机不受影响', () {
      final events = [
        for (var i = 0; i < 250; i++) event('a', n: i),
        for (var i = 0; i < 3; i++) event('b', n: i),
      ];
      final kept = pruneConnectionEvents(events, now);
      final a = kept.where((e) => e.hostId == 'a').toList();
      expect(a, hasLength(connectionEventsPerHost));
      expect(a.first.attempt, 50, reason: '删的是最旧的 50 条');
      expect(a.last.attempt, 249);
      expect(kept.where((e) => e.hostId == 'b'), hasLength(3));
    });

    test('一共只留最新 1000 条，顺序不变', () {
      final events = [
        for (var h = 0; h < 8; h++)
          for (var i = 0; i < 150; i++) event('h$h', n: h * 1000 + i),
      ];
      final kept = pruneConnectionEvents(events, now);
      expect(kept, hasLength(connectionEventsTotal));
      expect(kept.first.attempt, 1050, reason: 'h0 整台和 h1 的前 50 条最旧');
      expect(kept.last.attempt, 7149);
      final order = [for (final e in kept) e.attempt!];
      expect(order, [...order]..sort());
    });

    test('超过 7 天的删，记在一天以后的（时钟拨回去过）也删', () {
      final kept = pruneConnectionEvents([
        event('a', at: now.subtract(const Duration(days: 7, minutes: 1)), n: 1),
        event('a', at: now.subtract(const Duration(days: 6, hours: 23)), n: 2),
        event('a', at: now.add(const Duration(hours: 2)), n: 3),
        event('a', at: now.add(const Duration(days: 2)), n: 4),
      ], now);
      expect([for (final e in kept) e.attempt], [2, 3]);
    });
  });

  group('JSON', () {
    test('来回一遍不丢字段', () {
      final original = ConnectionEvent(
        hostId: 'web',
        at: now,
        kind: ConnectionEventKind.restore,
        protocol: HostProtocol.ssh,
        entry: ConnectionEntryKind.socks5,
        hopIds: const ['edge', 'web'],
        stages: const [
          ConnectionEventStage(
              ConnectionStep.proxy, 0, Duration(milliseconds: 3)),
          ConnectionEventStage(
            ConnectionStep.handshake,
            0,
            Duration(milliseconds: 40),
            userWait: Duration(seconds: 2),
          ),
        ],
        outcome: ConnectionOutcome.failed,
        total: const Duration(milliseconds: 2500),
        failure: ConnectionFailureKind.authFailed,
        failureHop: 0,
        attempt: 3,
      );
      final back = ConnectionEvent.fromJson(
        jsonDecode(jsonEncode(original.toJson())),
      )!;
      expect(back.hostId, 'web');
      expect(back.at, now);
      expect(back.kind, ConnectionEventKind.restore);
      expect(back.entry, ConnectionEntryKind.socks5);
      expect(back.hopIds, ['edge', 'web']);
      expect(back.stages.map((s) => s.step),
          [ConnectionStep.proxy, ConnectionStep.handshake]);
      expect(back.stages[1].userWait, const Duration(seconds: 2));
      expect(back.failure, ConnectionFailureKind.authFailed);
      expect(back.failureHop, 0);
      expect(back.attempt, 3);
      expect(back.stageDuration(0), const Duration(milliseconds: 37));
      expect(back.stageDuration(1), const Duration(milliseconds: 2460));
      expect(back.preparation, const Duration(milliseconds: 3));
    });

    test('不认识的失败分类按「其他」留着；缺必填字段、阶段坏了的整条不要', () {
      final base = event('a').toJson();
      expect(
        ConnectionEvent.fromJson({...base, 'f': 'fromTheFuture'})!.failure,
        ConnectionFailureKind.other,
      );
      expect(ConnectionEvent.fromJson({...base}..remove('h')), isNull);
      expect(ConnectionEvent.fromJson({...base, 'k': 'nope'}), isNull);
      expect(
        ConnectionEvent.fromJson({
          ...base,
          's': [
            {'n': 'dial', 'i': 0, 't': 'x'},
          ],
        }),
        isNull,
      );
    });
  });

  group('从一次尝试生成记录', () {
    HostProfile host(String id, Map<String, Object?> extra) => HostProfile({
          'id': id,
          'label': 'LABEL-$id',
          'hostname': '$id.decoy-host.example',
          'port': 2222,
          'username': 'decoy-user-$id',
          'password': 'DECOY-PASSWORD-$id',
          'protocol': 'ssh',
          ...extra,
        });

    late RoutePlan plan;
    setUp(() {
      plan = resolveRoutePlan(
        host('web', {
          'hostChain': {
            'hostIds': ['edge'],
          },
          'proxyConfig': {
            'type': 'socks5',
            'host': '10.9.8.7',
            'port': 1080,
            'username': 'decoy-proxy-user',
            'password': 'DECOY-PROXY-PASSWORD',
          },
        }),
        hosts: [host('edge', const {})],
        proxyProfiles: const [],
      );
    });

    test('阶段、失败跳、分类记下来；地址、名字、口令、报错原话都不进记录', () async {
      final attempt = ConnectionAttempt();
      attempt.report(const ConnectionStage(
        ConnectionStep.proxy,
        hopCount: 2,
        label: 'LABEL-edge',
        detail: '10.9.8.7:1080',
      ));
      attempt.report(const ConnectionStage(
        ConnectionStep.handshake,
        hopCount: 2,
        label: 'LABEL-edge',
        detail: 'edge.decoy-host.example:2222',
      ));
      // 第一次连接弹指纹框：等人的时间单独记。
      await attempt.waitingForUser(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      attempt.report(const ConnectionStage(
        ConnectionStep.forward,
        hopCount: 2,
        label: 'LABEL-edge',
        detail: 'web.decoy-host.example:2222',
      ));
      final error = RouteHopException(
        1,
        '目标“LABEL-web”（web.decoy-host.example:2222）SSH 握手或登录失败：DECOY-BANNER',
        SSHAuthFailError('DECOY-BANNER'),
        relayed: true,
      );
      final recorded = attemptEvent(
        hostId: 'web',
        now: now,
        kind: ConnectionEventKind.open,
        protocol: HostProtocol.ssh,
        attempt: attempt,
        plan: plan,
        error: error,
      );
      expect(recorded.outcome, ConnectionOutcome.failed);
      expect(recorded.failure, ConnectionFailureKind.authFailed);
      expect(recorded.failureHop, 1);
      expect(recorded.entry, ConnectionEntryKind.socks5);
      expect(recorded.hopIds, ['edge', 'web']);
      expect(recorded.stages.map((s) => s.step), [
        ConnectionStep.proxy,
        ConnectionStep.handshake,
        ConnectionStep.forward,
      ]);
      expect(recorded.stages[1].userWait,
          greaterThanOrEqualTo(const Duration(milliseconds: 30)));
      expect(recorded.stages[0].userWait, Duration.zero);
      expect(recorded.total, greaterThanOrEqualTo(recorded.stages.last.start));
      expect(recorded.at.isBefore(now) || recorded.at == now, isTrue);

      // 端口号不查：用时是微秒整数，碰巧含「1080」就会误报。没有地址就没有端口。
      final json = jsonEncode(recorded.toJson());
      for (final decoy in ['LABEL', 'decoy', 'DECOY', '10.9.8.7']) {
        expect(json, isNot(contains(decoy)), reason: decoy);
      }
    });

    test('取消不算失败；取消以后的阶段不记', () {
      final attempt = ConnectionAttempt();
      attempt.report(const ConnectionStage(ConnectionStep.dial));
      attempt.cancel();
      attempt.report(const ConnectionStage(ConnectionStep.handshake));
      final recorded = attemptEvent(
        hostId: 'web',
        now: now,
        kind: ConnectionEventKind.open,
        protocol: HostProtocol.ssh,
        attempt: attempt,
        error: const ConnectionCancelledException(),
        cancelled: true,
      );
      expect(recorded.outcome, ConnectionOutcome.cancelled);
      expect(recorded.failure, isNull);
      expect(recorded.stages.map((s) => s.step), [ConnectionStep.dial]);
    });

    test('代理、连不上、指纹各归各的类', () {
      expect(
        classifyConnectionFailure(const RouteHopException(
            0, 'x', ProxyHandshakeException('x'),
            relayed: true)),
        ConnectionFailureKind.proxy,
      );
      expect(
        classifyConnectionFailure(
            const RouteHopException(0, 'x', SocketException('x'))),
        ConnectionFailureKind.unreachable,
      );
      expect(
        classifyConnectionFailure(
            RouteHopException(0, 'x', SSHHostkeyError('x'))),
        ConnectionFailureKind.hostKey,
      );
      expect(
        classifyConnectionFailure(
            RouteHopException(1, 'x', SSHAuthAbortError('x'), relayed: true)),
        ConnectionFailureKind.authAbortedRelayed,
      );
      expect(classifyConnectionFailure(StateError('x')),
          ConnectionFailureKind.other);
    });

    test('每一类都有「下一步」，没有一句是替用户改成直连的', () {
      for (final kind in ConnectionFailureKind.values) {
        final step = failureNextStep(kind);
        expect(step, isNotEmpty, reason: kind.name);
        expect(failureLabel(kind), isNotEmpty, reason: kind.name);
        if (kind != ConnectionFailureKind.moshRoute) {
          expect(step, isNot(contains('直连')), reason: kind.name);
        }
      }
    });
  });

  group('记录本身', () {
    test('读完文件之前记的接在后面，不盖掉旧记录', () async {
      final store = MemoryConnectionEventStore([event('old', n: 1)]);
      final log = ConnectionEventLog(store, now: () => now);
      log.record(event('new', n: 2));
      await log.ready;
      await Future<void>.delayed(Duration.zero);
      expect([for (final e in log.state) e.attempt], [1, 2]);
      final saved = jsonDecode(store.saved!) as List;
      expect(saved, hasLength(2));
    });

    test('清除一台、清除全部：写回文件后才返回', () async {
      final store = MemoryConnectionEventStore([
        event('a', n: 1),
        event('b', n: 2),
        event('a', n: 3),
      ]);
      final log = ConnectionEventLog(store, now: () => now);
      await log.clearHost('a');
      expect([for (final e in log.state) e.attempt], [2]);
      expect(jsonDecode(store.saved!), hasLength(1));
      await log.clearAll();
      expect(log.state, isEmpty);
      expect(jsonDecode(store.saved!), isEmpty);
    });

    test('打开记录页时把过期的删掉，没有过期的就不写盘', () async {
      var clock = now;
      final store = MemoryConnectionEventStore([event('a', n: 1)]);
      final log = ConnectionEventLog(store, now: () => clock);
      await log.prune();
      expect(store.saves, 0);
      clock = now.add(const Duration(days: 8));
      await log.prune();
      expect(log.state, isEmpty);
      expect(store.saves, 1);
    });

    test('文件：写了读得回来；坏文件从空的开始、下一次写盖掉；清空删文件', () async {
      final dir = await Directory.systemTemp.createTemp('r25-events');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileConnectionEventStore(() async => dir);
      await store.save([event('a', n: 7)]);
      expect((await store.load()).single.attempt, 7);

      final file = File('${dir.path}/connection_events.json');
      await file.writeAsString('{not json');
      final log = ConnectionEventLog(store, now: () => now);
      await log.ready;
      expect(log.state, isEmpty);
      log.record(event('b', n: 8));
      await log.clearHost('nobody');
      expect((await store.load()).single.attempt, 8);

      await log.clearAll();
      expect(await file.exists(), isFalse);
    });
  });
}
