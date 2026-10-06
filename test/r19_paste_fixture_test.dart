import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/docker_fixture.dart';

// R19 / TER09、GST04、SEC10：粘贴在真实 OpenSSH + 真 bash（readline）上到底会不会执行。
// 用来核对预览里的说法：bracketed paste 开着时 bash 等回车；关着时前面各行粘贴即执行；
// 断线、恢复后不补发。依赖 tool/fixture-environment（镜像里要有 bash）；没起时整组 skip，证据里记 NOT_RUN。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = DockerFixture.load();
  final skip = fixture == null ? DockerFixture.skipReason : false;

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });

  HostProfile edgeHost() => HostProfile({
        'id': 'r19-edge',
        'label': 'edge',
        'hostname': fixture!.edgeHost,
        'port': fixture.edgePort,
        'username': fixture.user,
        'password': fixture.password,
        'authMethod': 'password',
        'protocol': 'ssh',
      });

  Future<bool> verify(HostProfile host, String algorithm, String fp) async =>
      fp == fixture!.edgeFingerprint;

  /// 独立于被测代码的检查通道：另开一条 dartssh2 连接到 ssh-edge 执行命令。
  Future<String> remote(String command) async {
    final f = fixture!;
    final client = SSHClient(
      await SSHSocket.connect(f.edgeHost, f.edgePort),
      username: f.user,
      onPasswordRequest: () => f.password,
      onVerifyHostKey: (_, fp) => utf8.decode(fp) == f.edgeFingerprint,
    );
    try {
      return utf8.decode(await client.run(command)).trim();
    } finally {
      client.close();
    }
  }

  Future<void> waitUntil(bool Function() condition,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('等待条件超时');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// 登录后换成 bash（登录 shell 是 busybox sh，不支持 bracketed paste），等提示符出来。
  Future<void> startBash(TerminalSessionAdapter terminal) async {
    await waitUntil(() => terminal.allText().trim().isNotEmpty);
    terminal.sendText("exec bash --norc --noprofile; PS1='r19\$ '\r");
    terminal.sendText('echo BASH-\$((40+2))\r');
    await waitUntil(() => terminal.allText().contains('BASH-42'));
  }

  Future<String> files(String pattern) =>
      remote('ls $pattern 2>/dev/null | xargs -n1 basename 2>/dev/null');

  final engines = <String, TerminalSessionAdapter Function()>{
    'Ghostty': GhosttyTerminalAdapter.new,
    'xterm2': XtermTerminalAdapter.new,
  };

  for (final MapEntry(key: engine, value: newTerminal) in engines.entries) {
    group('$engine 粘贴到真 bash', () {
      late TerminalSessionAdapter terminal;

      setUp(() async {
        if (fixture == null) return;
        await remote('rm -f ~/r19-*');
        terminal = newTerminal();
        final session = await SshService().connect(
          sessionId: 'r19',
          host: edgeHost(),
          verifyHostKey: verify,
          terminal: terminal,
        );
        addTearDown(() async {
          await session.close();
          terminal.dispose();
        });
        await startBash(terminal);
      });

      test('bracketed paste 开着（bash 默认）：多行进了输入行、没执行；用户按回车才执行', () async {
        await waitUntil(() => terminal.bracketedPasteMode);
        terminal.paste('touch ~/r19-a\ntouch ~/r19-b');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(await files('~/r19-*'), isEmpty, reason: 'bash 等着回车，没执行');

        terminal.sendText('\r');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(await files('~/r19-*'), 'r19-a\nr19-b');
      }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

      test('bracketed paste 关着：除了最后一行，前面各行粘贴即执行；最后一行等回车', () async {
        terminal.sendText("bind 'set enable-bracketed-paste off'\r");
        terminal.sendText('echo OFF-\$((40+3))\r');
        await waitUntil(() => terminal.allText().contains('OFF-43'));
        await waitUntil(() => !terminal.bracketedPasteMode);

        terminal.paste('touch ~/r19-c\ntouch ~/r19-d');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(await files('~/r19-*'), 'r19-c', reason: '第一行粘贴时就执行了');
        terminal.sendText('\x15'); // Ctrl-U 清掉还在输入行里的最后一行
      }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

      test('伪造的结束标记、Ctrl-C 被挡掉；但这只是清洗：粘贴的命令按回车照样执行', () async {
        await waitUntil(() => terminal.bracketedPasteMode);
        terminal.paste('touch ~/r19-e\x1b[201~\ntouch ~/r19-f\x03');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(await files('~/r19-*'), isEmpty, reason: '伪造的结束标记没能提前结束粘贴');
        terminal.sendText('\r');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(await files('~/r19-*'), contains('r19-e'),
            reason: '按了回车照样执行：粘贴清洗不等于不执行');
      }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
    });
  }

  test('断线：发不出去；恢复成新连接后不补发；旧目标再发也不行', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);
    await remote('rm -f ~/r19-*');
    await controller.connect(edgeHost(), verify);
    final old = controller.state.sessions.single;
    addTearDown(() async {
      for (final session in [...controller.state.sessions]) {
        await session.close();
      }
    });
    await startBash(old.terminal);

    // 只杀这条连接的 sshd 进程（bash 的父进程）：全量测试并行跑时，pkill 全部会把别的测试的会话一起断掉。
    old.terminal.sendText('echo PP-\$PPID-PP\r');
    await waitUntil(
        () => RegExp(r'PP-(\d+)-PP').hasMatch(old.terminal.allText()));
    final pid =
        RegExp(r'PP-(\d+)-PP').firstMatch(old.terminal.allText())!.group(1)!;
    final kill = await Process.run('docker', [
      'compose',
      '-f',
      'tool/fixture-environment/compose.yaml',
      'exec',
      '-T',
      'ssh-edge',
      'kill',
      '-KILL',
      pid,
    ]);
    expect(kill.exitCode, 0, reason: '${kill.stderr}');
    await waitUntil(() => !old.connected);
    expect(
      () => controller.pasteInto(old, 'touch ~/r19-lost', enter: true),
      throwsA(isA<TerminalTargetChangedException>()),
    );

    await controller.reconnectDisconnected();
    await waitUntil(() => controller.state.sessions
        .any((s) => s.id == old.id && s.connected && !identical(s, old)));
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(await files('~/r19-*'), isEmpty, reason: '恢复后没有补发断线时的粘贴');
    expect(
      () => controller.pasteInto(old, 'touch ~/r19-lost', enter: true),
      throwsA(isA<TerminalTargetChangedException>()
          .having((e) => e.problem, 'problem', TerminalTargetProblem.replaced)),
    );
  }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
}
