// R20 设备门禁：Ghostty 成为唯一引擎后，在真 Android 上跑真实全屏程序、量资源、跑 AI CLI 的交互界面。
//
// 这不是 CI 测试。要本机的 Docker 测试环境和一台模拟器，经 tool/r20-gate.sh 跑（转发端口、预授权通知、截图）：
//   (cd tool/fixture-environment && ./up.sh)
//   (cd tool/ai-cli-fixture && ./up.sh)        # 只有 ai-cli 场景要
//   tool/r20-gate.sh emulator-5580 tui         # 或 resources、ai-cli
// 输出以 "R20 " 开头的行作为证据，也进 logcat。截图在脚本打印的目录里。
//
// - tui（TER03 + 「CJK/全屏/协议回应无关键错误」）：App 里用 Ghostty 直接跑 vim、less、htop；远端同时起一个
//   **同尺寸**的后台 tmux 跑同一条命令、按同样的键，拿 tmux 自己的 capture-pane 当裁判，逐行比屏幕上的字。
//   再在 App 里开 tmux 客户端、左右分屏，各窗格和 capture-pane 比。最后核对退出全屏后主屏上原来的字还在。
// - resources（TER11）：4 个标签各吃 1.25 MiB 中文+颜色输出，再开关 100 次标签，量本进程的 RSS、PSS、fd、线程；
//   顺带量按键到远端回显的时间、50 次收起/叫出系统键盘。
// - ai-cli（TER13）：Claude Code、Codex CLI 不登录就有的界面（选主题、选登录方式），方向键、回车、Ctrl+C。
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:netcatty_mobile/app.dart';
import 'package:netcatty_mobile/application/home_navigation.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';

const _scenario = String.fromEnvironment('R20_SCENARIO');
const _ssh = String.fromEnvironment('R17_SSH');
const _aiCli = String.fromEnvironment('R20_AI_CLI');
const _shots = bool.fromEnvironment('R20_SHOTS');

void r20(String key, Object? value) => debugPrint('R20 $key=$value');

/// 截图：打出 "R20 SHOT=<名字>" 后停 2.5 秒，让电脑那边用 adb screencap 截下这个画面。
Future<void> shot(WidgetTester tester, String name) async {
  if (!_shots) return;
  debugPrint('R20 SHOT=$name');
  await settle(tester, 2500);
}

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

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

late ProviderContainer _container;

/// 起真 App（终端页），返回会话控制器。引擎走生产的默认（R20 起只有 Ghostty），不 override。
Future<SessionController> startApp(WidgetTester tester) async {
  final repository = await VaultRepository.open();
  _container = ProviderContainer(overrides: [
    vaultRepositoryProvider.overrideWithValue(repository),
  ]);
  addTearDown(_container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: _container,
    child: const NetcattyApp(),
  ));
  _container.read(homeTabProvider.notifier).state = 1;
  await settle(tester);
  return _container.read(sessionControllerProvider.notifier);
}

var _tabs = 0;

/// 新开一个标签连 [config] 指的 sshd，等到出提示符。
Future<ActiveTerminalSession> openTab(
  WidgetTester tester,
  SessionController controller,
  Map<String, dynamic> config,
) async {
  final before = controller.state.sessions.length;
  final connected = controller.connect(
    HostProfile({
      'id': 'r20-${++_tabs}',
      'label': 'r20-$_tabs',
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
  await waitFor(tester, () => controller.state.sessions.length > before,
      what: '连上');
  expect(await connected, isTrue);
  final session = controller.state.sessions.last;
  await waitFor(tester, () => session.terminal.allText().trim().isNotEmpty,
      what: '提示符');
  return session;
}

var _runs = 0;

/// 在远端 shell 里跑 [command]，等它跑完（标记用算术展开：回显的命令行里是算式，只有输出里才是数字）。
Future<void> run(
  WidgetTester tester,
  TerminalSessionAdapter terminal,
  String command, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final n = 3000 + ++_runs;
  terminal.sendText('$command; echo R20D\$(($n))\r');
  await waitFor(tester, () => terminal.allText().contains('R20D$n'),
      timeout: timeout, what: command);
  await settle(tester, 200);
}

/// 另开 exec 通道跑命令，原样拿回输出（不 trim：capture-pane 的行首空格、空行都要留着）。
Future<String> exec(ActiveTerminalSession session, String command) async =>
    utf8.decode(await session.sshClient!.run(command), allowMalformed: true);

/// 屏幕上现在看得见的每一行（去掉行尾空格）。
List<String> screen(TerminalSessionAdapter terminal) => [
      for (final line in terminal.recentLines(terminal.viewRows))
        line.text.trimRight(),
    ];

List<String> _normalize(String capture, int rows) {
  final lines = capture.split('\n').map((l) => l.trimRight()).toList();
  while (lines.length > rows) {
    lines.removeLast();
  }
  while (lines.length < rows) {
    lines.add('');
  }
  return lines;
}

/// 两边逐行比，返回不一样的行（「行号：Ghostty | tmux」），一样就是空的。
List<String> diff(List<String> ghostty, List<String> oracle) => [
      for (var i = 0; i < oracle.length; i++)
        if ((i < ghostty.length ? ghostty[i] : '') != oracle[i])
          '$i: ${i < ghostty.length ? ghostty[i] : '<无>'} | ${oracle[i]}',
    ];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  final ssh = _ssh.isEmpty ? null : jsonDecode(_ssh) as Map<String, dynamic>;

  testWidgets('tui：vim、less、htop、tmux 客户端在真 PTY 上，Ghostty 的屏幕和 tmux 裁判逐行一样',
      (tester) async {
    final controller = await startApp(tester);
    final session = await openTab(tester, controller, ssh!);
    final terminal = session.terminal;
    r20('engine', terminal.engine);
    r20('platform', Platform.operatingSystemVersion);

    // 素材：中文、emoji、宽窄混排、超长行，base64 传过去免得引号出事。
    String file(String name, String text) =>
        'echo ${base64.encode(utf8.encode(text))} | base64 -d > /tmp/r20/$name';
    await exec(
        session,
        [
          'rm -rf /tmp/r20; mkdir -p /tmp/r20',
          file('demo.py', _demoPy),
          file('long.txt', _longTxt()),
          file('o.conf',
              'set -g default-terminal "xterm-256color"\nset -g status off\nset -s escape-time 0\n'),
          file('c.conf',
              'set -s escape-time 0\nset -g status-left "[c] "\nset -g status-right "R20"\nset -g status-interval 0\nset -g automatic-rename off\n'),
        ].join('; '));

    // 主屏上先放一段字：全屏程序退出后它还要在（TER03）。
    await run(tester, terminal, "clear; printf 'r20-main-%s\\n' 1 2 3");
    // 连上后系统键盘弹起，终端行数跟着变（动画十几帧，尺寸合并后才发给远端）：等远端的行列和屏幕对上再开始。
    var rows = 0, cols = 0;
    final sizeDeadline = DateTime.now().add(const Duration(seconds: 6));
    while (true) {
      await settle(tester, 500);
      await run(tester, terminal, 'stty size > /tmp/r20/size');
      final size = (await exec(session, 'cat /tmp/r20/size')).trim().split(' ');
      rows = int.parse(size[0]);
      cols = int.parse(size[1]);
      if (rows == terminal.viewRows || DateTime.now().isAfter(sizeDeadline)) {
        break;
      }
    }
    r20('size', '${cols}x$rows viewRows=${terminal.viewRows}');
    expect(rows, terminal.viewRows, reason: '远端 PTY 的行数就是屏幕上看得见的行数');

    final failures = <String>[];
    const env = 'export LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=xterm-256color';
    const oracle = 'tmux -u -L r20o -f /tmp/r20/o.conf';

    /// 同一条命令：App 里直接跑（Ghostty），远端后台再起一个同尺寸的 tmux 跑一份当裁判。
    /// 命令先写进脚本，两边跑同一个脚本：命令里的单引号（vim -c '…'）不会和 tmux 那层引号打架。
    Future<void> start(String command) async {
      await exec(
          session,
          '${file('cmd.sh', '$env\nexec $command\n')}; '
          '$env; $oracle kill-server 2>/dev/null; '
          "$oracle new-session -d -s o -x $cols -y $rows 'sh /tmp/r20/cmd.sh'");
      terminal.sendText('sh /tmp/r20/cmd.sh\r');
    }

    /// 同样的键两边各按一次。[app] 发给 App 的终端（走真实的输入编码），[tmux] 是 send-keys 的写法。
    Future<void> keys(void Function() app, String tmux) async {
      app();
      await exec(session, '$oracle send-keys -t o $tmux');
    }

    /// 比到一样为止（程序重画要一点时间），最多等 8 秒；还不一样就记下差的行。
    Future<void> checkpoint(String name) async {
      var last = <String>[];
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (true) {
        await settle(tester, 300);
        final expected = _normalize(
            await exec(session, '$oracle capture-pane -p -t o'), rows);
        last = diff(screen(terminal), expected);
        if (last.isEmpty || DateTime.now().isAfter(deadline)) break;
      }
      r20('tui.$name', last.isEmpty ? 'same' : 'DIFF ${jsonEncode(last)}');
      if (last.isNotEmpty) failures.add(name);
      await shot(tester, 'tui-$name');
    }

    void key(TerminalSpecialKey k) => terminal.sendKey(k);
    void text(String s) => terminal.sendText(s);

    // vim：语法色、行号、中文、竖分屏、搜索高亮、插入 emoji。
    await start("vim -N -n -u NONE -i NONE -c 'syntax on' "
        "-c 'set encoding=utf-8 number hlsearch laststatus=2 ruler' /tmp/r20/demo.py");
    await waitFor(tester, () => terminal.isAlternateScreen, what: 'vim 进备用屏');
    await checkpoint('vim-open');
    await keys(() => text(':vsplit /tmp/r20/long.txt\r'),
        "':vsplit /tmp/r20/long.txt' Enter");
    await checkpoint('vim-vsplit');
    await keys(() => text('/中文\r'), "'/中文' Enter");
    await checkpoint('vim-search');
    await keys(
        () => text('Go新增一行：emoji 🙂 和全角（）ok'), "G o '新增一行：emoji 🙂 和全角（）ok'");
    await keys(() => key(TerminalSpecialKey.escape), 'Escape');
    await checkpoint('vim-insert');
    await keys(() => text(':qa!\r'), "':qa!' Enter");
    await waitFor(tester, () => !terminal.isAlternateScreen, what: 'vim 退出备用屏');

    // less：中文长行折行、翻页、搜索。
    await start('less -R /tmp/r20/long.txt');
    await waitFor(tester, () => terminal.isAlternateScreen, what: 'less 进备用屏');
    await checkpoint('less-open');
    await keys(() => text(' '), 'Space');
    await checkpoint('less-page2');
    await keys(() => text('/第150行\r'), "'/第150行' Enter");
    await checkpoint('less-search');
    await keys(() => text('q'), 'q');
    await waitFor(tester, () => !terminal.isAlternateScreen, what: 'less 退出');

    // htop：-d 100 每 10 秒才刷新一次，两边比得上；树形、设置页。
    await start('htop -d 100');
    await waitFor(tester, () => terminal.isAlternateScreen, what: 'htop 进备用屏');
    await settle(tester, 1500);
    // htop 的 CPU、内存、时间两边不可能一样（两个进程、不同时刻），只比固定的字：底下一行功能键和表头。
    Future<void> htopCheck(String name) async {
      await settle(tester, 1200);
      final expected =
          _normalize(await exec(session, '$oracle capture-pane -p -t o'), rows);
      final mine = screen(terminal);
      final bottomSame = mine.last == expected.last;
      // 表头：树形、排序时 PID 和 USER 之间是排序标记（PID△USER），不一定是空格。
      final header = RegExp(r'^\s*PID.?USER');
      final mineHeader = mine.indexWhere(header.hasMatch);
      final oracleHeader = expected.indexWhere(header.hasMatch);
      final headerSame = mineHeader >= 0 &&
          mineHeader == oracleHeader &&
          mine[mineHeader] == expected[oracleHeader];
      r20(
          'tui.$name',
          'bottom=${bottomSame ? 'same' : jsonEncode([
                      mine.last,
                      expected.last
                    ])} '
              'header=${headerSame ? 'same@$mineHeader' : jsonEncode([
                      mineHeader,
                      oracleHeader
                    ])}');
      if (!bottomSame || !headerSame) failures.add(name);
      await shot(tester, 'tui-$name');
    }

    await htopCheck('htop-open');
    await keys(() => text('t'), 't');
    await htopCheck('htop-tree');
    await keys(() => text('q'), 'q');
    await waitFor(tester, () => !terminal.isAlternateScreen, what: 'htop 退出');
    await exec(session, '$oracle kill-server 2>/dev/null');

    // tmux 客户端开在 App 里：左右分屏，一边中文 printf，一边 seq；每个窗格和 tmux 自己的 capture-pane 比，
    // 最后一行是状态栏（写死了，不随时间变）。
    const client = 'tmux -u -L r20c -f /tmp/r20/c.conf';
    terminal.sendText('$env; $client new-session -s c\r');
    await waitFor(tester, () => terminal.isAlternateScreen, what: 'tmux 进备用屏');
    await settle(tester, 1000);
    await exec(
        session,
        '$client split-window -h -t c; '
        "$client send-keys -t c:0.0 \"printf '中文测试 %s\\\\n' 一 二 三 🙂\" Enter; "
        "$client send-keys -t c:0.1 'seq 1 60' Enter");
    await settle(tester, 1500);
    Future<void> paneCheck(String name) async {
      final panes = (await exec(session,
              "$client list-panes -t c -F '#{pane_index} #{pane_left} #{pane_top} #{pane_width} #{pane_height}'"))
          .trim()
          .split('\n');
      final mine = screen(terminal);
      for (final pane in panes) {
        final [index, left, top, width, height] =
            pane.split(' ').map(int.parse).toList();
        final expected = _normalize(
            await exec(session, '$client capture-pane -p -t c:0.$index'),
            height);
        final region = [
          for (var r = top; r < top + height; r++)
            _cells(mine[r], left, width).trimRight(),
        ];
        final d = diff(region, expected);
        r20('tui.$name.pane$index',
            d.isEmpty ? 'same' : 'DIFF ${jsonEncode(d)}');
        if (d.isNotEmpty) failures.add('$name.pane$index');
      }
      final status = mine.last;
      r20('tui.$name.status', jsonEncode(status));
      if (!status.startsWith('[c] ') || !status.endsWith('R20')) {
        failures.add('$name.status');
      }
      await shot(tester, 'tui-$name');
    }

    await paneCheck('tmux-split');
    await exec(session, '$client kill-server');
    await waitFor(tester, () => !terminal.isAlternateScreen, what: 'tmux 退出');

    // TER03：全屏程序都退出了，主屏上原来那几行还在，备用屏的东西没漏到主屏，之后的输出接在下面。
    await run(tester, terminal, 'echo r20-after');
    final text_ = terminal.allText();
    final mainKept =
        ['r20-main-1', 'r20-main-2', 'r20-main-3'].every(text_.contains);
    final leaked = text_.contains('新增一行') || text_.contains('PID USER');
    r20('tui.ter03', 'mainKept=$mainKept altLeaked=$leaked');
    if (!mainKept || leaked) failures.add('ter03');

    await controller.close(0);
    await settle(tester, 300);
    expect(failures, isEmpty, reason: '不一样的：$failures');
  },
      skip: _scenario != 'tui' || ssh == null,
      timeout: const Timeout(Duration(minutes: 8)));

  testWidgets(
      'resources：4 个标签各吃 0.9 MiB、再开关 500 次，进程的 RSS/PSS/fd/线程不持续涨，连 SSH 的 socket 全关后一个不剩',
      (tester) async {
    final controller = await startApp(tester);
    final baseline = _usage();
    final baselineFds = _fdKinds();
    r20('res.start', baseline);
    r20('res.startFds', baselineFds);
    await meminfo(tester, 'start');

    final tabs = <ActiveTerminalSession>[];
    for (var i = 0; i < 4; i++) {
      tabs.add(await openTab(tester, controller, ssh!));
    }
    // 固定负载：每个标签 20000 行中文 + 8 色 + emoji，约 0.9 MiB，4 个一共约 3.6 MiB。单个标签吃 4.9 MB 的背压在 TER10（R17）。
    await exec(
            tabs.first,
            r"""awk 'BEGIN{for(i=0;i<20000;i++) printf "\033[3%dm第%05d行 中文输出 🙂 abc\033[0m %s\n", i%8, i, (i%3?"":"尾巴")}' > /tmp/r20-load.txt; """
            'head -c 65536 /tmp/r20-load.txt > /tmp/r20-small.txt; wc -c /tmp/r20-load.txt')
        .then((out) => r20('res.loadBytes', out.trim()));
    final watch = Stopwatch()..start();
    for (var i = 0; i < tabs.length; i++) {
      controller.activate(i);
      await run(tester, tabs[i].terminal, 'cat /tmp/r20-load.txt',
          timeout: const Duration(seconds: 120));
    }
    r20('res.load4TabsMs', watch.elapsedMilliseconds);
    await shot(tester, 'res-4tabs');
    final loaded = _usage();
    r20('res.after4Tabs', loaded);
    r20('res.after4TabsFds', _fdKinds());

    // 输入到远端回显：cat 开着，tty 自己回显，每个字从交给终端（和快捷键栏、按键面板同一个入口）到出现在屏幕上，
    // 含 adb 转发、Docker 网络、sshd 的来回。硬件按键从扫描码到远端那一段由 r18_keys_test 的真实扫描码测。
    controller.activate(0);
    await settle(tester, 500);
    final echoTerminal = tabs.first.terminal;
    echoTerminal.sendText('clear; cat > /dev/null\r');
    await settle(tester, 800);
    final latencies = <int>[];
    // 只数屏幕上看得见的那几行里的 x：监听里调 allText 要把 5000 行滚动区格式化一遍，会把延迟量大。
    int xs() => screen(echoTerminal).join().split('x').length;
    // 直接轮询屏幕（每 2 ms 一次），不靠适配器的监听：它只在模式、选区这类状态变时通知，远端写进来的字不一定触发。
    for (var i = 0; i < 50; i++) {
      final before = xs();
      final stopwatch = Stopwatch()..start();
      echoTerminal.sendText('x');
      var seen = -1;
      while (seen < 0 && stopwatch.elapsedMilliseconds < 5000) {
        await tester.pump(const Duration(milliseconds: 2));
        if (xs() > before) seen = stopwatch.elapsedMicroseconds;
      }
      if (seen >= 0) latencies.add(seen);
      await tester.pump(const Duration(milliseconds: 30));
    }
    echoTerminal.sendText('\x03');
    expect(latencies, isNotEmpty, reason: '一个回显都没等到');
    latencies.sort();
    int pct(double p) => latencies[(p * (latencies.length - 1)).round()];
    r20('res.echoMs',
        'n=${latencies.length} p50=${(pct(.5) / 1000).toStringAsFixed(1)} p95=${(pct(.95) / 1000).toStringAsFixed(1)} max=${(latencies.last / 1000).toStringAsFixed(1)}');
    expect(latencies, hasLength(50), reason: '每个键都要回显');

    // 500 次：新开一个标签、吃 64 KiB、关掉，每 20 次量一次。前 100 次当热身（Dart 堆、字形缓存、原生分配器会先长到
    // 一个台阶），按 100–500 次的斜率判有没有「每开关一次就漏一点」：两个点相减分不清一次性的台阶和持续增长
    // （第一次跑 100 次时，第 30→40 次 RSS 跳了约 18 MiB、之后在同一高度来回，单看第 20、100 次就是 +18.9 MiB）。
    final samples = <int, Map<String, int>>{};
    final profiles = <int, _HeapProfile>{};
    for (var cycle = 1; cycle <= 500; cycle++) {
      final tab = await openTab(tester, controller, ssh!);
      await run(tester, tab.terminal, 'cat /tmp/r20-small.txt');
      await controller.close(controller.state.sessions.indexOf(tab));
      await settle(tester, 150);
      if (cycle % 20 == 0) {
        samples[cycle] = _usage();
        r20('res.cycle$cycle', samples[cycle]);
      }
      if (cycle == 100 || cycle == 500) {
        await meminfo(tester, 'cycle$cycle');
        profiles[cycle] = await _heapAfterGc();
        r20('res.heap$cycle', profiles[cycle]!.summary);
      }
    }
    r20('res.cycle500Fds', _fdKinds());
    await shot(tester, 'res-after500');
    final s20 = samples[20]!;
    final s100 = samples[100]!;
    final s300 = samples[500]!;
    // 最小二乘斜率：每开关一次涨多少。
    double slope(String key) {
      final points = [
        for (final MapEntry(key: c, value: v) in samples.entries)
          if (c >= 100) (c.toDouble(), v[key]!.toDouble()),
      ];
      final mx =
          points.map((p) => p.$1).reduce((a, b) => a + b) / points.length;
      final my =
          points.map((p) => p.$2).reduce((a, b) => a + b) / points.length;
      var num = 0.0, den = 0.0;
      for (final (x, y) in points) {
        num += (x - mx) * (y - my);
        den += (x - mx) * (x - mx);
      }
      return num / den;
    }

    final rssSlope = slope('rssKiB') / 1024;
    final pssSlope = slope('pssKiB') / 1024;
    final fdSlope = slope('fd');
    final threadSlope = slope('threads');
    r20(
        'res.growth20to100',
        'rss=${((s100['rssKiB']! - s20['rssKiB']!) / 1024).toStringAsFixed(1)}MiB '
            'pss=${((s100['pssKiB']! - s20['pssKiB']!) / 1024).toStringAsFixed(1)}MiB');
    // 强制 GC 之后还活着的对象：哪些类的实例数随开关次数涨（关掉的标签还被谁拿着）。
    final grew = profiles[500]!.instancesGrownSince(profiles[100]!);
    r20('res.heapGrowth100to500', jsonEncode(grew));
    r20(
        'res.growth100to500',
        'rss=${((s300['rssKiB']! - s100['rssKiB']!) / 1024).toStringAsFixed(1)}MiB '
            'pss=${((s300['pssKiB']! - s100['pssKiB']!) / 1024).toStringAsFixed(1)}MiB '
            'fd=${s300['fd']! - s100['fd']!} threads=${s300['threads']! - s100['threads']!}');
    r20(
        'res.slope100to500PerCycle',
        'rss=${(rssSlope * 1024).toStringAsFixed(1)}KiB pss=${(pssSlope * 1024).toStringAsFixed(1)}KiB '
            'fd=${fdSlope.toStringAsFixed(3)} threads=${threadSlope.toStringAsFixed(3)}');

    // 50 次收起/叫出系统键盘（R04 冻结的测法），前后各量一次。
    controller.activate(0);
    await settle(tester, 500);
    final beforeKeyboard = _usage();
    var shown = 0;
    for (var i = 0; i < 50; i++) {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await settle(tester, 250);
      await tester.tapAt(tester.getCenter(find.byType(Scaffold).first));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (tester.view.viewInsets.bottom == 0 &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      if (tester.view.viewInsets.bottom > 0) shown++;
    }
    final afterKeyboard = _usage();
    r20(
        'res.keyboard50',
        'shown=$shown/50 pssDeltaKiB=${afterKeyboard['pssKiB']! - beforeKeyboard['pssKiB']!} '
            'rssDeltaKiB=${afterKeyboard['rssKiB']! - beforeKeyboard['rssKiB']!}');

    for (var i = controller.state.sessions.length - 1; i >= 0; i--) {
      await controller.close(i);
    }
    await settle(tester, 1500);
    final end = _usage();
    final endFds = _fdKinds();
    r20('res.end', end);
    r20('res.endFds', endFds);
    await meminfo(tester, 'end');

    // 判定（跑 300 次之前定的）：热身后每开关一次 RSS、PSS 涨不到 0.05 MiB（真漏 0.1 MiB/次，200 次就是 20 MiB，会挂），
    // fd、线程每次涨不到 0.02 个（200 次不到 4 个）。
    expect(rssSlope, lessThan(0.05), reason: 'RSS 持续涨');
    expect(pssSlope, lessThan(0.05), reason: 'PSS 持续涨');
    expect(fdSlope, lessThan(0.02), reason: 'fd 持续涨');
    expect(threadSlope, lessThan(0.02), reason: '线程持续涨');
    // 连 SSH 的 socket 全关后一个不剩：App 里读不到 /proc/net（Android 10 起），由 tool/r20-gate.sh 在 MEM=end 时用 root 读、
    // 打 "R20HOST end ssh-sockets=…"，证据照那一行写。
  },
      skip: _scenario != 'resources' || ssh == null,
      timeout: const Timeout(Duration(minutes: 45)));

  testWidgets('ai-cli：Claude Code、Codex 不登录的界面能用方向键、回车、Ctrl+C 操作',
      (tester) async {
    final config = jsonDecode(_aiCli) as Map<String, dynamic>;
    final controller = await startApp(tester);
    final session = await openTab(tester, controller, config);
    final terminal = session.terminal;
    final failures = <String>[];
    r20(
        'ai.versions',
        (await exec(
                session, 'node --version; claude --version; codex --version'))
            .trim()
            .replaceAll('\n', ' | '));

    String visible() => screen(terminal).join('\n');
    void dump(String name) => r20('ai.$name', jsonEncode(screen(terminal)));
    Future<bool> waitText(Pattern pattern, {int seconds = 40}) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(deadline)) {
        if (visible().contains(pattern)) return true;
        await tester.pump(const Duration(milliseconds: 100));
      }
      return false;
    }

    /// 按 Ctrl+C 直到回到 shell（最后一行是 bash 的提示符），最多 4 次；再跑一条带标记的 echo 确认 shell 真能用。
    /// [hardware] 为真时按的是硬件 Ctrl+C（走 flterm 的按键编码，远端开了 kitty 键盘协议就编成 CSI u），
    /// 否则和快捷键栏、按键面板一样直接发 0x03。
    Future<bool> exitWithCtrlC(String name, {required bool hardware}) async {
      bool atPrompt() {
        final lines = screen(terminal).where((l) => l.isNotEmpty).toList();
        return lines.isNotEmpty &&
            RegExp(r'fixture@\S*:\S*\$$').hasMatch(lines.last);
      }

      var presses = 0;
      while (!atPrompt() && presses < 4) {
        presses++;
        if (hardware) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        } else {
          terminal.sendText('\x03');
        }
        await settle(tester, 1500);
      }
      dump('$name.afterCtrlC');
      r20('ai.$name.ctrlC',
          'presses=$presses hardware=$hardware atPrompt=${atPrompt()}');
      try {
        await run(tester, terminal, 'echo back-$name');
        return true;
      } on TestFailure {
        return false;
      }
    }

    // Claude Code：第一次运行先选主题（不登录就有）。↓ 换一项、↑ 回来、回车确认，进下一步（选登录方式之类）。
    await run(tester, terminal, 'cd /tmp && clear');
    terminal.sendText('claude\r');
    final themeShown = await waitText(RegExp(r'[Tt]heme|text style|Dark mode'));
    dump('claude.first');
    await shot(tester, 'ai-claude-first');
    if (!themeShown) failures.add('claude-theme');
    final firstScreen = visible();
    terminal.sendKey(TerminalSpecialKey.arrowDown);
    await settle(tester, 1200);
    dump('claude.down');
    final moved = visible() != firstScreen;
    terminal.sendKey(TerminalSpecialKey.arrowUp);
    await settle(tester, 1200);
    terminal.sendKey(TerminalSpecialKey.enter);
    await settle(tester, 3000);
    dump('claude.afterEnter');
    await shot(tester, 'ai-claude-next');
    final advanced = visible() != firstScreen;
    r20('ai.claude.keys', 'arrowMovedSelection=$moved enterAdvanced=$advanced');
    if (!moved) failures.add('claude-arrow');
    if (!advanced) failures.add('claude-enter');
    // Ctrl+C：Claude Code 要按两次才退出。这里按硬件 Ctrl+C（走按键编码）。
    if (!await exitWithCtrlC('claude', hardware: true)) {
      failures.add('claude-ctrl-c');
    }

    // Codex：不登录时先问怎么登录。↓/↑ 换选项，Ctrl+C 退出。
    await run(tester, terminal, 'clear');
    terminal.sendText('codex\r');
    final codexShown =
        await waitText(RegExp(r'Sign in|API key|ChatGPT|[Ll]og in'));
    dump('codex.first');
    await shot(tester, 'ai-codex-first');
    if (!codexShown) failures.add('codex-login');
    final codexFirst = visible();
    terminal.sendKey(TerminalSpecialKey.arrowDown);
    await settle(tester, 1200);
    dump('codex.down');
    final codexMoved = visible() != codexFirst;
    r20('ai.codex.keys', 'arrowMovedSelection=$codexMoved');
    if (!codexMoved) failures.add('codex-arrow');
    // 这里按快捷键栏、按键面板那种 0x03。
    if (!await exitWithCtrlC('codex', hardware: false)) {
      failures.add('codex-ctrl-c');
    }
    await shot(tester, 'ai-back-to-shell');

    await controller.close(0);
    await settle(tester, 300);
    expect(failures, isEmpty, reason: '不对的：$failures');
  },
      skip: _scenario != 'ai-cli' || _aiCli.isEmpty,
      timeout: const Timeout(Duration(minutes: 6)));
}

/// 本进程的资源：RSS、PSS（/proc/self/smaps_rollup，原生库的内存也算在里面）、fd 个数、线程数。
Map<String, int> _usage() {
  int field(String file, String name) {
    final line = File(file)
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('$name:'), orElse: () => '$name: -1');
    return int.parse(
        RegExp(r'-?\d+').firstMatch(line.substring(name.length))!.group(0)!);
  }

  return {
    'rssKiB': ProcessInfo.currentRss ~/ 1024,
    'pssKiB': field('/proc/self/smaps_rollup', 'Pss'),
    'fd': _fdCount(),
    'threads': field('/proc/self/status', 'Threads'),
  };
}

/// 让电脑那边抓一次 dumpsys meminfo（分得清 Native Heap 和别的），抓完再往下走。
Future<void> meminfo(WidgetTester tester, String name) async {
  debugPrint('R20 MEM=$name');
  await settle(tester, 4000);
}

/// 强制 GC 之后的 Dart 堆：还活着的字节数、容量，和每个类还活着的实例数。走本进程自己的 VM service
/// （debug 包才有），用 dart:io 的 WebSocket 发 JSON-RPC，不另加依赖。
class _HeapProfile {
  _HeapProfile(
      this.heapUsage, this.heapCapacity, this.external, this.instances);
  final int heapUsage;
  final int heapCapacity;
  final int external;
  final Map<String, int> instances;

  String get summary =>
      'liveAfterGcKiB=${heapUsage ~/ 1024} capacityKiB=${heapCapacity ~/ 1024} '
      'externalKiB=${external ~/ 1024} '
      'watched=${jsonEncode({for (final k in _watched) k: instances[k] ?? 0})}';

  /// 比 [before] 多出来的实例最多的 15 个类。
  Map<String, int> instancesGrownSince(_HeapProfile before) {
    final grown = <String, int>{
      for (final MapEntry(:key, :value) in instances.entries)
        if (value - (before.instances[key] ?? 0) > 0)
          key: value - (before.instances[key] ?? 0),
    };
    final top = grown.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map.fromEntries(top.take(15));
  }

  static const _watched = [
    'ActiveTerminalSession',
    'GhosttyTerminalAdapter',
    'TerminalSession',
    'Terminal',
    'SSHClient',
    'SSHSession',
    'ConnectionAttempt',
    '_TerminalPaneState',
    '_GhosttyTerminalViewState',
  ];
}

Future<_HeapProfile> _heapAfterGc() async {
  final info = await developer.Service.getInfo();
  final ws = await WebSocket.connect(info.serverWebSocketUri.toString());
  final replies = ws
      .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
      .asBroadcastStream();
  var id = 0;
  Future<Map<String, dynamic>> call(
      String method, Map<String, dynamic> params) async {
    final my = '${++id}';
    final reply = replies.firstWhere((r) => r['id'] == my);
    ws.add(jsonEncode(
        {'jsonrpc': '2.0', 'id': my, 'method': method, 'params': params}));
    final result = await reply;
    if (result['error'] != null) {
      throw StateError('$method: ${result['error']}');
    }
    return result['result'] as Map<String, dynamic>;
  }

  try {
    final isolateId = developer.Service.getIsolateId(Isolate.current)!;
    final profile = await call(
        'getAllocationProfile', {'isolateId': isolateId, 'gc': true});
    final usage = profile['memoryUsage'] as Map<String, dynamic>;
    final instances = <String, int>{};
    for (final member
        in (profile['members'] as List).cast<Map<String, dynamic>>()) {
      final name = (member['class'] as Map<String, dynamic>)['name'] as String;
      final count = member['instancesCurrent'] as int? ?? 0;
      if (count > 0) instances[name] = (instances[name] ?? 0) + count;
    }
    return _HeapProfile(usage['heapUsage'] as int, usage['heapCapacity'] as int,
        usage['externalUsage'] as int, instances);
  } finally {
    await ws.close();
  }
}

/// 本进程的 fd 按指向分类数：socket、pipe、anon_inode:名字、/dev/ 下的设备，其余文件归成 file。
/// 全关标签后 fd 总数没回到起点时，靠它看多出来的是什么（SSH 的 socket 才是连接没关干净）。
Map<String, int> _fdKinds() {
  final kinds = <String, int>{};
  for (final entry in Directory('/proc/self/fd').listSync(followLinks: false)) {
    final String target;
    try {
      target = Link(entry.path).targetSync();
    } on FileSystemException {
      continue; // 列的时候正好被关了
    }
    final kind = target.startsWith('socket:')
        ? 'socket'
        : target.startsWith('pipe:')
            ? 'pipe'
            : target.startsWith('anon_inode:')
                ? target.replaceAll(RegExp(r'[\[\]]'), '')
                : target.startsWith('/dev/')
                    ? target
                    : 'file';
    kinds[kind] = (kinds[kind] ?? 0) + 1;
  }
  return Map.fromEntries(
      kinds.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
}

/// 本进程打开的 fd 个数。列 /proc/self/fd 的同时别的线程可能正好关掉一个，默认跟随链接去 stat 就会报
/// 「No such file」：不跟链接，碰上了再列一次。
int _fdCount() {
  for (var attempt = 0;; attempt++) {
    try {
      return Directory('/proc/self/fd').listSync(followLinks: false).length;
    } on FileSystemException {
      if (attempt >= 5) rethrow;
    }
  }
}

/// 一行里第 [left] 到 [left]+[width] 个格子的字。中文、emoji 占两格，后半格不再出字。
String _cells(String line, int left, int width) {
  final out = StringBuffer();
  var col = 0;
  for (final rune in line.runes) {
    final w = _wide(rune) ? 2 : 1;
    if (col >= left && col + w <= left + width) out.writeCharCode(rune);
    col += w;
    if (col >= left + width) break;
  }
  return out.toString();
}

bool _wide(int r) =>
    (r >= 0x1100 && r <= 0x115f) ||
    (r >= 0x2e80 && r <= 0xa4cf) ||
    (r >= 0xac00 && r <= 0xd7a3) ||
    (r >= 0xf900 && r <= 0xfaff) ||
    (r >= 0xfe30 && r <= 0xfe4f) ||
    (r >= 0xff00 && r <= 0xff60) ||
    (r >= 0xffe0 && r <= 0xffe6) ||
    (r >= 0x1f300 && r <= 0x1f64f) ||
    (r >= 0x1f900 && r <= 0x1f9ff);

const _demoPy = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R20 设备上的全屏程序素材：中文、emoji、宽窄混排。"""

def 问候(名字: str) -> str:
    return f"你好，{名字}！今天是测试 🙂"

数据 = {"中文": 1, "English": 2, "日本語": 3, "한국어": 4}
for 键, 值 in 数据.items():
    print(键, 值, "全角（括号）【方括号】")

# 这一行比较长，用来看 vim 怎样折行：中文中文中文中文中文中文中文中文 abcdefghijklmnopqrstuvwxyz 0123456789 结尾
print(问候("终端"))
''';

String _longTxt() {
  final lines = <String>[];
  for (var i = 1; i <= 200; i++) {
    final n = i.toString().padLeft(3, '0');
    if (i % 7 == 0) {
      lines.add('第$n行 \x1b[32m绿色\x1b[0m \x1b[1;31m粗红\x1b[0m 普通 ascii text');
    } else if (i % 5 == 0) {
      lines.add('第$n行 这是一行超过八十列的长内容，用来看 less 怎样折行：'
          '中文中文中文中文中文 abcdefghijklmnopqrstuvwxyz 0123456789 结尾');
    } else {
      lines.add('第$n行 中文内容 the quick brown fox ${i * 37 % 101}');
    }
  }
  return '${lines.join('\n')}\n';
}
