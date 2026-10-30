import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/app_log.dart';
import 'package:shun/application/auto_sync_controller.dart';
import 'package:shun/domain/log_scrub.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/sync/cloud_sync_service.dart';

// R26 F24：本机日志。崩溃、出错、同步写进来之前去敏；同一件事合并计数；保留 14 天、300 条。

class _Platform implements DiagnosticsPlatform {
  _Platform({this.crash, this.exits = const []});

  Map<Object?, Object?>? crash;
  List<Map<Object?, Object?>> exits;
  final asked = <int>[];

  @override
  Future<Map<Object?, Object?>?> takeJavaCrash() async {
    final taken = crash;
    crash = null;
    return taken;
  }

  @override
  Future<List<Map<Object?, Object?>>> exitReasons(int since) async {
    asked.add(since);
    return [
      for (final exit in exits)
        if ((exit['at'] as int) > since) exit
    ];
  }
}

void main() {
  group('scrubLogText', () {
    test('地址、登录名、令牌、URL 里的口令、私钥都换成记号', () {
      final out = scrubLogText(
        'SocketException: Connection refused (OS Error), address = 100.64.0.9, port = 22\n'
        'root@web.example.com via [fd7a:115c:a1e0::9] '
        'key tskey-client-kXYZ-abcdef123 Authorization: Bearer abcdefghijkl12345 '
        'https://alice:hunter2@dav.example.com/x?token=s3cr3t&x=1 password=pw-1 '
        'mail me@example.org\n'
        '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----',
      );
      for (final leak in [
        '100.64.0.9',
        'root@',
        'web.example.com',
        'fd7a:115c',
        'kXYZ',
        'abcdefghijkl12345',
        'hunter2',
        's3cr3t',
        'pw-1',
        'me@example.org',
        'AAAA',
      ]) {
        expect(out, isNot(contains(leak)), reason: leak);
      }
      expect(out, contains('<IP>'));
      expect(out, contains('tskey-<redacted>'));
      expect(out, contains('<private key redacted>'));
      expect(out, contains('port = 22'), reason: '端口、报错类型这些留着，不然没法查');
    });

    test('堆栈里的代码位置不当域名换；行号、时间不当 IPv6 换', () {
      const stack =
          '#0      SessionController.close (package:shun/application/session_controller.dart:2281:12)\n'
          'at io.flutter.embedding.engine.FlutterJNI.dispatch(FlutterJNI.java:1234)';
      expect(scrubLogText(stack, stack: true), stack);
      expect(scrubLogText('在 12:34:56 报错'), '在 12:34:56 报错');
      expect(scrubLogText('see app_log.dart'), 'see app_log.dart');
    });

    test('异常类名不当域名换；同样大写开头的用户主机名照样换', () {
      // 模拟器上 `am crash` 实测的第一行：类名换掉就只剩「<host>: shell-induced crash」。
      expect(
        scrubLogText('android.app.RemoteServiceException: shell-induced crash'),
        'android.app.RemoteServiceException: shell-induced crash',
      );
      expect(scrubLogText('java.io.IOException: closed'),
          'java.io.IOException: closed');
      expect(
          scrubLogText('ssh to MyServer.Local failed'), 'ssh to <host> failed');
      expect(scrubLogText('Corp.Example.Com refused'), '<host> refused');
    });
  });

  group('AppLog', () {
    late DateTime clock;
    late MemoryAppLogStore store;
    late AppLog log;

    setUp(() async {
      clock = DateTime(2026, 10, 30, 12);
      store = MemoryAppLogStore();
      log = AppLog(store, now: () => clock);
      await log.ready;
    });
    tearDown(() => log.dispose());

    AppLogEntry entry(String title, {Duration ago = Duration.zero}) =>
        AppLogEntry(
          at: clock.subtract(ago),
          kind: AppLogKind.error,
          title: title,
          detail: 'Bad state at 100.64.0.9',
        );

    test('写进去之前去敏；存盘的也是去敏后的', () async {
      log.record(entry('x'));
      await pumpEventQueue();
      expect(log.state.single.detail, 'Bad state at <IP>');
      expect(store.saved!.entries.single.detail, 'Bad state at <IP>');
    });

    test('同一件事 10 分钟内重复：合成一条、计数；隔久了另起一条', () {
      log.record(entry('x'));
      clock = clock.add(const Duration(minutes: 5));
      log.record(entry('x'));
      expect(log.state, hasLength(1));
      expect(log.state.single.count, 2);
      expect(log.state.single.at, clock, reason: '时间是最后一次');
      clock = clock.add(const Duration(minutes: 11));
      log.record(entry('x'));
      expect(log.state, hasLength(2));
      log.record(entry('y'));
      expect(log.state, hasLength(3), reason: '不一样的事不合并');
    });

    test('只留 14 天、最多 300 条，超了从最旧的删', () {
      final entries = [
        for (var i = 0; i < 320; i++)
          AppLogEntry(
            at: clock.subtract(Duration(minutes: i * 20)),
            kind: AppLogKind.sync,
            title: 'e$i',
          ),
        AppLogEntry(
          at: clock.subtract(const Duration(days: 15)),
          kind: AppLogKind.crash,
          title: 'old',
        ),
      ];
      final kept = pruneAppLog(entries, clock);
      expect(kept, hasLength(appLogLimit));
      expect(kept.any((e) => e.title == 'old'), isFalse);
      expect(kept.last.title, 'e0', reason: '旧的在前，最新的在最后');
      expect(kept.any((e) => e.title == 'e319'), isFalse, reason: '最旧的先删');
    });

    test('文件里已有的读回来，读的时候新记的接在后面', () async {
      final old = AppLogEntry(
        at: clock.subtract(const Duration(hours: 1)),
        kind: AppLogKind.crash,
        title: 'old',
      );
      final reopened = AppLog(
        MemoryAppLogStore(AppLogFile(entries: [old], exitsSeenUntil: 7)),
        now: () => clock,
      );
      reopened.record(entry('new'));
      await reopened.ready;
      expect(reopened.state.map((e) => e.title), ['old', 'new']);
      reopened.dispose();
    });

    test('开机收上次的 Java 崩溃和系统退出原因；不重复记、不记用户自己划掉的', () async {
      final crashAt = clock.subtract(const Duration(minutes: 30));
      final platform = _Platform(
        crash: {
          'at': crashAt.millisecondsSinceEpoch,
          'thread': 'main',
          'stack':
              'java.lang.IllegalStateException: boom at 10.0.0.5\n\tat top.xdwa.shun.MainActivity.onCreate(MainActivity.kt:42)',
        },
        exits: [
          // 同一次 Java 崩溃在系统记录里的那条：只有一句 crash，不重复记。
          {
            'at': crashAt.millisecondsSinceEpoch + 200,
            'reason': 4,
            'description': 'crash',
          },
          {
            'at':
                clock.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
            'reason': 6,
            'description': 'Input dispatching timed out',
            'trace': '"main" prio=5 tid=1 Blocked',
          },
          {
            'at':
                clock.subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
            'reason': 3,
            'description': null,
          },
          {
            'at':
                clock.subtract(const Duration(hours: 4)).millisecondsSinceEpoch,
            'reason': 10,
            'description': 'remove task',
          },
        ],
      );
      await log.collectPlatform(platform);
      final titles = log.state.map((e) => e.title).toList();
      expect(titles, [
        '内存不够，系统结束了 App',
        '长时间无响应（ANR），系统结束了 App',
        'App 崩溃（Java 层）',
      ]);
      final crash = log.state.last;
      expect(crash.kind, AppLogKind.crash);
      expect(crash.stack, contains('MainActivity.kt:42'));
      expect(crash.stack, isNot(contains('10.0.0.5')));
      expect(log.state[1].stack, contains('tid=1'), reason: 'ANR 的线程堆栈');
      expect(log.state.first.kind, AppLogKind.error, reason: '内存不够被杀不算崩溃');

      // 再启动一次：系统记录还在，但看过的不再记。
      await log.collectPlatform(platform);
      expect(log.state, hasLength(3));
      expect(platform.asked.last, crashAt.millisecondsSinceEpoch + 200);
      expect(store.saved!.exitsSeenUntil, crashAt.millisecondsSinceEpoch + 200);
    });

    test('清除只清条目，系统退出记录看到哪了留着（不然下次启动旧的又回来）', () async {
      final platform = _Platform(exits: [
        {
          'at': clock.millisecondsSinceEpoch,
          'reason': 5,
          'description': 'crash'
        },
      ]);
      await log.collectPlatform(platform);
      await log.clearAll();
      await log.collectPlatform(platform);
      expect(log.state, isEmpty);
    });

    test('Dart 里没人接的错误记成「出错」，再交给原来的处理', () {
      final previous = FlutterError.onError;
      final handled = <FlutterErrorDetails>[];
      FlutterError.onError = handled.add;
      addTearDown(() => FlutterError.onError = previous);
      installAppErrorCapture(log);
      FlutterError.reportError(FlutterErrorDetails(
        exception: StateError('lost route to 192.168.1.20'),
        stack: StackTrace.current,
      ));
      expect(handled, hasLength(1), reason: '原来的处理照样跑');
      final error = log.state.single;
      expect(error.kind, AppLogKind.error);
      expect(error.title, '界面出错（Flutter）');
      expect(error.detail, 'Bad state: lost route to <IP>');
      expect(error.stack, isNotNull);
    });
  });

  test('同步每一轮的结果交给日志：成功写结果，失败写报错', () async {
    final changes = StreamController<VaultData>.broadcast();
    final outcomes = <(bool, String)>[];
    var fail = false;
    final controller = AutoSyncController(
      localChanges: changes.stream,
      loadVault: () async => VaultData.empty(),
      synchronize: (vault) async {
        if (fail) throw StateError('WebDAV 401 at dav.example.com');
        return CloudSyncResult(
          vault: vault,
          message: '云端同步完成',
          versions: const CloudSyncVersions(
            localVersion: 1,
            cloudVersion: 1,
            baseVersion: 1,
            hasLocalChanges: false,
          ),
        );
      },
      applyVault: (_) async {},
      onOutcome: (ok, detail) => outcomes.add((ok, detail)),
      retryDelays: const [],
    );
    await controller.synchronizeNow();
    fail = true;
    await expectLater(controller.synchronizeNow(), throwsStateError);
    expect(outcomes, [
      (true, '云端同步完成'),
      (false, 'Bad state: WebDAV 401 at dav.example.com'),
    ]);

    final log = AppLog(MemoryAppLogStore());
    await log.ready;
    log.recordSync(ok: false, detail: outcomes.last.$2);
    expect(log.state.single.title, '同步失败');
    expect(log.state.single.detail, 'Bad state: WebDAV 401 at <host>');
    log.dispose();
    controller.dispose();
    await changes.close();
  });
}
