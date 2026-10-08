import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/domain/tmux/tmux_target.dart';
import 'package:netcatty_mobile/infrastructure/ssh/connection_platform_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/tmux/tmux_protocol.dart';
import 'package:netcatty_mobile/infrastructure/tmux/tmux_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/tmux_fixture.dart';

import 'support/test_terminal.dart';

// R21：真实 OpenSSH + 真实 tmux（2.4、2.7、3.0a、3.5a），外加没有 tmux、假 tmux 两台。
// 依赖 tool/tmux-fixture；没起时整组 skip，证据里记 NOT_RUN。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = TmuxFixture.load();
  final skip = fixture == null ? TmuxFixture.skipReason : false;
  const service = TmuxService(probeTimeout: Duration(seconds: 4));

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });

  Future<void> waitUntil(FutureOr<bool> Function() condition, String what,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) fail('等不到：$what');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// 被测查询用的连接（相当于终端标签自己的那条）。
  Future<SSHClient> appClient(String node, {String user = 'fixture'}) async {
    final client = await fixture!.client(node, user: user);
    addTearDown(client.close);
    return client;
  }

  Future<TmuxTarget> targetNamed(SSHClient client, String node, String name,
      {TmuxSocketSpec socket = const TmuxSocketSpec.standard()}) async {
    final probe = await service.probe(client, socket);
    expect(probe.availability, TmuxAvailability.ready, reason: probe.problem);
    final row = probe.sessions.singleWhere((value) => value.name == name);
    return targetOf(
      row,
      hostKey: '127.0.0.1:${fixture!.port(node)}',
      unixUser: probe.unixUser,
      uid: probe.uid!,
      socket: socket,
    );
  }

  group('TMX01 能力探测：版本、没有 tmux、非默认 socket、异常输出和超时', () {
    for (final node in TmuxFixture.realNodes) {
      test('$node：没有 server 时只读，不起 server、不建目录；有 server 时列表准确', () async {
        final f = fixture!;
        await f.reset(node);
        final client = await appClient(node);

        final empty =
            await service.probe(client, const TmuxSocketSpec.standard());
        expect(empty.availability, TmuxAvailability.noServer);
        expect(empty.versionLine, f.tmuxVersion(node));
        expect(empty.unixUser, 'fixture');
        expect(empty.uid, 1000);
        expect(empty.socketPath, '/tmp/tmux-1000/default');
        expect(
          await f.run(
              node, 'ls -d /tmp/tmux-1000 2>/dev/null; pgrep tmux; echo done'),
          'done',
          reason: '查询不得建 socket 目录、不得起 tmux server',
        );

        await f.run(
            node, 'tmux new-session -d -s alpha; tmux new-session -d -s beta');
        final probe =
            await service.probe(client, const TmuxSocketSpec.standard());
        expect(probe.availability, TmuxAvailability.ready,
            reason: probe.problem);
        expect(probe.sessions.map((s) => s.name).toSet(), {'alpha', 'beta'});
        expect(probe.sessions.map((s) => s.sessionId).toSet().length, 2);
        expect(probe.server!.pid,
            int.parse(await f.run(node, 'tmux display-message -p "#{pid}"')));
        expect(
            probe.sessions.every((s) => s.prefix == 'C-b' && !s.mouse), isTrue);
        expect(probe.skippedLines, 0);
        expect(probe.truncated, isFalse);
        await f.reset(node);
      }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
    }

    test('远端没有 tmux：如实报告，没有安装任何东西；普通 SSH 照常', () async {
      final client = await appClient('notmux');
      final probe =
          await service.probe(client, const TmuxSocketSpec.standard());
      expect(probe.availability, TmuxAvailability.missing);
      expect(probe.uid, 1000);
      expect(await fixture!.run('notmux', 'command -v tmux; echo ok'), 'ok');
    }, skip: skip);

    test('非默认 socket：-L 和 -S 各查各的 server，默认 socket 看不到它们', () async {
      final f = fixture!;
      await f.reset('tmux35');
      await f.run('tmux35',
          'tmux -L r21named new-session -d -s onnamed; tmux -S /tmp/r21-path.sock new-session -d -s onpath');
      final client = await appClient('tmux35');
      final standard =
          await service.probe(client, const TmuxSocketSpec.standard());
      expect(standard.availability, TmuxAvailability.noServer);
      final named =
          await service.probe(client, TmuxSocketSpec.named('r21named'));
      expect(named.sessions.single.name, 'onnamed');
      expect(named.socketPath, '/tmp/tmux-1000/r21named');
      final path = await service.probe(
          client, TmuxSocketSpec.path('/tmp/r21-path.sock'));
      expect(path.sessions.single.name, 'onpath');
      expect(path.server, isNot(named.server));
      await f.reset('tmux35');
    }, skip: skip);

    test('认不出或太老的版本：退回普通 SSH，不提供操作', () async {
      final f = fixture!;
      final client = await appClient('faketmux');
      for (final version in ['tmux 1.8', 'tmux openbsd-7.5', 'tmux master']) {
        await f.run('faketmux', 'echo "version $version" > ~/.faketmux');
        final probe =
            await service.probe(client, const TmuxSocketSpec.standard());
        expect(probe.availability, TmuxAvailability.unsupported,
            reason: version);
        expect(probe.canOperate, isFalse);
      }
      await f.run('faketmux', 'echo binary > ~/.faketmux');
      final binary =
          await service.probe(client, const TmuxSocketSpec.standard());
      expect(binary.versionLine, isNot(contains('\x1b')));
      expect(binary.versionLine, isNot(contains('\x07')));
      expect(binary.availability, TmuxAvailability.unsupported);
      await f.reset('faketmux');
    }, skip: skip);

    test('远端 tmux 卡住：按期限放弃，不一直等', () async {
      final f = fixture!;
      await f.run('faketmux', 'echo hang > ~/.faketmux');
      final client = await appClient('faketmux');
      final watch = Stopwatch()..start();
      await expectLater(
        service.probe(client, const TmuxSocketSpec.standard()),
        throwsA(isA<TmuxCommandException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 8)));
      await f.reset('faketmux');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));
  });

  group('TMX02 / SEC11 列表：恶意名字、同名、大量会话、坏输出', () {
    test('恶意名字只显示、从不执行；按 ID 结束也不执行', () async {
      final f = fixture!;
      await f.reset('tmux35');
      // `##` 在 tmux 格式里是字面的 `#`：这样建出来的名字就是「#(touch …)」本身。
      // 其余名字用 printf 生成，避开测试代码里的多层转义。
      await f.run(
        'tmux35',
        r'''tmux new-session -d -s "##(touch /tmp/r21-pwned)"; '''
            r'''tmux new-session -d -s "a;b"; '''
            r'''tmux new-session -d -s "$(printf "q\047uote")"; '''
            r'''tmux new-session -d -s "$(printf "x\042y")"; '''
            r'''tmux new-session -d -s "$(printf "\044(touch /tmp/r21-pwned2)")"; '''
            r'''tmux new-session -d -s "$(printf "t\tab\nnl")"; '''
            r'''tmux new-session -d -s "$(printf "\033]0;owned\007esc")"; '''
            r'''tmux new-session -d -s "中文会话"; '''
            r'''tmux new-session -d -s "$(head -c 300 /dev/zero | tr "\0" n)"''',
      );
      final client = await appClient('tmux35');
      final probe =
          await service.probe(client, const TmuxSocketSpec.standard());
      expect(probe.availability, TmuxAvailability.ready, reason: probe.problem);
      expect(probe.sessions, hasLength(9));
      final names = probe.sessions.map((s) => s.name).toList();
      expect(names, contains('#(touch /tmp/r21-pwned)'));
      expect(names, contains('a;b'));
      expect(names, contains("q'uote"));
      expect(names, contains('x"y'));
      expect(names, contains(r'$(touch /tmp/r21-pwned2)'));
      expect(names, contains('中文会话'));
      for (final name in names) {
        expect(name.runes.any((r) => r < 0x20 || r == 0x7f), isFalse,
            reason: '显示用的名字里不得有控制字符：$name');
        expect(name.length, lessThanOrEqualTo(201));
      }
      // 每个都按 ID 结束：恶意名字不进命令行，也就没有机会被 shell 或 tmux 执行。
      for (final row in probe.sessions) {
        await service.kill(
          client,
          targetOf(row,
              hostKey: '127.0.0.1:${f.port('tmux35')}',
              unixUser: 'fixture',
              uid: 1000,
              socket: const TmuxSocketSpec.standard()),
        );
      }
      expect(
        await f.run('tmux35',
            'ls /tmp/r21-pwned /tmp/r21-pwned2 2>/dev/null; tmux ls 2>/dev/null; echo end'),
        'end',
      );
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('两个 socket 上各有同名 session：按各自的 server 身份分开，不混为一个', () async {
      final f = fixture!;
      await f.reset('tmux30');
      await f.run('tmux30',
          'tmux new-session -d -s dup; tmux -L r21b new-session -d -s dup');
      final client = await appClient('tmux30');
      final a = await targetNamed(client, 'tmux30', 'dup');
      final b = await targetNamed(client, 'tmux30', 'dup',
          socket: TmuxSocketSpec.named('r21b'));
      expect(a.sessionId, b.sessionId, reason: r'两个 server 都从 $0 数起');
      expect(a.server, isNot(b.server));
      expect(a.sameAs(b), isFalse);
      await f.reset('tmux30');
    }, skip: skip);

    test('1200 个 session：只读前 1000 个、标出列表不全，耗时有界', () async {
      final f = fixture!;
      await f.reset('tmux35');
      await f.run('tmux35',
          r'i=0; while [ $i -lt 1200 ]; do tmux new-session -d -s "s$i"; i=$((i+1)); done');
      final client = await appClient('tmux35');
      final watch = Stopwatch()..start();
      final probe =
          await service.probe(client, const TmuxSocketSpec.standard());
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      expect(probe.availability, TmuxAvailability.ready, reason: probe.problem);
      expect(probe.sessions, hasLength(tmuxMaxSessions));
      expect(probe.truncated, isTrue);
      await f.reset('tmux35');
    }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

    test('server 开着但没有 session；socket 文件残留（server 已死）', () async {
      final f = fixture!;
      await f.reset('tmux35');
      await f.run('tmux35',
          'echo "set -g exit-empty off" > ~/.tmux.conf; tmux start-server');
      final client = await appClient('tmux35');
      final empty =
          await service.probe(client, const TmuxSocketSpec.standard());
      expect(empty.availability, TmuxAvailability.ready, reason: empty.problem);
      expect(empty.sessions, isEmpty);
      await f.run('tmux35', 'pkill -9 tmux; sleep 0.3; ls /tmp/tmux-1000');
      final stale =
          await service.probe(client, const TmuxSocketSpec.standard());
      expect(stale.availability, TmuxAvailability.noServer,
          reason: stale.problem);
      await f.reset('tmux35');
    }, skip: skip);

    test('坏输出：混进伪造的 server、坏行、转义序列和超长行时整表不可信，不提供操作', () async {
      final f = fixture!;
      await f.reset('faketmux');
      await f.run('faketmux',
          'tmux new-session -d -s real; echo garbage > ~/.faketmux');
      final client = await appClient('faketmux');
      final probe =
          await service.probe(client, const TmuxSocketSpec.standard());
      expect(probe.availability, TmuxAvailability.failed);
      expect(probe.canOperate, isFalse);
      expect(probe.problem, contains('不同的 server'));
      await f.reset('faketmux');
    }, skip: skip);

    test('20 MB 输出：读到上限就停，时间和内存都有界', () async {
      final f = fixture!;
      await f.reset('faketmux');
      await f.run(
          'faketmux', 'tmux new-session -d -s real; echo huge > ~/.faketmux');
      final client = await appClient('faketmux');
      final watch = Stopwatch()..start();
      final probe =
          await service.probe(client, const TmuxSocketSpec.standard());
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      expect(probe.availability, TmuxAvailability.failed,
          reason: '假数据每行同一个 ID，应判为不可信');
      expect(probe.sessions, isEmpty);
      await f.reset('faketmux');
    }, skip: skip);

    test('App 这边的字节上限：远端不截断也只读这么多', () async {
      final client = await appClient('tmux35');
      final result = await service.runBounded(
        client,
        'head -c 5000000 /dev/zero',
        timeout: const Duration(seconds: 5),
        maxBytes: 100000,
      );
      expect(result.truncated, isTrue);
      expect(result.output.length, 100000);
    }, skip: skip);

    test('tmux 报错：如实显示原因', () async {
      final f = fixture!;
      await f.reset('faketmux');
      await f.run(
          'faketmux', 'tmux new-session -d -s real; echo fail > ~/.faketmux');
      final client = await appClient('faketmux');
      final probe =
          await service.probe(client, const TmuxSocketSpec.standard());
      expect(probe.availability, TmuxAvailability.failed);
      expect(probe.problem, contains('server exited unexpectedly'));
      await f.reset('faketmux');
    }, skip: skip);
  });

  group('SEC11 显式操作：名字白名单、启动命令按字面、身份核对', () {
    test('不合规的名字在 App 这边就拒绝，远端什么都没建', () async {
      final f = fixture!;
      await f.reset('tmux35');
      final client = await appClient('tmux35');
      for (final name in [
        '#(touch /tmp/r21-pwned)',
        'a;b',
        "q'uote",
        'x"y',
        'tab\there',
        'new\nline',
        'with:colon',
        'with.dot',
        r'$(id)',
        'w*',
        'n' * 65,
        '',
      ]) {
        await expectLater(
          service.create(client,
              hostKey: 'h',
              unixUser: 'fixture',
              uid: 1000,
              socket: const TmuxSocketSpec.standard(),
              name: name),
          throwsA(isA<FormatException>()),
          reason: name,
        );
      }
      expect(
        await f.run('tmux35',
            'tmux ls >/dev/null 2>&1 && echo has-server; ls /tmp/r21-pwned >/dev/null 2>&1 && echo pwned; echo end'),
        'end',
      );
    }, skip: skip);

    test('启动命令按字面输入新 session 的 shell，不被 tmux 当键名、不经命令行', () async {
      final f = fixture!;
      await f.reset('tmux27');
      final client = await appClient('tmux27');
      final target = await service.create(
        client,
        hostKey: '127.0.0.1:${f.port('tmux27')}',
        unixUser: 'fixture',
        uid: 1000,
        socket: const TmuxSocketSpec.standard(),
        name: 'lit',
        startupCommand: r'''echo "a;b" '$(id)' Enter C-c > ~/r21-lit.txt''',
      );
      expect(target.sessionId, startsWith(r'$'));
      await waitUntil(
          () async => (await f.run('tmux27', 'cat ~/r21-lit.txt 2>/dev/null'))
              .isNotEmpty,
          '启动命令执行');
      expect(
          await f.run('tmux27', 'cat ~/r21-lit.txt'), r'a;b $(id) Enter C-c');
      await f.reset('tmux27');
    }, skip: skip);

    test('身份对不上（同名新 session）时拒绝结束，原有会话不动', () async {
      final f = fixture!;
      await f.reset('tmux35');
      await f.run(
          'tmux35', 'tmux new-session -d -s keep; tmux new-session -d -s work');
      final client = await appClient('tmux35');
      final work = await targetNamed(client, 'tmux35', 'work');
      // 结束原来的 work，再建一个同名的：ID 和创建时间都对不上原目标。
      await f.run(
          'tmux35', 'tmux kill-session -t work; tmux new-session -d -s work');
      await expectLater(
          service.kill(client, work), throwsA(isA<TmuxTargetGoneException>()));
      expect(await f.run('tmux35', 'tmux ls -F "#{session_name}" | sort'),
          'keep\nwork');
      await f.reset('tmux35');
    }, skip: skip);

    test('基座对照：按名字结束会落到前缀相同的别的会话上；按 Tab 拆的列表永远是空的', () async {
      final f = fixture!;
      await f.reset('tmux35');
      await f.run('tmux35',
          'tmux new-session -d -s work; tmux new-session -d -s workshop; tmux kill-session -t work');
      // 基座的 killTmuxSession 发的就是这条：work 已经不在时，tmux 按前缀找到 workshop 把它结束了。
      await f.run('tmux35', "tmux kill-session -t 'work'; true");
      expect(
          await f.run('tmux35', 'tmux ls 2>&1'), contains('no server running'));
      await f.run('tmux35', 'tmux new-session -d -s alpha');
      final raw = await f.run(
        'tmux35',
        "tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}\t#{session_activity}\t#{session_group}'",
      );
      // 基座的 parseTmuxSessions：按 Tab 拆，少于 5 段的行丢掉。tmux 把格式里的 Tab 换成了 _，一行都拆不出来。
      expect(raw, startsWith('alpha_'));
      expect(raw.split('\n').where((line) => line.split('\t').length >= 5),
          isEmpty);
      await f.reset('tmux35');
    }, skip: skip);
  });

  group('附着、恢复、分离（会话控制器 + 真实 tmux）', () {
    late ProviderContainer container;
    late SessionController controller;
    late _NoAutoRecovery platform;
    var disposed = false;

    setUp(() async {
      if (fixture == null) return;
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        // 这组测的是「断线后、服务器上先改了东西、再恢复」：断线当场的自动恢复（R22）会抢在改动之前
        // 把原目标附着回来。报「没有网络」让自动那一轮先不跑，恢复只由测试手动触发。
        connectionPlatformProvider
            .overrideWithValue(platform = _NoAutoRecovery()),
      ]);
      controller = container.read(sessionControllerProvider.notifier);
      disposed = false;
    });

    tearDown(() async {
      if (fixture == null || disposed) return;
      for (final session in [...controller.state.sessions]) {
        await session.close();
      }
      container.dispose();
    });

    Future<ActiveTerminalSession> shellTab(String node,
        {String user = 'fixture'}) async {
      expect(
        await controller.connect(
            fixture!.host(node, user: user), fixture.verify),
        isTrue,
      );
      return controller.state.sessions.last;
    }

    Future<ActiveTerminalSession> attachTab(
        ActiveTerminalSession parent, TmuxTarget target) async {
      expect(await controller.openTmuxTerminal(parent, target), isTrue);
      final tab = controller.state.sessions.last;
      expect(tab.tmux, isNotNull);
      expect(tab.tmux!.target.sameAs(target), isTrue);
      return tab;
    }

    Future<List<String>> clientsOf(String node, String sessionId) async {
      final raw = await fixture!.run(node,
          "tmux list-clients -t '$sessionId' -F '#{client_tty}:#{client_pid}' 2>/dev/null");
      return raw.isEmpty ? const [] : raw.split('\n');
    }

    String clientKey(ActiveTerminalSession tab) =>
        '${tab.tmux!.clientTty}:${tab.tmux!.clientPid}';

    /// 「电脑上开着的另一个 tmux 客户端」：不经被测代码，直接 dartssh2 带 PTY 附着。
    Future<SSHSession> externalClient(String node, String sessionId) async {
      final client = await fixture!.client(node);
      addTearDown(client.close);
      final session = await client.execute(
        "exec tmux attach-session -t '$sessionId'",
        pty: const SSHPtyConfig(width: 80, height: 24),
      );
      session.stdout.listen((_) {});
      session.stderr.listen((_) {});
      return session;
    }

    test('TMX03 两个客户端附着同一个目标，不踢掉对方；新建要显式操作', () async {
      final f = fixture!;
      await f.reset('tmux35');
      await f.run('tmux35', 'tmux new-session -d -s work');
      final parent = await shellTab('tmux35');
      final target = await targetNamed(parent.sshClient!, 'tmux35', 'work');
      await externalClient('tmux35', target.sessionId);
      await waitUntil(
          () async => (await clientsOf('tmux35', target.sessionId)).length == 1,
          '外部客户端附着');
      final tab = await attachTab(parent, target);
      await waitUntil(
          () async => (await clientsOf('tmux35', target.sessionId)).length == 2,
          '两个客户端都在');
      expect(await clientsOf('tmux35', target.sessionId),
          contains(clientKey(tab)));
      // 查询多少次都不会多出 session；只有显式 create 才会。
      for (var i = 0; i < 3; i++) {
        await service.probe(parent.sshClient!, const TmuxSocketSpec.standard());
      }
      expect(await f.run('tmux35', 'tmux ls -F "#{session_name}"'), 'work');
      await service.create(parent.sshClient!,
          hostKey: target.hostKey,
          unixUser: 'fixture',
          uid: 1000,
          socket: const TmuxSocketSpec.standard(),
          name: 'second');
      expect(await f.run('tmux35', 'tmux ls -F "#{session_name}" | sort'),
          'second\nwork');
      expect(await f.run('tmux35', 'tmux list-clients -t second | wc -l'), '0',
          reason: '新建只建不附着');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    for (final node in TmuxFixture.realNodes) {
      test('$node：附着后中文和窗口尺寸正确；断网恢复重新附着同一个目标', () async {
        final f = fixture!;
        await f.reset(node);
        await f.run(node, 'tmux new-session -d -s work');
        final parent = await shellTab(node);
        final target = await targetNamed(parent.sshClient!, node, 'work');
        final tab = await attachTab(parent, target);
        resizeTestTerminal(tab.terminal, 100, 30);
        await waitUntil(
            () async =>
                await f.run(node,
                    'tmux display -p -t work "#{client_width}x#{client_height}" 2>/dev/null') ==
                '100x30',
            '终端尺寸传到 tmux');
        controller.sendToSession(tab.id, 'echo 中文-ok\r');
        await waitUntil(
            () => tab.terminal.allText().contains('中文-ok'), '中文回显（tmux -u）');
        expect(tab.terminal.allText(), isNot(contains(tmuxAttachMarker)));

        await f.dropConnectionOf(node, tab.tmux!.clientPid);
        await waitUntil(() => !tab.connected, '断线被发现');
        expect(tab.autoRestoreBlocked, isFalse, reason: '断网不是用户分离，应等待恢复');
        await controller.reconnectDisconnected();
        final restored =
            controller.state.sessions.singleWhere((s) => s.id == tab.id);
        expect(identical(restored, tab), isFalse);
        expect(restored.connected, isTrue);
        expect(restored.tmux!.target.sameAs(target), isTrue);
        await waitUntil(
            () async => (await clientsOf(node, target.sessionId))
                .contains(clientKey(restored)),
            '恢复后附着的是原目标');
        expect(await f.run(node, 'tmux ls -F "#{session_name}"'), 'work',
            reason: '恢复不新建');
      }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
    }

    test('R22 网络在时断线：不用手动，自动恢复把原目标附着回来', () async {
      final f = fixture!;
      await f.reset('tmux35');
      await f.run('tmux35', 'tmux new-session -d -s work');
      platform.online();
      final parent = await shellTab('tmux35');
      final target = await targetNamed(parent.sshClient!, 'tmux35', 'work');
      final tab = await attachTab(parent, target);
      await f.dropConnectionOf('tmux35', tab.tmux!.clientPid);
      await waitUntil(() {
        final now =
            controller.state.sessions.singleWhere((s) => s.id == tab.id);
        return !identical(now, tab) && now.connected;
      }, '自动恢复');
      final restored =
          controller.state.sessions.singleWhere((s) => s.id == tab.id);
      expect(restored.tmux!.target.sameAs(target), isTrue);
      await waitUntil(
          () async => (await clientsOf('tmux35', target.sessionId))
              .contains(clientKey(restored)),
          '附着的是原目标');
      expect(await f.run('tmux35', 'tmux ls -F "#{session_name}"'), 'work',
          reason: '自动恢复也不新建');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('TMX04 断线后目标被删、重连前另建同名：说明旧目标不在，不附着、不新建', () async {
      final f = fixture!;
      await f.reset('tmux35');
      await f.run(
          'tmux35', 'tmux new-session -d -s keep; tmux new-session -d -s work');
      final parent = await shellTab('tmux35');
      final target = await targetNamed(parent.sshClient!, 'tmux35', 'work');
      final tab = await attachTab(parent, target);
      await f.dropConnectionOf('tmux35', tab.tmux!.clientPid);
      await waitUntil(() => !tab.connected, '断线被发现');
      await f.run(
          'tmux35', 'tmux kill-session -t work; tmux new-session -d -s work');

      await controller.reconnectDisconnected();
      expect(tab.autoRestoreBlocked, isTrue, reason: '目标不在了就停下等用户');
      expect(controller.state.sessions.singleWhere((s) => s.id == tab.id),
          same(tab));
      expect(tab.terminal.allText(), contains('原来的 tmux 会话已经不在了'));
      expect(
          await f.run('tmux35',
              'tmux ls -F "#{session_name}:#{session_attached}" | sort'),
          'keep:0\nwork:0',
          reason: '同名的新 work 没有被附着，也没有多建');
      // 后台维护再跑也不会去试。
      await controller.reconnectDisconnected();
      expect(tab.connected, isFalse);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test(r'TMX05 server 重启后 $0 被重用：不当成同一个会话', () async {
      final f = fixture!;
      await f.reset('tmux27');
      await f.run('tmux27', 'tmux new-session -d -s work');
      final parent = await shellTab('tmux27');
      final target = await targetNamed(parent.sshClient!, 'tmux27', 'work');
      expect(target.sessionId, r'$0');
      final tab = await attachTab(parent, target);
      await f.dropConnectionOf('tmux27', tab.tmux!.clientPid);
      await waitUntil(() => !tab.connected, '断线被发现');
      await f.run(
          'tmux27', 'tmux kill-server; sleep 1; tmux new-session -d -s work');
      expect(await f.run('tmux27', 'tmux display -p -t work "#{session_id}"'),
          r'$0');
      await controller.reconnectDisconnected();
      expect(tab.autoRestoreBlocked, isTrue);
      expect(await f.run('tmux27', 'tmux list-clients | wc -l'), '0');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('TMX05 换 Unix 用户、换 socket、换主机：都不附着', () async {
      final f = fixture!;
      await f.reset('tmux35');
      await f.run('tmux35', 'tmux new-session -d -s work');
      await f.run('tmux35', 'tmux new-session -d -s work', user: 'other');
      final parent = await shellTab('tmux35');
      final target = await targetNamed(parent.sshClient!, 'tmux35', 'work');

      // 同一台机器、另一个 Unix 用户登录的标签：远端 uid 对不上，不附着 other 自己的 work。
      final otherParent = await shellTab('tmux35', user: 'other');
      await expectLater(controller.openTmuxTerminal(otherParent, target),
          throwsA(isA<TmuxTargetGoneException>()));

      // 同一个用户、换个 socket：另一个 server 上恰好也有 $0。
      await f.run('tmux35', 'tmux -L r21other new-session -d -s work');
      final movedSocket = TmuxTarget(
        hostKey: target.hostKey,
        unixUser: target.unixUser,
        uid: target.uid,
        socket: TmuxSocketSpec.named('r21other'),
        server: target.server,
        sessionId: target.sessionId,
        sessionCreated: target.sessionCreated,
        displayName: target.displayName,
      );
      await expectLater(controller.openTmuxTerminal(parent, movedSocket),
          throwsA(isA<TmuxTargetGoneException>()));

      // 另一台主机：App 这边就拒绝，不连过去。
      final elsewhere = await shellTab('tmux30');
      expect(() => controller.openTmuxTerminal(elsewhere, target),
          throwsStateError);
      expect(
          await f.run('tmux35',
              'tmux list-clients | wc -l; tmux -L r21other list-clients | wc -l'),
          '0\n0');
      expect(await f.run('tmux35', 'tmux list-clients | wc -l', user: 'other'),
          '0');
      await f.reset('tmux35');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('TMX06 多个标签和外部客户端共用：只分离明确绑定的那个客户端；按键只到自己的会话', () async {
      final f = fixture!;
      await f.reset('tmux30');
      await f.run(
          'tmux30', 'tmux new-session -d -s s1; tmux new-session -d -s s2');
      final parent = await shellTab('tmux30');
      final s1 = await targetNamed(parent.sshClient!, 'tmux30', 's1');
      final s2 = await targetNamed(parent.sshClient!, 'tmux30', 's2');
      final a = await attachTab(parent, s1);
      final b = await attachTab(parent, s1);
      final c = await attachTab(parent, s2);
      await externalClient('tmux30', s1.sessionId);
      await waitUntil(
          () async => (await clientsOf('tmux30', s1.sessionId)).length == 3,
          's1 上三个客户端');

      // 标签 c 里按 prefix + c 新开窗口：只有 s2 多一个窗口。
      controller.sendToSession(c.id, '\x02c');
      await waitUntil(
          () async =>
              await f.run(
                  'tmux30', 'tmux display -p -t s2 "#{session_windows}"') ==
              '2',
          's2 多一个窗口');
      expect(
          await f.run('tmux30', 'tmux display -p -t s1 "#{session_windows}"'),
          '1');

      await service.detach(parent.sshClient!, a.tmux!);
      await waitUntil(() => !a.connected, '标签 a 的客户端退出');
      final left = await clientsOf('tmux30', s1.sessionId);
      expect(left, hasLength(2));
      expect(left, contains(clientKey(b)));
      expect(left, isNot(contains(clientKey(a))));
      expect(a.autoRestoreBlocked, isTrue, reason: '用户分离不是断线，不自动重新附着');
      expect(a.terminal.allText(), contains('tmux 客户端已退出'));

      // 已经不在的绑定、对不上 pid 的绑定：都不分离别人。
      await expectLater(service.detach(parent.sshClient!, a.tmux!),
          throwsA(isA<TmuxCommandException>()));
      await expectLater(
        service.detach(
          parent.sshClient!,
          TmuxClientBinding(
              target: s1, clientTty: b.tmux!.clientTty, clientPid: 1),
        ),
        throwsA(isA<TmuxCommandException>()),
      );
      expect(await clientsOf('tmux30', s1.sessionId), hasLength(2));
      expect(b.connected, isTrue);

      // 面板展开会话时的详情：按 ID 只读查询，能认出哪个客户端是本标签。
      final details = await service.details(parent.sshClient!, s1);
      expect(details.windows, hasLength(1));
      expect(details.clients.map((c) => '${c.tty}:${c.pid}'),
          contains(clientKey(b)));
      await f.run('tmux30', 'tmux kill-session -t s2');
      await expectLater(service.details(parent.sshClient!, s2),
          throwsA(isA<TmuxTargetGoneException>()));
      await f.reset('tmux30');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('TMX07 自定义 prefix、mouse 关：如实显示、附着不改；显式打开只作用于这个会话；copy-mode 下分离不发键',
        () async {
      final f = fixture!;
      await f.reset('tmux35');
      await f.run(
          'tmux35',
          r'printf "set -g prefix C-a\nunbind C-b\nbind C-a send-prefix\nset -g mouse off\n" > ~/.tmux.conf; '
              'tmux new-session -d -s m1; tmux new-session -d -s m2');
      final conf = await f.run('tmux35', 'md5sum ~/.tmux.conf');
      final parent = await shellTab('tmux35');
      var probe = await service.probe(
          parent.sshClient!, const TmuxSocketSpec.standard());
      expect(
          probe.sessions.every((s) => s.prefix == 'C-a' && !s.mouse), isTrue);
      final m1 = await targetNamed(parent.sshClient!, 'tmux35', 'm1');
      final tab = await attachTab(parent, m1);
      await waitUntil(
          () async => (await clientsOf('tmux35', m1.sessionId)).length == 1,
          '附着');
      probe = await service.probe(
          parent.sshClient!, const TmuxSocketSpec.standard());
      expect(probe.sessions.every((s) => !s.mouse), isTrue,
          reason: '基座附着时会顺手把 mouse 打开；现在附着不改任何选项');

      await service.setMouse(parent.sshClient!, m1, enable: true);
      probe = await service.probe(
          parent.sshClient!, const TmuxSocketSpec.standard());
      expect({for (final s in probe.sessions) s.name: s.mouse},
          {'m1': true, 'm2': false});
      expect(await f.run('tmux35', 'tmux show -gv mouse'), 'off');
      await service.setMouse(parent.sshClient!, m1, enable: false);
      probe = await service.probe(
          parent.sshClient!, const TmuxSocketSpec.standard());
      expect(probe.sessions.every((s) => !s.mouse), isTrue);
      expect(await f.run('tmux35', 'md5sum ~/.tmux.conf'), conf,
          reason: '不改 tmux.conf');

      // 自定义前缀下进 copy-mode，然后用 App 的分离：tmux 自己处理，不往 pane 里发任何键。
      controller.sendToSession(tab.id, '\x01[');
      await waitUntil(
          () async =>
              await f.run(
                  'tmux35', 'tmux display -p -t m1 "#{pane_in_mode}"') ==
              '1',
          '进入 copy-mode');
      await service.detach(parent.sshClient!, tab.tmux!);
      await waitUntil(() => !tab.connected, '分离');
      expect(await f.run('tmux35', 'tmux display -p -t m1 "#{pane_in_mode}"'),
          '1');
      expect(await f.run('tmux35', 'tmux ls -F "#{session_name}" | sort'),
          'm1\nm2');
      await f.reset('tmux35');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('TMX08 关标签、断网、分离、整个 App 停止：会话都在，pane 里没收到 Ctrl-C', () async {
      final f = fixture!;
      await f.reset('tmux24');
      // pane 里跑一个按字节记录输入的程序：raw 模式下 Ctrl-C 不会变成信号，而是记成 ^C。
      // 老 busybox 的 cat 没有 -v，用 dd bs=1：收到一个字节写一个字节，不缓冲。
      await f.run('tmux24',
          'tmux new-session -d -s rec "stty raw -echo; exec dd bs=1 of=\$HOME/r21-rec.log 2>/dev/null"');
      Future<List<int>> recorded() async {
        final hex = await f.run(
            'tmux24', 'od -An -tx1 ~/r21-rec.log 2>/dev/null | tr -d " \\n"');
        return [
          for (var i = 0; i + 1 < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ];
      }

      final parent = await shellTab('tmux24');
      final target = await targetNamed(parent.sshClient!, 'tmux24', 'rec');
      Future<void> stillAlive(String what) async {
        expect(
            await f.run('tmux24',
                'tmux ls -F "#{session_name}:#{pane_dead}" 2>&1; tmux display -p -t rec "#{pane_dead}" 2>&1'),
            'rec:0\n0',
            reason: what);
        expect(await recorded(), isNot(contains(0x03)), reason: what);
      }

      // 1. 关标签
      var tab = await attachTab(parent, target);
      // 等 tmux 客户端真的附着上再打字：附着前那一瞬间的按键可能被 tmux 启动时丢掉（归 R23）。
      await waitUntil(
          () async => (await clientsOf('tmux24', target.sessionId)).length == 1,
          '附着');
      controller.sendToSession(tab.id, 'typed');
      await waitUntil(
          () async => utf8.decode(await recorded()).contains('typed'),
          '输入到达 pane');
      await controller.close(controller.state.sessions.indexOf(tab));
      await waitUntil(
          () async => (await clientsOf('tmux24', target.sessionId)).isEmpty,
          '客户端退出');
      await stillAlive('关标签');

      // 2. 断网
      tab = await attachTab(parent, target);
      await f.dropConnectionOf('tmux24', tab.tmux!.clientPid);
      await waitUntil(() => !tab.connected, '断线');
      await stillAlive('断网');
      await controller.close(controller.state.sessions.indexOf(tab));

      // 3. 显式分离
      tab = await attachTab(parent, target);
      await service.detach(parent.sshClient!, tab.tmux!);
      await waitUntil(() => !tab.connected, '分离');
      await stillAlive('分离');
      await controller.close(controller.state.sessions.indexOf(tab));

      // 4. 整个 App 停止（会话控制器销毁）
      tab = await attachTab(parent, target);
      await waitUntil(
          () async => (await clientsOf('tmux24', target.sessionId)).length == 1,
          '附着');
      container.dispose();
      disposed = true;
      await waitUntil(
          () async => (await clientsOf('tmux24', target.sessionId)).isEmpty,
          '客户端退出');
      await stillAlive('App 停止');
      expect(utf8.decode(await recorded()), 'typed',
          reason: '四种离开方式都没有往 pane 里发任何字节');
      await f.reset('tmux24');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));
  });
}

class _NoAutoRecovery extends NoConnectionPlatform {
  final _events = StreamController<ConnectionPlatformEvent>.broadcast();

  /// 报「网络回来了」：之后断线就照常当场自动恢复。
  void online() => _events.add(const NetworkChanged(
      NetworkStatus(available: true, id: 'test', transports: {'wifi'})));

  @override
  Stream<ConnectionPlatformEvent> get events => _events.stream;

  @override
  Future<NetworkStatus> currentNetwork() async =>
      const NetworkStatus(available: false);
}
