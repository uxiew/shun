// X03 设备验证：在模拟器/真机上驱动真实的插件桥（Kotlin）和真实的 echo 插件 APK。
//
// 这不是 CI 测试：要先装好对应的测试插件变体，按场景分别跑。编排脚本和步骤见 plugins/README.md 的「X03 设备检查」。
//   flutter test integration_test/plugin_session_test.dart -d <设备> --dart-define=X03_SCENARIO=stream
//
// 批准是用 App 自己的批准存储写入的（批准界面在 X02 已用界面实测过），这里只测会话本身。
// 输出以 "X03 " 开头的行进 logcat / 测试输出，作为证据。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/application/plugin_discovery.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/plugin_sessions.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/plugins/builtin_plugins.dart';
import 'package:shun/infrastructure/plugins/android_plugin_bridge.dart';
import 'package:shun/infrastructure/plugins/plugin_approval_store.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';

const scenario = String.fromEnvironment('X03_SCENARIO', defaultValue: 'stream');
const echo = 'example.shun.fixture.echo';
const second = 'example.shun.fixture.echo.debugkey';

void report(String key, Object? value) => debugPrint('X03 $key=$value');

Future<void> until(bool Function() done,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('等待超时');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

int fdCount() => Directory('/proc/self/fd').listSync().length;

Future<void> roundTrip(PluginTerminalSession s, String text) async {
  final got = BytesBuilder();
  final sub = s.output.listen(got.add);
  await s.write(Uint8List.fromList(utf8.encode(text)));
  await until(() => got.length >= text.length,
      timeout: const Duration(seconds: 5));
  await sub.cancel();
  expect(utf8.decode(got.takeBytes()), text);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AndroidPluginBridge bridge;
  late PluginRegistry registry;
  late PluginDiscovery discovery;
  late PluginSessionManager manager;
  final bridgeLog = <PluginBridgeEvent>[];

  Future<void> setUpPlugins() async {
    bridge = AndroidPluginBridge();
    bridge.events.listen(bridgeLog.add);
    registry = PluginRegistry(
      policy: AdmissionPolicy(
        builtinIds: BuiltinPlugins.ids,
        allowDebugSigners: kDebugMode,
      ),
    );
    discovery = PluginDiscovery(
      bridge,
      PluginApprovalStore(await SharedPreferences.getInstance()),
      registry,
    );
    manager = PluginSessionManager(bridge, registry);
    await discovery.refresh();
  }

  PluginEntry entry(String package) =>
      registry.entries.singleWhere((e) => e.packageName == package);

  /// 待批准就批准（用 App 自己的批准存储），然后连接测试（握手 + ping）。
  Future<PluginEntry> connected(String package) async {
    var e = entry(package);
    if (e.status == PluginStatus.needsApproval) {
      await discovery.approve(e);
      e = entry(package);
    }
    expect(e.status, PluginStatus.ready, reason: e.reason);
    final check = await discovery.check(e);
    report('check.$package', check);
    expect(check, contains('握手成功'));
    return e;
  }

  Future<PluginTerminalSession> activeSession(PluginEntry e) async {
    final s = await manager.open(e);
    if (s.phase != SessionPhase.active) {
      await s.phases
          .firstWhere((p) => p == SessionPhase.active)
          .timeout(const Duration(seconds: 10));
    }
    return s;
  }

  testWidgets('X03 场景：$scenario', (tester) async {
    await setUpPlugins();
    switch (scenario) {
      case 'stream':
        await _stream(connected, activeSession, discovery, report);
      case 'slowopen':
        final fd0 = fdCount();
        final e = await connected(echo);
        final s = await manager.open(e);
        expect(s.phase, SessionPhase.opening);
        await s.close(); // 插件要 3 秒后才会回报 active
        report('slowopen.phaseAfterClose', s.phase);
        report('slowopen.stopConfirmed', s.stopConfirmed);
        await Future<void>.delayed(const Duration(seconds: 5));
        report('slowopen.phaseAfter5s', s.phase);
        expect(s.phase, SessionPhase.closed);
        expect(s.stopConfirmed, isTrue);
        await discovery.disconnect(echo);
        await Future<void>.delayed(const Duration(seconds: 1));
        report('slowopen.fds', '$fd0 -> ${fdCount()}');
      case 'misbehave':
        final e = await connected(echo);
        final s = await activeSession(e);
        await Future<void>.delayed(const Duration(seconds: 2));
        final dropped = bridgeLog
            .where((l) => l.type == 'droppedEvent')
            .map((l) => l.detail)
            .toList();
        report('misbehave.dropped', dropped);
        report('misbehave.sessionDropped', s.droppedEvents);
        expect(dropped.any((d) => d.contains('旧代次')), isTrue);
        expect(dropped.any((d) => d.contains('不是这个插件的会话')), isTrue);
        expect(s.phase, SessionPhase.active);
        await roundTrip(s, 'still fine');
        await s.close();
        expect(s.stopConfirmed, isTrue);
      case 'stubborn':
        final a = await activeSession(await connected(echo));
        final b = await activeSession(await connected(second));
        final droppedBefore =
            bridgeLog.where((l) => l.type == 'droppedEvent').length;
        await discovery.revoke(entry(echo)); // 撤销批准：注册表关会话，桥断开连接
        await Future<void>.delayed(const Duration(seconds: 4));
        final dropped = bridgeLog
            .where((l) => l.type == 'droppedEvent')
            .skip(droppedBefore)
            .toList();
        report('stubborn.a.phase', a.phase);
        report('stubborn.a.stopConfirmed', a.stopConfirmed);
        report('stubborn.droppedAfterRevoke', dropped.length);
        report('stubborn.droppedSample',
            dropped.take(2).map((l) => l.detail).toList());
        expect(a.phase, SessionPhase.closed);
        expect(a.stopConfirmed, isFalse);
        expect(dropped.length, greaterThanOrEqualTo(4));
        expect(b.phase, SessionPhase.active);
        await roundTrip(b, 'other provider unaffected');
        report('stubborn.b', 'round trip ok');
        await b.close();
      case 'kill':
        const port = int.fromEnvironment('SSH_PORT');
        final host = HostProfile({
          'id': 'x03-edge',
          'label': 'edge',
          'hostname': '127.0.0.1',
          'port': port,
          'username': const String.fromEnvironment('SSH_USER'),
          'password': const String.fromEnvironment('SSH_PASS'),
          'authMethod': 'password',
          'protocol': 'ssh',
        });
        final ssh = await SshService().connect(
          terminal: GhosttyTerminalAdapter(),
          sessionId: 'x03',
          host: host,
          hosts: [host],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: (_, __, fp) async =>
              fp == const String.fromEnvironment('SSH_FP'),
        );
        Future<String> run(String c) =>
            ssh.sshClient!.run(c).then((o) => utf8.decode(o).trim());
        report('kill.sshBefore', await run('echo before'));
        final a = await activeSession(await connected(echo));
        final b = await activeSession(await connected(second));
        report('kill.READY', 'kill $echo now');
        await a.phases
            .firstWhere((p) => p.isTerminal)
            .timeout(const Duration(seconds: 90));
        report('kill.a.phase', a.phase);
        expect(a.phase, SessionPhase.providerDied);
        expect(b.phase, SessionPhase.active);
        await roundTrip(b, 'second provider alive');
        report('kill.sshAfter', await run('echo after'));
        final sftp = await ssh.sshClient!.sftp();
        final listing = await sftp.listdir('/');
        report('kill.sftpAfter', '${listing.length} entries in /');
        expect(listing, isNotEmpty);
        sftp.close();
        await b.close();
        await ssh.close();
      case 'hostkill':
        final a = await activeSession(await connected(echo));
        await roundTrip(a, 'before host dies');
        report('hostkill.READY', 'kill host now');
        await Future<void>.delayed(const Duration(minutes: 2)); // 等脚本杀掉本进程
      case 'version':
        final e = entry(echo);
        if (e.status == PluginStatus.needsApproval) await discovery.approve(e);
        final check = await discovery.check(entry(echo));
        report('version.check', check);
        expect(check, contains('API 版本'));
        await expectLater(
          manager.open(entry(echo)),
          throwsA(isA<PluginBridgeException>()),
        );
        report('version.open', 'refused: not connected');
      default:
        fail('未知场景 $scenario');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _stream(
  Future<PluginEntry> Function(String) connected,
  Future<PluginTerminalSession> Function(PluginEntry) activeSession,
  PluginDiscovery discovery,
  void Function(String, Object?) report,
) async {
  final fd0 = fdCount();
  final e = await connected(echo);
  final s = await activeSession(e);
  report('stream.fdsWithSession', '$fd0 -> ${fdCount()}');

  // ① 逐字节写 2000 次，回来的必须一字不差、次序不乱。
  final got = BytesBuilder();
  final sub = s.output.listen(got.add);
  final bytes = List<int>.generate(2000, (i) => i % 251);
  var sw = Stopwatch()..start();
  for (final b in bytes) {
    await s.write(Uint8List.fromList([b]));
  }
  await until(() => got.length >= bytes.length);
  expect(got.takeBytes(), bytes);
  report('stream.byteByByte', '2000 bytes in ${sw.elapsedMilliseconds} ms');

  // ② 1 MiB 随机大小的块，每 50 块插一次 resize：控制事件不混进字节流。
  final rnd = Random(3);
  final sent = BytesBuilder();
  var chunks = 0;
  var resizes = 0;
  String? lastAsked;
  sw = Stopwatch()..start();
  while (sent.length < 1 << 20) {
    final chunk = Uint8List.fromList(
        List.generate(1 + rnd.nextInt(8192), (_) => rnd.nextInt(256)));
    sent.add(chunk);
    await s.write(chunk);
    if (++chunks % 50 == 0) {
      await s.resize(80 + chunks % 40, 24);
      lastAsked = '${80 + chunks % 40}x24';
      resizes++;
    }
  }
  final expected = sent.takeBytes();
  await until(() => got.length >= expected.length);
  final back = got.takeBytes();
  expect(back.length, expected.length);
  expect(listEquals(back, expected), isTrue);
  report('stream.randomChunks',
      '$chunks chunks, ${expected.length} bytes, $resizes resizes, ${sw.elapsedMilliseconds} ms');
  // resize 的确认走控制通道，可能比数据晚到：等它，而不是要求它和字节同步。
  await until(() => s.lastResize == lastAsked,
      timeout: const Duration(seconds: 5));
  report('stream.lastResize', '${s.lastResize} (asked $lastAsked)');
  await sub.cancel();

  // ③ 背压：订阅者暂停，一口气丢 3 MiB。宿主缓冲和输入积压必须有上限，恢复后一个字节不少、不乱。
  final s2 = await activeSession(e);
  final got2 = BytesBuilder();
  final sub2 = s2.output.listen(got2.add)..pause();
  final accepted = <int, Uint8List>{};
  var rejected = 0;
  final writes = <Future<void>>[];
  for (var i = 0; i < 48; i++) {
    final chunk = Uint8List.fromList(List.filled(64 * 1024, i));
    writes.add(() async {
      try {
        await s2.write(chunk);
        accepted[i] = chunk;
      } on PluginBridgeException catch (err) {
        if (err.code != 'INPUT_BACKLOG') rethrow;
        rejected++;
      }
    }());
  }
  await Future<void>.delayed(const Duration(seconds: 3));
  final stats = await s2.stats();
  report('stream.backpressure.stats', stats);
  report('stream.backpressure.dartBuffered', got2.length);
  report('stream.backpressure.rejectedSoFar', rejected);
  expect(stats!['outputChunksInFlight'] as int,
      lessThanOrEqualTo(stats['outputWindow'] as int));
  expect(stats['pendingInputBytes'] as int,
      lessThanOrEqualTo(stats['maxPendingInputBytes'] as int));
  expect(got2.length, 0);
  sub2.resume();
  await Future.wait(writes);
  final keys = accepted.keys.toList()..sort();
  final expected2 = BytesBuilder();
  for (final k in keys) {
    expected2.add(accepted[k]!);
  }
  final want = expected2.takeBytes();
  await until(() => got2.length >= want.length);
  expect(listEquals(got2.takeBytes(), want), isTrue);
  report('stream.backpressure',
      'accepted ${keys.length} x 64 KiB in order, rejected $rejected (INPUT_BACKLOG)');
  await sub2.cancel();

  // ④ 关闭：插件确认；重复关闭无副作用；关后写入被拒。
  await s.close();
  await s.close();
  await s2.close();
  report('stream.stopConfirmed', '${s.stopConfirmed} ${s2.stopConfirmed}');
  expect(s.stopConfirmed, isTrue);
  expect(() => s.write(Uint8List(1)), throwsStateError);
  await Future<void>.delayed(const Duration(seconds: 1));
  final fdAfterOne = fdCount();

  // ⑤ 连开连关 20 次：宿主这边的 FD 不随次数增长（socketpair、读写线程都释放了）。
  for (var i = 0; i < 20; i++) {
    final x = await activeSession(e);
    await roundTrip(x, 'cycle $i');
    await x.close();
    expect(x.stopConfirmed, isTrue);
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  final fdAfterCycles = fdCount();
  report('stream.fds',
      'start $fd0, after first close $fdAfterOne, after 20 more cycles $fdAfterCycles');
  expect(fdAfterCycles - fdAfterOne, lessThanOrEqualTo(1));
  await discovery.disconnect(echo);
}
