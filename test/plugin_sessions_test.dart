import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/application/plugin_sessions.dart';
import 'package:netcatty_mobile/domain/plugins/builtin_plugins.dart';
import 'package:netcatty_mobile/infrastructure/plugins/android_plugin_bridge.dart';
import 'package:plugin_api/plugin_api.dart';

// X03 宿主侧会话状态机。桥是假的：这里测的是 Dart 这一层怎么对待插件发来的事件和字节。
// 真实的 FD、Binder、插件进程在模拟器上用 integration_test 验证，见 evidence/X03.md。

String descriptor(String id, String package) => jsonEncode({
      'schemaVersion': 1,
      'pluginId': id,
      'displayName': id,
      'version': '0.1.0',
      'apiMajor': 1,
      'apiMinor': 0,
      'deployment': 'android-service',
      'capabilities': ['terminal-session'],
      'supportedRoutes': ['system-default'],
      'platforms': ['android'],
      'permissions': ['own-session-input-output'],
      'packageName': package,
      'serviceClass': '$package.S',
    });

class FakeBridge extends AndroidPluginBridge {
  final data = StreamController<SessionDataEvent>.broadcast(sync: true);
  final control = StreamController<SessionBridgeEvent>.broadcast(sync: true);
  final calls = <String>[];
  var acks = 0;

  @override
  Stream<SessionDataEvent> get sessionData => data.stream;
  @override
  Stream<SessionBridgeEvent> get sessionEvents => control.stream;

  @override
  Future<void> openSession({
    required String packageName,
    required String handle,
    required int generation,
    required int cols,
    required int rows,
  }) async =>
      calls.add('open $packageName $generation');

  @override
  Future<bool> closeSession(String p, String h, int g) async {
    calls.add('close $p $g');
    return true;
  }

  @override
  Future<void> ackSession(String p, String h, int g) async => acks++;

  void state(PluginTerminalSession s, int seq, String state,
          {String? package, int? generation, String? handle}) =>
      control.add(
        SessionBridgeEvent(
          type: 'sessionEvent',
          packageName: package ?? s.packageName,
          handle: handle ?? s.handle,
          generation: generation ?? s.generation,
          sequence: seq,
          state: state,
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBridge bridge;
  late PluginRegistry registry;
  late PluginSessionManager manager;

  PluginEntry ready(String id, String package) {
    registry
      ..offerInstalled(
        packageName: package,
        descriptorJson: descriptor(id, package),
        signerDigests: {'cert-$package'},
        serviceClass: '$package.S',
      )
      ..approve(
        ApprovedBinding(
          pluginId: id,
          packageName: package,
          signingDigest: 'cert-$package',
          capabilities: {Capability.terminalSession},
        ),
      );
    return registry.readyEntry(id)!;
  }

  setUp(() {
    bridge = FakeBridge();
    registry = PluginRegistry(
      policy: AdmissionPolicy(builtinIds: BuiltinPlugins.ids),
    );
    manager = PluginSessionManager(bridge, registry);
  });

  test('没批准的 provider：在宿主这边就拒绝，不去碰插件', () async {
    registry.offerInstalled(
      packageName: 'p.a',
      descriptorJson: descriptor('example.a', 'p.a'),
      signerDigests: {'c'},
      serviceClass: 'p.a.S',
    );
    final entry = registry.entries.singleWhere((e) => e.packageName == 'p.a');
    await expectLater(manager.open(entry), throwsA(isA<PluginUnavailable>()));
    expect(bridge.calls, isEmpty);
  });

  test('每次打开代次递增；active 之后才算运行', () async {
    final a = await manager.open(ready('example.a', 'p.a'));
    final b = await manager.open(ready('example.a', 'p.a'));
    expect(b.generation, greaterThan(a.generation));
    expect(a.phase, SessionPhase.opening);
    bridge.state(a, 1, 'active');
    expect(a.phase, SessionPhase.active);
    expect(registry.pluginSessions, hasLength(2));
  });

  group('PLG06 句柄归属与代次', () {
    test('别的插件拿着这个会话的句柄发事件：不作用到这个会话', () async {
      final a = await manager.open(ready('example.a', 'p.a'));
      ready('example.b', 'p.b');
      bridge.state(a, 1, 'active', package: 'p.b');
      expect(a.phase, SessionPhase.opening);
      bridge.state(a, 1, 'closed', package: 'p.b');
      expect(a.phase, SessionPhase.opening);
    });

    test('旧代次、序号不增的事件：丢弃并计数', () async {
      final a = await manager.open(ready('example.a', 'p.a'));
      bridge.state(a, 1, 'active');
      bridge.state(a, 2, 'closed', generation: a.generation - 1);
      expect(a.phase, SessionPhase.active);
      bridge.state(a, 5, 'resized:100x30');
      bridge.state(a, 4, 'resized:1x1');
      expect(a.lastResize, '100x30');
      expect(a.droppedEvents, 1);
    });

    test('字节只交给句柄、包名、代次都对上的会话', () async {
      final a = await manager.open(ready('example.a', 'p.a'));
      final got = <int>[];
      a.output.listen(got.addAll);
      bridge.data
        ..add(SessionDataEvent('p.b', a.handle, a.generation, Uint8List(3)))
        ..add(SessionDataEvent('p.a', a.handle, a.generation + 1, Uint8List(3)))
        ..add(
          SessionDataEvent(
            'p.a',
            a.handle,
            a.generation,
            Uint8List.fromList([1, 2]),
          ),
        );
      await pumpEventQueue();
      expect(got, [1, 2]);
    });
  });

  group('PLG08 取消、重复关闭、迟到的成功', () {
    test('打开中就关：迟到的 active 不复活；重复关闭只关一次', () {
      fakeAsync((clock) {
        late PluginTerminalSession s;
        manager.open(ready('example.a', 'p.a')).then((v) => s = v);
        clock.flushMicrotasks();
        final first = s.close();
        final second = s.close();
        clock.flushMicrotasks();
        bridge.state(s, 1, 'active'); // 插件慢，关了才回报 active
        expect(s.phase, SessionPhase.closing);
        bridge.state(s, 2, 'closed');
        clock.flushMicrotasks();
        expect(s.phase, SessionPhase.closed);
        expect(s.stopConfirmed, isTrue);
        var done = 0;
        first.then((_) => done++);
        second.then((_) => done++);
        clock.elapse(const Duration(seconds: 3));
        expect(done, 2);
        expect(bridge.calls.where((c) => c.startsWith('close')), hasLength(1));
        bridge.state(s, 3, 'active');
        expect(s.phase, SessionPhase.closed);
        expect(registry.pluginSessions, isEmpty);
      });
    });

    test('插件不回报 closed：2 秒后收尾为「停止未确认」，不伪报成功', () {
      fakeAsync((clock) {
        late PluginTerminalSession s;
        manager.open(ready('example.a', 'p.a')).then((v) => s = v);
        clock.flushMicrotasks();
        bridge.state(s, 1, 'active');
        s.close();
        clock.elapse(const Duration(milliseconds: 1900));
        expect(s.phase, SessionPhase.closing);
        clock.elapse(const Duration(milliseconds: 200));
        expect(s.phase, SessionPhase.closed);
        expect(s.stopConfirmed, isFalse);
      });
    });
  });

  group('PLG07 背压：订阅者不取就不回 ack', () {
    test('没订阅、暂停时不 ack；恢复后补上', () async {
      final s = await manager.open(ready('example.a', 'p.a'));
      bridge.state(s, 1, 'active');
      void chunk() => bridge.data.add(
            SessionDataEvent('p.a', s.handle, s.generation, Uint8List(4)),
          );
      chunk();
      chunk();
      await pumpEventQueue();
      expect(bridge.acks, 0);
      final sub = s.output.listen((_) {});
      await pumpEventQueue();
      expect(bridge.acks, 2);
      sub.pause();
      chunk();
      await pumpEventQueue();
      expect(bridge.acks, 2);
      sub.resume();
      await pumpEventQueue();
      expect(bridge.acks, 3);
    });
  });

  group('PLG09/PLG12 连接断开', () {
    test('插件进程死亡：只有它的会话变 providerDied，别的插件会话不受影响', () async {
      final a = await manager.open(ready('example.a', 'p.a'));
      final b = await manager.open(ready('example.b', 'p.b'));
      bridge
        ..state(a, 1, 'active')
        ..state(b, 1, 'active')
        ..control.add(
          SessionBridgeEvent(
            type: 'sessionClosed',
            packageName: 'p.a',
            handle: a.handle,
            generation: a.generation,
            cause: 'providerDied',
          ),
        );
      expect(a.phase, SessionPhase.providerDied);
      expect(b.phase, SessionPhase.active);
    });

    test('撤销批准：注册表关掉它的会话；插件之后再发的事件都进不来', () {
      fakeAsync((clock) {
        late PluginTerminalSession a;
        late PluginTerminalSession b;
        manager.open(ready('example.a', 'p.a')).then((v) => a = v);
        manager.open(ready('example.b', 'p.b')).then((v) => b = v);
        clock.flushMicrotasks();
        bridge
          ..state(a, 1, 'active')
          ..state(b, 1, 'active');
        registry.revoke('example.a');
        clock.flushMicrotasks();
        expect(a.phase, SessionPhase.closing);
        for (var i = 2; i < 10; i++) {
          bridge.state(a, i, 'still-running');
        }
        clock.elapse(const Duration(seconds: 3));
        expect(a.phase, SessionPhase.closed);
        expect(a.stopConfirmed, isFalse);
        expect(b.phase, SessionPhase.active);
      });
    });

    test('读到 EOF 时插件进程已不在：记为插件死亡，不是普通中断', () async {
      final a = await manager.open(ready('example.a', 'p.a'));
      bridge
        ..state(a, 1, 'active')
        ..control.add(
          SessionBridgeEvent(
            type: 'sessionEof',
            packageName: 'p.a',
            handle: a.handle,
            generation: a.generation,
            providerAlive: false,
          ),
        );
      expect(a.phase, SessionPhase.providerDied);
    });

    test('插件自己关了它那一端：会话中断，不是正常关闭', () async {
      final a = await manager.open(ready('example.a', 'p.a'));
      bridge
        ..state(a, 1, 'active')
        ..control.add(
          SessionBridgeEvent(
            type: 'sessionEof',
            packageName: 'p.a',
            handle: a.handle,
            generation: a.generation,
          ),
        );
      expect(a.phase, SessionPhase.interrupted);
    });
  });
}
