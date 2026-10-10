// R22 设备测试：连接生命周期在真 Android 上的样子（通知「全部断开」、系统停服务、Wi-Fi↔蜂窝、锁屏、
// 代理和 sshd 重启、Activity 被结束、进程被结束后放回标签、引擎原生内存）。
//
// 这不是 CI 测试。要本机的 Docker 测试环境和一台模拟器，经 tool/r22-lifecycle.sh 跑：
//   (cd tool/fixture-environment && ./up.sh)
//   tool/r22-lifecycle.sh emulator-5580 notify|svcstop|network|lock|proxy|activity|engine|seed
// 真机长测 soak（LIFE07）经 tool/r22-soak.sh 跑，要所有者在场锁屏、解锁。
// 测试和脚本靠两样东西对话：测试打 "R22 ACTION=<名字>" 请脚本在手机/测试环境上做一件事（按 HOME、点通知、
// 关 Wi-Fi、锁屏、停代理……），脚本做完用 run-as 在 App 私有目录里放一个 r22/<名字> 文件，测试看到它再往下走。
// App 在后台时 Flutter 不出帧，等待一律用真实时钟（Future.delayed），不用 tester.pump。
// 证据是以 "R22 " 开头的行（也进 logcat），脚本那一侧打 "R22HOST " 开头的行。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:netcatty_mobile/app.dart';
import 'package:netcatty_mobile/application/home_navigation.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/tmux/tmux_target.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/tmux/tmux_service.dart';
import 'package:netcatty_mobile/presentation/terminal/terminal_view.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _scenario = String.fromEnvironment('R22_SCENARIO');
const _config = String.fromEnvironment('R22_CONFIG');

File? _logFile;

/// 真机长测锁屏时要拔 USB 线，flutter 那头的输出就断了：同样的行再写一份到 App 私有目录的 r22/log.txt，
/// 脚本插回线后从那里读。
void r22(String key, Object? value) {
  final line = 'R22 $key=$value';
  debugPrint(line);
  _logFile?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

/// 请脚本做一件事，等它做完（它在 App 私有目录放 r22/<名字>）。
Future<void> action(String name,
    {Duration timeout = const Duration(minutes: 15)}) async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/r22');
  final done = File('${dir.path}/$name');
  r22('ACTION', name);
  final deadline = DateTime.now().add(timeout);
  while (!await done.exists()) {
    if (DateTime.now().isAfter(deadline)) fail('等脚本做「$name」超时');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  r22('ACK', name);
}

/// 真实时钟下等到 [condition] 成立，最多 [timeout]；成立返回 true。App 在后台也能用。
Future<bool> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return true;
}

Future<void> frames(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 数每条标签发起了几次连接（新开和恢复都算）、其中几次连上了。真连接照常建，只是记个数。
class _CountingSshService extends SshService {
  final calls = <String, int>{};
  final succeeded = <String, int>{};
  final purposes = <ConnectionPurpose>[];

  int get total => calls.values.fold(0, (a, b) => a + b);

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
    calls[sessionId] = (calls[sessionId] ?? 0) + 1;
    purposes.add(purpose);
    return super
        .connect(
      sessionId: sessionId,
      host: host,
      hosts: hosts,
      keys: keys,
      proxyProfiles: proxyProfiles,
      routePlan: routePlan,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
      terminal: terminal,
      purpose: purpose,
      attempt: attempt,
      tmuxAttach: tmuxAttach,
    )
        .then((session) {
      succeeded[sessionId] = (succeeded[sessionId] ?? 0) + 1;
      return session;
    });
  }
}

late ProviderContainer _container;
final _service = _CountingSshService();
late Map<String, dynamic> _cfg;

Future<SessionController> startApp(WidgetTester tester) async {
  _cfg = jsonDecode(_config) as Map<String, dynamic>;
  final logDir =
      Directory('${(await getApplicationSupportDirectory()).path}/r22')
        ..createSync(recursive: true);
  _logFile = File('${logDir.path}/log.txt');
  final repository = await VaultRepository.open();
  _container = ProviderContainer(overrides: [
    vaultRepositoryProvider.overrideWithValue(repository),
    sshServiceProvider.overrideWithValue(_service),
  ]);
  addTearDown(_container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: _container,
    child: const NetcattyApp(),
  ));
  _container.read(homeTabProvider.notifier).state = 1;
  await frames(tester);
  return _container.read(sessionControllerProvider.notifier);
}

/// 测试环境边缘 sshd（adb reverse 的 22201，走 adb 通道、不经模拟器网络）或经模拟器网络的 10.0.2.2；
/// 真机走 Wi-Fi 时是 xdwmbp 上的转发口。
HostProfile edgeHost(String id,
        {String hostname = '127.0.0.1', int? port, bool ephemeral = true}) =>
    HostProfile({
      'id': id,
      'label': id,
      'hostname': hostname,
      'port': port ?? _cfg['edge']['port'],
      'username': _cfg['user'],
      'password': _cfg['password'],
      'authMethod': 'password',
      'protocol': 'ssh',
      if (ephemeral) '_ephemeralTerminal': true,
    });

Future<bool> trustEdge(
        HostProfile host, String algorithm, String fingerprint) async =>
    fingerprint == _cfg['edge']['fingerprint'];

Future<ActiveTerminalSession> open(
  SessionController controller,
  HostProfile host, {
  HostKeyVerifier verify = trustEdge,
}) async {
  final before = controller.state.sessions.length;
  final ok = await controller.connect(host, verify);
  if (!ok || controller.state.sessions.length <= before) {
    fail('没连上 ${host.label}');
  }
  final session = controller.state.sessions.last;
  await until(() => session.terminal.allText().trim().isNotEmpty);
  return session;
}

ActiveTerminalSession? tabOf(SessionController controller, String id) =>
    controller.state.sessions.where((value) => value.id == id).firstOrNull;

String describe(SessionController controller) => [
      for (final session in controller.state.sessions)
        '${session.host.label}:${session.connected ? 'up' : controller.state.recovering.contains(session.id) ? 'recovering' : 'down'}'
            '${session.restoreHold == null ? '' : '/${session.restoreHold!.kind.name}'}',
    ].join(',');

Future<String> exec(ActiveTerminalSession session, String command) async =>
    utf8.decode(await session.sshClient!.run(command), allowMalformed: true);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('R22 $_scenario', (tester) async {
    final controller = await startApp(tester);
    switch (_scenario) {
      case 'notify':
      case 'svcstop':
        await _stopScenario(tester, controller);
      case 'network':
        await _networkScenario(tester, controller);
      case 'lock':
        await _lockScenario(tester, controller);
      case 'saver':
        await _saverScenario(tester, controller);
      case 'proxy':
        await _proxyScenario(tester, controller);
      case 'activity':
        await _activityScenario(tester, controller);
      case 'engine':
        await _engineScenario(tester);
      case 'sshcycle':
        await _sshCycleScenario(tester, controller);
      case 'frames':
        await _framesScenario(tester, controller);
      case 'framesview':
        await _framesScenario(tester, controller,
            page: false, liveSeconds: 1200, every: 120);
      case 'framestext':
        await _framesScenario(tester, controller,
            page: false, text: true, liveSeconds: 1200, every: 120);
      case 'seed':
        await _seedScenario(tester, controller);
      case 'soak':
        try {
          await _soakScenario(tester, controller);
        } on Object catch (error) {
          // 拔过线之后 flutter 那头收不到测试结果，脚本靠这一行知道测试已经结束。
          r22('FAILED', error);
          rethrow;
        }
      default:
        fail('不认识的场景：$_scenario');
    }
    r22('DONE', _scenario);
    // soak 是前台 + 锁屏各 30 分钟，再加等所有者锁屏、解锁的时间。
  }, timeout: Timeout(Duration(minutes: _scenario == 'soak' ? 180 : 40)));
}

/// LIFE02：通知「全部断开」（notify）或系统停了服务（svcstop），然后切网络：不复活、不重新登录；
/// 回到前台给出原因和「重新连接」。
Future<void> _stopScenario(
    WidgetTester tester, SessionController controller) async {
  final a = await open(controller, edgeHost('r22-a'));
  final b = await open(controller, edgeHost('r22-b'));
  await frames(tester);
  r22('tabs', describe(controller));
  await action('home');
  await action(_scenario == 'notify' ? 'notify-stop' : 'stop-service');
  final stopped = await until(
      () => controller.state.sessions.every((value) => !value.connected),
      timeout: const Duration(seconds: 20));
  r22('stopped', '$stopped ${describe(controller)}');
  r22('hold', tabOf(controller, a.id)?.restoreHold?.message);
  final calls = _service.total;
  await action('wifi-toggle');
  await Future<void>.delayed(const Duration(seconds: 20));
  r22('connect-calls-after-stop', _service.total - calls);
  r22('tabs-after-network', describe(controller));
  await action('foreground');
  await frames(tester, 1500);
  await action('shot-$_scenario-banner');
  final hold = tabOf(controller, b.id)?.restoreHold?.message ?? '';
  r22('banner-shown', find.text(hold).evaluate().isNotEmpty);
  r22('reconnect-button',
      find.byKey(const ValueKey('terminal-reconnect')).evaluate().length);
  expect(stopped, isTrue);
  expect(_service.total - calls, 0, reason: '全部断开后不复活、不重新登录');
}

/// LIFE03：A 走 adb reverse（不经模拟器网络，切网时必须一直活着），B 走模拟器网络（10.0.2.2，只有蜂窝通）。
/// 脚本切 20 次：10 次短（Wi-Fi 开 8 秒，蜂窝上的连接还在 30 秒的保留期里，B 应当活着），
/// 10 次长（Wi-Fi 开 45 秒，系统掐掉蜂窝上的 socket，B 断、恢复、再连上）。
Future<void> _networkScenario(
    WidgetTester tester, SessionController controller) async {
  await action('cellular-only');
  final a = await open(controller, edgeHost('r22-adb'));
  final b = await open(controller, edgeHost('r22-net', hostname: '10.0.2.2'));
  r22('tabs', describe(controller));
  final aObject = a;
  var bDrops = 0;
  var aDown = false;
  var last = describe(controller);
  var maxAttempts = 0;
  final cycling = action('wifi-cycle', timeout: const Duration(minutes: 30));
  var finished = false;
  unawaited(cycling.then((_) => finished = true));
  var bWasUp = true;
  final started = DateTime.now();
  while (!finished) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final now = describe(controller);
    final aNow = tabOf(controller, a.id);
    if (!identical(aNow, aObject) || aNow?.connected != true) aDown = true;
    final bNow = tabOf(controller, b.id);
    final bUp = bNow?.connected == true;
    if (bWasUp && !bUp) bDrops++;
    bWasUp = bUp;
    maxAttempts = _service.calls[b.id] ?? 0;
    if (now != last) {
      r22('t+${DateTime.now().difference(started).inSeconds}s', now);
      last = now;
    }
  }
  final recovered = await until(
      () => tabOf(controller, b.id)?.connected == true,
      timeout: const Duration(seconds: 90));
  r22('a-never-down', !aDown);
  r22('a-same-object', identical(tabOf(controller, a.id), aObject));
  r22('b-drops', bDrops);
  r22('b-connect-calls', maxAttempts);
  r22('b-recovered-at-end', recovered);
  r22('b-hold', tabOf(controller, b.id)?.restoreHold?.message);
  r22('purposes',
      _service.purposes.map((value) => value.name).toSet().join('+'));
  expect(aDown, isFalse, reason: '不经模拟器网络的连接不能因为网络通知被断开');
  expect(recovered, isTrue);
}

/// SEC07 / LIFE04「锁屏」：后台、锁屏时服务器那头断掉，App 不重新登录；解锁回到 App 才恢复。
Future<void> _lockScenario(
    WidgetTester tester, SessionController controller) async {
  final session = await open(controller, edgeHost('r22-lock'));
  await action('home-lock');
  final calls = _service.total;
  await action('kill-server-sessions');
  final down = await until(
      () => tabOf(controller, session.id)?.connected == false,
      timeout: const Duration(seconds: 60));
  await Future<void>.delayed(const Duration(seconds: 30));
  r22('down-while-locked', down);
  r22('connect-calls-while-locked', _service.total - calls);
  r22('hold', tabOf(controller, session.id)?.restoreHold?.message);
  await action('unlock-foreground');
  final back = await until(
      () => tabOf(controller, session.id)?.connected == true,
      timeout: const Duration(seconds: 60));
  r22('restored-after-unlock', back);
  await frames(tester, 1000);
  await action('shot-lock-restored');
  r22('connect-calls-after-unlock', _service.total - calls);
  expect(_service.total - calls >= 1, isTrue);
  expect(back, isTrue);
}

/// LIFE04「进入省电」：后台、息屏、打开省电模式 60 秒。前台服务的进程不受省电模式断网，连接应当还在、
/// App 不该自己去断或重连；关掉省电回到前台，同一条连接接着用。
Future<void> _saverScenario(
    WidgetTester tester, SessionController controller) async {
  final session = await open(controller, edgeHost('r22-saver'));
  final marker = await exec(session, 'echo \$PPID');
  final calls = _service.total;
  await action('home-saver-on');
  await Future<void>.delayed(const Duration(seconds: 60));
  r22('during-saver', describe(controller));
  r22('connect-calls-during-saver', _service.total - calls);
  await action('saver-off-foreground');
  await frames(tester, 1000);
  final tab = tabOf(controller, session.id);
  final same = identical(tab, session) && tab!.connected;
  r22('after-saver.same-session', same);
  r22('after-saver.same-ssh',
      same && (await exec(session, 'echo \$PPID')) == marker);
  expect(same, isTrue);
}

/// LIFE04：经 SOCKS 代理到只有容器网络里才有的 target；代理停了再起、target 的 sshd 重启。
Future<void> _proxyScenario(
    WidgetTester tester, SessionController controller) async {
  final host = HostProfile({
    'id': 'r22-proxy',
    'label': 'r22-proxy',
    'hostname': _cfg['target']['name'],
    'port': _cfg['target']['port'],
    'username': _cfg['user'],
    'password': _cfg['password'],
    'authMethod': 'password',
    'protocol': 'ssh',
    '_ephemeralTerminal': true,
    'proxyConfig': {
      'type': 'socks5',
      'host': '127.0.0.1',
      'port': _cfg['socks']['port'],
      'username': _cfg['socks']['username'],
      'password': _cfg['socks']['password'],
    },
  });
  final session = await open(controller, host,
      verify: (_, __, fingerprint) async =>
          fingerprint == _cfg['target']['fingerprint']);
  r22('tabs', describe(controller));
  await action('socks-stop');
  await until(() => tabOf(controller, session.id)?.connected == false);
  await Future<void>.delayed(const Duration(seconds: 12));
  r22('during-socks-down', describe(controller));
  r22('error-while-proxy-down', controller.state.error);
  await action('socks-start');
  final back = await until(
      () => tabOf(controller, session.id)?.connected == true,
      timeout: const Duration(seconds: 90));
  r22('recovered-after-socks', back);
  final restored = tabOf(controller, session.id)!;
  r22('route-after-recovery', restored.routePlan?.entry);
  // sshd 重启、密钥不变：恢复时照常核对指纹，核对通过就接着用。
  await action('target-restart');
  await until(() => tabOf(controller, session.id)?.connected == false);
  final again = await until(
      () => tabOf(controller, session.id)?.connected == true,
      timeout: const Duration(seconds: 120));
  r22('recovered-after-sshd-restart', '$again ${describe(controller)}');
  // 重启后换了主机密钥：恢复在指纹这一步停下，一次都不重试，等用户。
  final calls = _service.total;
  await action('target-rekey');
  await until(() => tabOf(controller, session.id)?.connected == false);
  final held = await until(
      () => tabOf(controller, session.id)?.restoreHold != null,
      timeout: const Duration(seconds: 120));
  await Future<void>.delayed(const Duration(seconds: 15));
  r22('after-rekey', '$held ${describe(controller)}');
  r22('hold-after-rekey', tabOf(controller, session.id)?.restoreHold?.message);
  r22('connect-calls-after-rekey', _service.total - calls);
  expect(again, isTrue);
  expect(held, isTrue);
  expect(back, isTrue);
}

/// LIFE05「Activity 重建」：返回键、开发者选项「不保留活动」、从最近任务划掉。会话对象和连接都不能变。
Future<void> _activityScenario(
    WidgetTester tester, SessionController controller) async {
  final session = await open(controller, edgeHost('r22-activity'));
  final marker = await exec(session, 'echo \$PPID');
  r22('tabs', describe(controller));
  for (final step in ['back', 'dont-keep-activities', 'recents-swipe']) {
    await action(step);
    await Future<void>.delayed(const Duration(seconds: 3));
    final tab = tabOf(controller, session.id);
    r22('$step.same-session', identical(tab, session));
    r22('$step.connected', tab?.connected);
    await action('foreground');
    await frames(tester, 1000);
    await action('shot-activity-$step');
    final again = tabOf(controller, session.id);
    r22('$step.after-return',
        '${identical(again, session)} ${again?.connected}');
    r22('$step.same-ssh', (await exec(session, 'echo \$PPID')) == marker);
    expect(identical(again, session) && again!.connected, isTrue, reason: step);
  }
}

/// LIFE06 分来源：开关 SSH 标签 400 次（连上、跑一条命令、关），但停在「保险库」页、不显示终端。
/// 和 R20 资源门禁（显示终端）比，Native Heap 涨不涨就分得出是 SSH/Dart 这边还是终端页的渲染。
Future<void> _sshCycleScenario(
    WidgetTester tester, SessionController controller) async {
  _container.read(homeTabProvider.notifier).state = 0;
  await frames(tester);
  for (var i = 0; i <= 400; i++) {
    if (i % 100 == 0) await action('mem-sshcycle-$i');
    final session = await open(controller, edgeHost('r22-cycle'));
    await exec(session, 'echo cycle-$i');
    await controller.close(controller.state.sessions.indexOf(session));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// LIFE06 线索（LIFE07 真机第一轮撞出来的）：测试框架 fullyLive 时一直出帧，30 分钟后 Native Heap 到了 78 MB。
/// 同一个画面先按需出帧（不动）量 2 分钟当底，再 fullyLive 一直出帧量 4 分钟，每 30 秒抓一次 meminfo，
/// 数出这段画了多少帧。先是完整的终端页（连着一个 SSH 标签），再是只有一个终端视图（不连 SSH）。
/// 后一段涨、前一段不涨，就是按帧在涨；两个画面比，分得出涨在终端视图还是页上别的部件。
///
/// `framesview` 只量终端视图、一直出帧 20 分钟（每 2 分钟一次），看涨到一定程度停不停；不连 SSH。
/// `framestext` 是它的对照组：同样的字换成 Flutter 自带的 Text，分得清涨在 Ghostty 还是 Flutter/测试框架自己。
Future<void> _framesScenario(WidgetTester tester, SessionController controller,
    {bool page = true,
    bool text = false,
    int liveSeconds = 240,
    int every = 30}) async {
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  Future<void> measure(String name) async {
    Future<void> sample(String phase, int seconds) async {
      for (var at = 0; at <= seconds; at += every) {
        await action('mem-frames-$name-$phase-${at}s');
        if (at < seconds) {
          await Future<void>.delayed(Duration(seconds: every));
        }
      }
    }

    await sample('idle', 120);
    var drawn = 0;
    void count(List<FrameTiming> timings) => drawn += timings.length;
    SchedulerBinding.instance.addTimingsCallback(count);
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    binding.scheduleFrame();
    await sample('live', liveSeconds);
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fadePointers;
    await Future<void>.delayed(const Duration(seconds: 2));
    SchedulerBinding.instance.removeTimingsCallback(count);
    r22('frames-$name', drawn);
  }

  if (page) {
    await open(controller, edgeHost('r22-frames'));
    await frames(tester);
    await measure('page');
  }

  if (text) {
    // 对照组：同样 40 行红字中文，换成 Flutter 自带的 Text，不经 Ghostty。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Text(
          '中文 frames\n' * 40,
          style: const TextStyle(
              fontSize: 13, color: Colors.red, fontFamily: 'monospace'),
        ),
      ),
    ));
    await frames(tester);
    await measure('text');
    await tester.pumpWidget(const SizedBox());
    return;
  }
  final terminal = GhosttyTerminalAdapter();
  terminal.feed(
      Uint8List.fromList(utf8.encode('\x1b[31m中文 frames\x1b[0m\r\n' * 40)));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: terminalViewFor(
        terminal,
        const TerminalViewOptions(
          fontSize: 13,
          secureKeyboard: false,
          interactive: true,
          transparentBackground: false,
        ),
      ),
    ),
  ));
  await frames(tester);
  await measure('view');
  await tester.pumpWidget(const SizedBox());
  terminal.dispose();
}

/// LIFE06 的引擎部分：只建/销毁 Ghostty 终端（不连 SSH），挂上视图和不挂视图各 400 次，
/// 每 100 次请脚本抓一次 dumpsys meminfo，分得清原生内存涨在引擎还是别处。
Future<void> _engineScenario(WidgetTester tester) async {
  Future<void> cycle(String name, {required bool view}) async {
    for (var i = 0; i <= 400; i++) {
      if (i % 100 == 0) await action('mem-$name-$i');
      final terminal = GhosttyTerminalAdapter();
      terminal.feed(
          Uint8List.fromList(utf8.encode('\x1b[31m中文 $i\x1b[0m\r\n' * 40)));
      if (view) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: terminalViewFor(
              terminal,
              const TerminalViewOptions(
                fontSize: 13,
                secureKeyboard: false,
                interactive: true,
                transparentBackground: false,
              ),
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
      terminal.dispose();
    }
  }

  await tester.pumpWidget(const SizedBox());
  await cycle('adapter', view: false);
  await cycle('view', view: true);
}

/// LIFE02/LIFE05「进程被结束」的前半段：主机写进保险库（含信任的指纹），开一个普通标签和一个 tmux 标签，
/// 等标签清单写盘，然后一直等着被脚本结束。后半段（放回、点「重新连接」）脚本装正式的 debug 包、用 uiautomator 做。
Future<void> _seedScenario(
    WidgetTester tester, SessionController controller) async {
  final vault = _container.read(vaultControllerProvider.notifier);
  final host = edgeHost('r22-seed', ephemeral: false)
    ..data['label'] = 'r22 edge';
  await vault.upsertHost(host);
  final data = await vault.ready();
  await vault.replace(data.copyWith(extras: {
    ...data.extras,
    'knownHosts': [
      {
        'hostname': '127.0.0.1',
        'port': _cfg['edge']['port'],
        'keyType': _cfg['edge']['keyType'],
        'fingerprint': _cfg['edge']['fingerprint'],
        'acceptedAt': DateTime.now().millisecondsSinceEpoch,
      },
    ],
  }));
  final stored =
      (await vault.ready()).hosts.firstWhere((value) => value.id == host.id);
  final plain = await open(controller, stored);
  await exec(plain,
      'tmux kill-session -t r22 2>/dev/null; tmux new-session -d -s r22 "sh"');
  final probe = await const TmuxService()
      .probe(plain.sshClient!, const TmuxSocketSpec.standard());
  final row = probe.sessions.firstWhere((value) => value.name == 'r22');
  final target = targetOf(row,
      hostKey: tmuxHostKeyOf(plain),
      unixUser: probe.unixUser,
      uid: probe.uid!,
      socket: const TmuxSocketSpec.standard());
  r22('tmux-target', target.guard);
  await controller.openTmuxTerminal(plain, target);
  await until(() => controller.state.sessions.length == 2);
  await Future<void>.delayed(const Duration(seconds: 2));
  final saved = (await SharedPreferences.getInstance())
          .getString('xwshun.r22.restorableTabs') ??
      '';
  r22('persisted', saved);
  r22('SEEDED', describe(controller));
  // 等脚本结束进程（stop-app / force-stop）。
  await Future<void>.delayed(const Duration(minutes: 30));
}

/// LIFE07（真机，tool/r22-soak.sh）：前台 minutes 分钟、再锁屏同样长；省电豁免关、开各跑一轮（豁免由脚本加）。
/// 锁屏前所有者先拔掉 USB 线（插着线手机 CPU 不睡，测不出真情况），到点插回再解锁。
/// 三条标签：usb 走 adb reverse（经 USB，拔线就断，解锁后该恢复），wifi 和 tick 走手机 Wi-Fi 到 xdwmbp 上的转发；
/// tick 的 shell 每 5 分钟打一行 tick-N，看锁屏时远端的输出还到不到。
/// 「状态真实」：每个检查点在 App 说「连着」的标签上跑一条命令，跑不通（NOREPLY）就是嘴上连着。
/// 「无重复操作」：每条标签连上的次数不超过 1 + 它真断过的次数（连不上按退避再试不算）。
/// 锁屏时手机睡了多久：Stopwatch 不算休眠时间，和墙上时钟一减就是。
Future<void> _soakScenario(
    WidgetTester tester, SessionController controller) async {
  final minutes = (_cfg['minutes'] as num).toInt();
  final every = Duration(minutes: minutes >= 10 ? 5 : 1);
  final wifi = _cfg['wifi'] as Map<String, dynamic>;
  HostProfile overWifi(String id) => edgeHost(id,
      hostname: wifi['host'] as String, port: (wifi['port'] as num).toInt());
  await action('soak-start');
  final tabs = <String, ActiveTerminalSession>{
    'usb': await open(controller, edgeHost('life07-usb')),
    'wifi': await open(controller, overWifi('life07-wifi')),
    'tick': await open(controller, overWifi('life07-tick')),
  };
  final started = DateTime.now();
  tabs['tick']!.terminal.sendText(
      'i=0; while :; do i=\$((i+1)); echo tick-\$i; sleep 300; done\r');
  r22(
      'server-pids',
      [
        for (final MapEntry(:key, :value) in tabs.entries)
          '$key:${(await exec(value, 'echo \$PPID')).trim()}',
      ].join(','));

  int lastTick() => RegExp(r'tick-(\d+)')
      .allMatches(tabOf(controller, tabs['tick']!.id)?.terminal.allText() ?? '')
      .map((match) => int.parse(match[1]!))
      .fold(0, (a, b) => a > b ? a : b);
  // 尝试次数/连上次数。恢复时连不上按退避再试（1、2、5…秒）不算重复，多连上一次才算。
  String calls() => [
        for (final MapEntry(:key, :value) in tabs.entries)
          '$key:${_service.calls[value.id] ?? 0}/${_service.succeeded[value.id] ?? 0}',
      ].join(',');
  final probes = <String>[];
  Future<String> probe(String label) async {
    final result = [
      for (final MapEntry(:key, :value) in tabs.entries)
        '$key:${await _probeOne(tabOf(controller, value.id))}',
    ].join(',');
    probes.add(result);
    r22(label, result);
    return result;
  }

  final drops = {for (final name in tabs.keys) name: 0};
  final wasUp = {for (final name in tabs.keys) name: true};
  var last = '';
  void watch(String phase, DateTime since) {
    for (final MapEntry(:key, :value) in tabs.entries) {
      final up = tabOf(controller, value.id)?.connected == true;
      if (wasUp[key]! && !up) drops[key] = drops[key]! + 1;
      wasUp[key] = up;
    }
    final now = '${describe(controller)} tick=${lastTick()} '
        'app=${WidgetsBinding.instance.lifecycleState?.name}';
    if (now != last) {
      r22('$phase+${DateTime.now().difference(since).inSeconds}s', now);
      last = now;
    }
  }

  // 前台：屏幕亮着、App 在最前（脚本让手机插着电时不灭屏），每秒画一帧。App 被盖住的话 watch 会记下 app=hidden 之类。
  // 只在 App 在前台时 pump：被盖住（插着电时按电源键进的是屏保）时等不到帧，pump 会一直卡着（试跑卡过一次）。
  // 别改成 framePolicy = fullyLive：测试框架在那种模式下画完一帧立刻排下一帧，120 帧/秒一直重画，
  // debug 包里占满一个核，第一轮正式跑到 25 分钟时一条命令要 10 秒才回。
  var check = 0;
  while (DateTime.now().isBefore(started.add(Duration(minutes: minutes)))) {
    watch('fg', started);
    if (!DateTime.now().isBefore(started.add(every * check))) {
      await probe('fg-check-$check');
      await action('facts-fg-$check');
      check++;
    }
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await tester.pump();
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await probe('fg-end');
  r22('fg-end.calls', '${calls()} drops=$drops');

  // 锁屏：所有者先拔线、再按电源键（插着线按电源键进的是屏保，拔了线屏保也可能不退，手机一直醒着）。
  // 拔线后脚本够不着手机，所以锁屏时刻由测试自己看 App 进后台来记；脚本等所有者插回线、解锁之后才回「lock」。
  // 锁着时 CPU 醒着才轮得到这里记一笔，所以只记变化。
  var unlocked = false;
  Object? failure;
  final unlocking = action('lock', timeout: Duration(minutes: minutes + 60))
      .then((_) => unlocked = true, onError: (Object error) {
    failure = error;
    unlocked = true;
  });
  while (!unlocked &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
    watch('fg', started);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  final lockedAt = DateTime.now();
  final awake = Stopwatch()..start();
  // 解锁那一刻（App 回到 resumed）先记 App 说的，立刻逐条核对；这时恢复才刚开始，看到的就是用户看到的。
  var resumed = false;
  while (!unlocked) {
    watch('lock', lockedAt);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!resumed && lifecycle == AppLifecycleState.resumed) {
      resumed = true;
      final wall = DateTime.now().difference(lockedAt);
      r22('resumed',
          '+${wall.inSeconds}s ${describe(controller)} tick=${lastTick()}');
      r22('lock.slept',
          '${(wall - awake.elapsed).inSeconds}s of ${wall.inSeconds}s (awake ${awake.elapsed.inSeconds}s)');
      await probe('resume.probe');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  await unlocking;
  if (failure != null) throw failure!;
  r22('lock.resume-seen', resumed);

  r22('unlock.claimed', '${describe(controller)} tick=${lastTick()}');
  watch('unlock', lockedAt);
  final back = await until(
      () => tabs.values
          .every((value) => tabOf(controller, value.id)?.connected == true),
      timeout: const Duration(seconds: 90));
  watch('unlock', lockedAt);
  // 截图前画一帧，不然截到的是锁屏前的画面。App 不在最前（所有者没点回来）时 pump 等不到帧，不画。
  if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
  await action('shot-life07-unlocked');
  r22('unlock.recovered', '$back ${describe(controller)}');
  await probe('unlock.probe-after');
  r22('ticks',
      'last=${lastTick()} expected=${1 + DateTime.now().difference(started).inSeconds ~/ 300}');
  r22('drops', drops);
  r22('connect-calls', calls());
  r22(
      'holds',
      [
        for (final MapEntry(:key, :value) in tabs.entries)
          '$key:${tabOf(controller, value.id)?.restoreHold?.message}',
      ].join(' | '));
  await action('soak-end');
  expect(probes.where((value) => value.contains('NOREPLY')), isEmpty,
      reason: 'App 说连着的标签必须真能跑命令');
  for (final MapEntry(:key, :value) in tabs.entries) {
    expect(
        _service.succeeded[value.id] ?? 0, lessThanOrEqualTo(1 + drops[key]!),
        reason: '$key：连上的次数不能超过 1 + 断开次数');
  }
}

/// 在一条标签上跑 `echo ok`，15 秒没回就记 NOREPLY。
Future<String> _probeOne(ActiveTerminalSession? tab) async {
  if (tab == null) return 'gone';
  if (!tab.connected) return 'down';
  final watch = Stopwatch()..start();
  try {
    final out = await exec(tab, 'echo ok').timeout(const Duration(seconds: 15));
    return out.trim() == 'ok' ? 'ok/${watch.elapsedMilliseconds}ms' : 'odd';
  } on Object catch (error) {
    return 'NOREPLY(${error.runtimeType})';
  }
}
