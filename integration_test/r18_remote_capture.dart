// R18 两个设备测试共用：用真实 App 页面连上 Docker 里的 OpenSSH，在远端逐字节收下 App 发出的东西。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/app.dart';
import 'package:netcatty_mobile/application/home_navigation.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/terminal_engine.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';

const r18Ssh = String.fromEnvironment('R17_SSH');

/// 只跑这个引擎（Ghostty / xterm2），空着两个都跑。
const r18Engine = String.fromEnvironment('R18_ENGINE');

void report(String key, Object? value) => debugPrint('R18 $key=$value');

/// 真实时钟下一帧一帧地等，最多 [timeout]。终端光标在闪，pumpAndSettle 等不到「静止」。
Future<void> waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String what = '条件',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 起真 App 页面（终端标签），用 [engine] 连上测试环境的边缘 sshd，返回会话和控制器。
Future<(ActiveTerminalSession, SessionController)> connectR18(
  WidgetTester tester,
  String engine,
) async {
  final config = jsonDecode(r18Ssh) as Map<String, dynamic>;
  final repository = await VaultRepository.open();
  final container = ProviderContainer(overrides: [
    vaultRepositoryProvider.overrideWithValue(repository),
    terminalAdapterFactoryProvider.overrideWithValue(
      engine == 'Ghostty'
          ? GhosttyTerminalAdapter.new
          : XtermTerminalAdapter.new,
    ),
  ]);
  addTearDown(container.dispose);
  final controller = container.read(sessionControllerProvider.notifier);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const NetcattyApp(),
  ));
  container.read(homeTabProvider.notifier).state = 1;
  final connected = controller.connect(
    HostProfile({
      'id': 'r18-$engine',
      'label': 'r18',
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
  await waitFor(tester, () => controller.state.sessions.isNotEmpty, what: '连上');
  expect(await connected, isTrue);
  final session = controller.state.sessions.single;
  await waitFor(tester, () => session.terminal.allText().trim().isNotEmpty,
      what: '提示符');
  return (session, controller);
}

var _captures = 0;

/// 远端什么时候停止收。
enum CaptureEnd {
  /// 留着 isig，靠最后到达的 Ctrl-C 结束（dd 包在接住 SIGINT 的子 shell 里：交互式 shell 看到前台命令
  /// 被 SIGINT 杀掉会放弃后面整串命令；noflsh 不让 Ctrl-C 清掉没读走的字）。
  ctrlC,

  /// Ctrl-C 也当数据收，收满 seconds 秒结束。
  timeout,

  /// 收到第一个回车后再收 3 秒结束（看回车后有没有多发的字），最多收 seconds 秒。真人在手机上输入时用。
  enter,
}

/// 远端逐字节收：raw 模式下退格、回车、控制字符原样到 dd。先打印就绪标记、等远端真开始收，
/// 再调 [act]（让主机按键、广播给回放输入法，或在页面上点快捷键栏），收完把字节读回来。
/// [prelude] 是收之前先执行的 shell 命令（比如在屏幕上打出给真人看的说明），要以分号结尾。
Future<List<int>> captureRemote(
  WidgetTester tester,
  TerminalSessionAdapter terminal,
  Future<void> Function() act, {
  CaptureEnd end = CaptureEnd.ctrlC,
  int seconds = 8,
  String prelude = '',
}) async {
  final n = 1000 + ++_captures;
  final mode = end == CaptureEnd.ctrlC ? 'isig noflsh' : '-isig';
  final read = switch (end) {
    CaptureEnd.ctrlC => '(trap : INT; dd bs=1 of=/tmp/r18.bin 2>/dev/null)',
    CaptureEnd.timeout =>
      'timeout $seconds dd bs=1 of=/tmp/r18.bin 2>/dev/null',
    // 非交互的 sh 里放到后台的 dd 不会被作业控制停住，但标准输入默认换成 /dev/null，所以显式接 /dev/tty。
    // 先清空文件：不然轮询会先看到上一次留下的回车，马上结束。
    CaptureEnd.enter => ': >/tmp/r18.bin; sh -c \''
        'timeout $seconds dd bs=1 of=/tmp/r18.bin </dev/tty 2>/dev/null & d=\$!; '
        'while kill -0 \$d 2>/dev/null; do '
        // 收到回车马上在屏幕上说一声：R18 真机复测时屏幕 3 秒没反应，所有者以为没按上，连按了好几下。
        'if [ -n "\$(tr -dc "\\r" </tmp/r18.bin)" ]; then '
        'printf "\\r\\n收到回车，3 秒后结束\\r\\n" >/dev/tty; sleep 3; kill \$d; fi; '
        'sleep 0.3; done\'',
  };
  // 标记用算术展开：回显的命令行里是 $((...))，只有输出里才是数字，不会被命令行本身误命中。
  terminal.sendText(
    '${prelude}echo R18R\$(($n)); stty raw -echo $mode; $read; stty sane; '
    'echo R18B\$(($n)); od -An -tx1 -v /tmp/r18.bin; echo R18E\$(($n))\r',
  );
  await waitFor(tester, () => terminal.allText().contains('R18R$n'),
      what: '远端就绪');
  await tester.pump(const Duration(milliseconds: 500));
  await act();
  await waitFor(tester, () => terminal.allText().contains('R18E$n'),
      timeout: Duration(seconds: seconds + 40), what: '远端收完');
  final text = terminal.allText();
  final body = text.substring(
      text.lastIndexOf('R18B$n') + 'R18B$n'.length, text.lastIndexOf('R18E$n'));
  return [
    for (final m in RegExp(r'\b[0-9a-f]{2}\b').allMatches(body))
      int.parse(m.group(0)!, radix: 16),
  ];
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// 按 PTY 行编辑的规矩还原远端看到的行：退格删一个字（码点），回车换行。
({List<String> lines, int deletes}) replay(List<int> bytes) {
  final lines = <String>[''];
  var deletes = 0;
  final pending = <int>[];
  void flush() {
    if (pending.isEmpty) return;
    lines.last += utf8.decode(pending, allowMalformed: true);
    pending.clear();
  }

  for (final byte in bytes) {
    if (byte == 0x7f) {
      flush();
      deletes++;
      final runes = lines.last.runes.toList();
      if (runes.isNotEmpty) {
        lines.last = String.fromCharCodes(runes.take(runes.length - 1));
      }
    } else if (byte == 0x0d) {
      flush();
      lines.add('');
    } else {
      pending.add(byte);
    }
  }
  flush();
  return (lines: lines, deletes: deletes);
}
