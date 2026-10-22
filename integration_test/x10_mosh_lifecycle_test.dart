// X10 设备验证：Mosh 会话在换网、离线、后台、运行时/插件崩溃、强停、「全部断开」时的样子（MOS06、MOS07、PLG16）。
// 走的是用户点「连接」的那条路（同 mosh_session_test.dart：SessionController → 协调器 → 真插件 → 真 mosh-server），
// 中间请电脑那头的脚本动手机或测试环境。
//
// 这不是 CI 测试。只经 tool/x10-mosh.sh 跑（它起测试、按测试的请求开关网络、杀进程、数远端）：
//   (cd tool/mosh-fixture && ./up.sh)
//   adb -s emulator-5580 install -r plugins/mosh/build/outputs/apk/release/mosh-release.apk
//   tool/x10-mosh.sh emulator-5580 roam|life|hostkill|cycles|doze
//   (cd tool/fixture-environment && ./up.sh) && tool/x10-mosh.sh emulator-5580 socks
// 测试和脚本的对话同 R22：测试打 "X10 ACTION=<名字>"，脚本做完用 run-as 在 App 私有目录放 x10/<名字>，测试看到再往下走。
// App 在后台时 Flutter 不出帧，tester.pump 会卡住：等待一律用真实时钟（Future.delayed）。
// 模拟器上 TCP 经 10.0.2.2 只在蜂窝上通（docs/dev/README.md 第 3 节），所以开会话、开 Monitor 都在 Wi-Fi 关着时做；
// UDP 两张网都通，换网只影响 Mosh 那条 UDP，正好是要测的。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shun/application/mosh_session.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/tmux/tmux_service.dart';

import 'mosh_session_test.dart'
    show Monitor, config, moshHost, startApp, verifyFixture;

const scenario = String.fromEnvironment('X10_SCENARIO');

/// socks 场景用的 tool/fixture-environment（SOCKS5 + 只在容器网络里的 target），由脚本从它的 fixture.json 生成。
final socksConfig =
    jsonDecode(const String.fromEnvironment('X10_SOCKS', defaultValue: '{}'))
        as Map<String, dynamic>;

File? _logFile;

/// hostkill 场景里测试进程会被脚本杀掉、flutter 那头的输出跟着断：同样的行再写一份到 App 私有目录 x10/log.txt。
void report(String key, Object? value) {
  final line = 'X10 $key=$value';
  debugPrint(line);
  _logFile?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

Future<void> action(String name,
    {Duration timeout = const Duration(minutes: 10)}) async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/x10');
  final done = File('${dir.path}/$name');
  report('ACTION', name);
  final deadline = DateTime.now().add(timeout);
  while (!await done.exists()) {
    if (DateTime.now().isAfter(deadline)) fail('等脚本做「$name」超时');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  // 同名动作会做好几次（offline / online / home…）：回执不删，第二次就会不等脚本直接往下走。
  await done.delete();
  report('ACK', name);
}

Future<bool> until(bool Function() condition,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return true;
}

Future<void> sleep(int seconds) =>
    Future<void>.delayed(Duration(seconds: seconds));

/// 同一台测试环境上的普通 SSH 标签：用来看 Mosh 出事时它受不受牵连。
/// 走 adb reverse 的 127.0.0.1（脚本加的），不经模拟器网络：经 10.0.2.2 的话 Wi-Fi 一接管它就会被断、自动恢复成新对象，
/// 分不清是换网断的还是被 Mosh 牵连的（第一次跑 life 就撑上了）。
HostProfile sshHost(String id) => HostProfile({
      'id': id,
      'label': id,
      'hostname': '127.0.0.1',
      'port': config['sshPort'],
      'username': config['user'],
      'password': config['password'],
      'authMethod': 'password',
      'protocol': 'ssh',
      '_ephemeralTerminal': true,
    });

Future<ActiveTerminalSession> open(
    SessionController controller, HostProfile host) async {
  final before = controller.state.sessions.length;
  final ok = await controller.connect(host, verifyFixture);
  if (!ok || controller.state.sessions.length <= before) {
    fail('没连上 ${host.label}');
  }
  final tab = controller.state.sessions.last;
  if (!await until(() => tab.terminal.allText().contains(r'$'))) {
    fail('${host.label} 没出提示符');
  }
  return tab;
}

String describe(SessionController controller) => [
      for (final s in controller.state.sessions)
        '${s.host.label}:${s.connected ? 'up' : 'down'}'
            '${s.restoreHold == null ? '' : '/${s.restoreHold!.kind.name}'}',
    ].join(',');

var _probe = 0;

/// 在标签里跑一条 echo，等结果回到屏幕上；返回用时（毫秒），超时返回 null。
Future<int?> echo(SessionController controller, ActiveTerminalSession tab,
    String tag,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final marker = '$tag-${_probe++}';
  final sw = Stopwatch()..start();
  controller.typeInto(tab.id, 'echo $marker-\$((6*7))\r');
  final ok = await until(
      () => tab.terminal.allText().contains('$marker-42'),
      timeout: timeout);
  report('echo.$tag',
      ok ? '${sw.elapsedMilliseconds} ms' : 'TIMEOUT ${timeout.inSeconds}s');
  return ok ? sw.elapsedMilliseconds : null;
}

/// mosh-client 此刻在屏幕顶上画的状态条（「mosh: Last contact …」之类），没有就是空。
/// 只看当前这一屏：状态条消失后旧的还留在滚动历史里，用 allText() 会把它当成还在。
String moshBar(ActiveTerminalSession tab) => tab.terminal
    .recentLines(tab.terminal.viewRows)
    .map((l) => l.text.trim())
    .where((l) => l.contains('mosh:') || l.contains('Last contact'))
    .join(' / ');

/// 终端里宿主写的 Mosh 结束说明（「[Mosh] …」开头的那段），压成一行。
String moshNotice(ActiveTerminalSession tab) {
  final text = tab.terminal.allText();
  final at = text.lastIndexOf('[Mosh]');
  return at < 0 ? '' : text.substring(at).replaceAll('\n', '').trim();
}

/// 标签每次从连着变断开都记下来：换网、离线时宿主不该自己把 Mosh 标签判断开。
class DropWatch {
  DropWatch(this.tab) {
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_last && !tab.connected) drops++;
      _last = tab.connected;
    });
  }

  final ActiveTerminalSession tab;
  late final Timer _timer;
  var _last = true;
  var drops = 0;

  void stop() => _timer.cancel();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = config.isEmpty || scenario.isEmpty;

  testWidgets('X10 $scenario', (tester) async {
    final dir =
        Directory('${(await getApplicationSupportDirectory()).path}/x10');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    _logFile = File('${dir.path}/log.txt');
    await action('cellular-only');
    final (container, controller) = await startApp(tester);
    final monitor = await Monitor.open();
    await monitor.run('pkill -x mosh-server; rm -f /tmp/x10-*.log; true');
    monitor.close();
    switch (scenario) {
      case 'roam':
        await _roam(controller);
      case 'life':
        await _life(container.read(vaultControllerProvider.notifier),
            controller);
      case 'hostkill':
        await _hostkill(container.read(vaultControllerProvider.notifier),
            controller);
      case 'socks':
        await _socks(container.read(vaultControllerProvider.notifier),
            controller);
      case 'cycles':
        await _cycles(container.read(vaultControllerProvider.notifier),
            controller);
      case 'doze':
        await _doze(controller);
      default:
        fail('未知场景 $scenario');
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 40)));
}

/// MOS06：一个 Mosh 会话连着，Wi-Fi 开（默认网络换到 Wi-Fi）、关（换回蜂窝）、整机断网 30 秒和 150 秒、
/// 在后台时换网。每一步之后在会话里真跑一条命令；断网期间敲的命令写进远端文件，回来后数它执行了几次。
/// 宿主这边：不重新 bootstrap（远端 mosh-server 启动次数、SSH 登录次数不变）、不重发输入（终端输入次数 = 宿主写入次数）、
/// 不自己把标签判断开；mosh-client 是不是同一个进程由脚本按 pid 核对。
Future<void> _roam(SessionController controller) async {
  var monitor = await Monitor.open();
  final starts0 = await monitor.starts();
  monitor.close();
  final tab = await open(controller, moshHost('x10-roam'));
  final link = tab.plugin! as MoshTerminalProvider;
  report('opened', '${link.detail} ${describe(controller)}');
  final drops = DropWatch(tab);
  await action('pids-open');
  await echo(controller, tab, 'cell');

  await action('wifi-on');
  await echo(controller, tab, 'wifi-early');
  await sleep(45);
  await echo(controller, tab, 'wifi-late');
  await action('pids-wifi');

  await action('wifi-off');
  await echo(controller, tab, 'cell-again');

  // 断网期间敲命令：宿主当场写给插件一次，mosh 的协议负责网络回来后送到；远端文件里应当正好一行。
  for (final (name, seconds) in [('off30', 30), ('off150', 150)]) {
    await action('offline');
    final inputs = link.inputEvents;
    final writes = link.session.writeCount;
    controller.typeInto(
        tab.id, 'echo $name >> /tmp/x10-roam.log; echo $name-done-\$((6*7))\r');
    await sleep(seconds ~/ 2);
    report('$name.mid',
        'connected=${tab.connected} phase=${link.session.phase.name} bar="${moshBar(tab)}"');
    await sleep(seconds - seconds ~/ 2);
    report('$name.end',
        'connected=${tab.connected} phase=${link.session.phase.name} bar="${moshBar(tab)}" '
        'inputs=${link.inputEvents - inputs} writes=${link.session.writeCount - writes}');
    final sw = Stopwatch()..start();
    await action('online');
    final back = await until(
        () => tab.terminal.allText().contains('$name-done-42'),
        timeout: const Duration(seconds: 60));
    report('$name.back', back ? '${sw.elapsedMilliseconds} ms after online' : 'TIMEOUT');
    await sleep(3);
    report('$name.barAfter', '"${moshBar(tab)}"');
  }

  // 后台换网：HOME 之后开关 Wi-Fi，人不在前台时会话照样跟着走；命令由测试代敲（后台没有键盘）。
  await action('home');
  await action('wifi-on');
  await sleep(45);
  await echo(controller, tab, 'bg-wifi');
  await action('wifi-off');
  await echo(controller, tab, 'bg-cell');
  await action('facts-bg');
  await action('foreground');
  await echo(controller, tab, 'fg');
  await action('pids-end');

  drops.stop();
  monitor = await Monitor.open();
  final starts = await monitor.starts() - starts0;
  final lines = await monitor.run('cat /tmp/x10-roam.log');
  final running = await monitor.running();
  report('end',
      'moshServerStartsDelta=$starts running=$running drops=${drops.drops} connected=${tab.connected} '
      'terminalInputs=${link.inputEvents} hostWrites=${link.session.writeCount} dropped=${link.droppedInputBytes}');
  report('end.remoteFile', lines.replaceAll('\n', ','));
  await controller.close(controller.state.sessions.indexOf(tab));
  var left = await monitor.running();
  for (var i = 0; i < 50 && left > 0; i++) {
    await sleep(1);
    left = await monitor.running();
  }
  report('closed', 'serverLeft=$left stopConfirmed=${link.session.stopConfirmed}');
  monitor.close();

  expect(starts, 1, reason: '整轮只该起过一次 mosh-server');
  expect(drops.drops, 0, reason: '换网、离线时宿主不该自己把 Mosh 标签判断开');
  expect(link.inputEvents, link.session.writeCount, reason: '每次输入只写一次');
  expect(lines.split('\n'), ['off30', 'off150'],
      reason: '断网期间敲的命令到远端正好各执行一次');
  expect(left, 0);
}

/// MOS07 / PLG16 / 验收 2：旁边开着一个普通 SSH 标签，Mosh 这边依次遇到后台、运行时崩溃、插件崩溃、插件被强停、
/// 用户关标签、通知「全部断开」。每次：Mosh 标签如实结束、不自动重启 mosh-server、SSH 标签还是那个对象并能跑命令；
/// 「重新连接」入口能用、只新起一个 mosh-server。
Future<void> _life(
    VaultController vault, SessionController controller) async {
  // 「重新连接」按保险库里的主机连，不在保险库里就停在「已从保险库删掉」。
  await vault.upsertHost(moshHost('x10-life'));
  final moshStored =
      (await vault.ready()).hosts.firstWhere((value) => value.id == 'x10-life');
  final ssh = await open(controller, sshHost('x10-ssh'));
  var mosh = await open(controller, moshStored);
  final starts0 = await _starts();
  report('opened', describe(controller));

  Future<void> sshAlive(String step) async {
    final same = identical(
        controller.state.sessions.where((s) => s.id == ssh.id).firstOrNull,
        ssh);
    final ms = await echo(controller, ssh, 'ssh-$step');
    report('$step.ssh', 'sameTab=$same connected=${ssh.connected} echo=${ms ?? 'TIMEOUT'}');
    expect(same && ssh.connected && ms != null, isTrue,
        reason: '$step：SSH 标签受了牵连');
  }

  /// Mosh 标签结束以后：等 20 秒、换一次网、进出一次后台，远端不该多起 mosh-server。
  Future<void> endedQuietly(String step, int startsBefore) async {
    final link = mosh.plugin! as MoshTerminalProvider;
    final ended = await until(() => !mosh.connected,
        timeout: const Duration(seconds: 40));
    report('$step.ended',
        '$ended phase=${link.session.phase.name} failure=${link.session.failure} '
        'hold=${mosh.restoreHold?.kind.name} autoRestoreBlocked=${mosh.autoRestoreBlocked}');
    report('$step.notice', mosh.restoreHold?.message.replaceAll('\n', ' '));
    report('$step.screen', moshNotice(mosh));
    expect(ended, isTrue, reason: '$step：Mosh 标签没结束');
    final inputs = link.inputEvents;
    final writes = link.session.writeCount;
    controller.typeInto(mosh.id, 'echo after-$step\r');
    await action('wifi-toggle');
    await action('home');
    await sleep(5);
    await action('foreground');
    await sleep(15);
    await controller.reconnectDisconnected();
    final delta = await _starts() - startsBefore;
    report('$step.quiet',
        'startsDelta=$delta tabs=${describe(controller)} inputsAfterEnd=${link.inputEvents - inputs} '
        'writesAfterEnd=${link.session.writeCount - writes} dropped=${link.droppedInputBytes}');
    expect(delta, 0, reason: '$step：结束后自己又起了 mosh-server');
    expect(link.session.writeCount - writes, 0, reason: '$step：结束后的输入不该写出去');
    await action('pids-$step');
    await sshAlive(step);
  }

  /// 点「重新连接」（同状态条上那个按钮的调用）：只新起一个 mosh-server，新会话能用。
  Future<void> reconnect(String step) async {
    final before = await _starts();
    final index = controller.state.sessions.indexWhere((s) => s.id == mosh.id);
    await controller.reconnect(mosh.id, verifyHostKey: verifyFixture);
    final replaced = controller.state.sessions[index];
    final ok = !identical(replaced, mosh) && replaced.connected;
    mosh = replaced;
    if (ok) {
      await until(() => mosh.terminal.allText().contains(r'$'));
    }
    final ms = ok ? await echo(controller, mosh, 'reconnected-$step') : null;
    final delta = await _starts() - before;
    report('$step.reconnect', 'ok=$ok samePosition=${controller.state.sessions.indexOf(mosh) == index} '
        'startsDelta=$delta echo=${ms ?? 'TIMEOUT'}');
    expect(ok && ms != null, isTrue, reason: '$step：重新连接没连上');
    expect(delta, 1, reason: '$step：重新连接应当正好新起一个 mosh-server');
  }

  // ---- 后台 60 秒：两个标签照常收发；脚本看保活服务、通知、两个进程的优先级、唤醒锁、媒体会话 ----
  await action('home');
  await sleep(30);
  await echo(controller, mosh, 'bg-mosh');
  await echo(controller, ssh, 'bg-ssh');
  await action('facts-bg');
  await sleep(30);
  await action('foreground');
  await echo(controller, mosh, 'fg-mosh');

  // ---- 运行时崩溃：只给 mosh-client 发 SIGSEGV（插件进程还在）----
  var before = await _starts();
  await action('kill-client');
  await endedQuietly('clientCrash', before);
  await reconnect('clientCrash');

  // ---- 插件进程崩溃（am crash：未捕获异常，进程被系统收掉）----
  before = await _starts();
  await action('kill-plugin');
  await endedQuietly('pluginCrash', before);
  await reconnect('pluginCrash');

  // ---- 插件被强行停止（设置里「强行停止」那一下）----
  before = await _starts();
  await action('force-stop-plugin');
  await endedQuietly('pluginForceStop', before);
  await reconnect('pluginForceStop');

  // ---- 用户关 Mosh 标签 ----
  before = await _starts();
  final closing = mosh.plugin! as MoshTerminalProvider;
  await controller.close(controller.state.sessions.indexOf(mosh));
  await sleep(3);
  report('userClose', 'stopConfirmed=${closing.session.stopConfirmed} phase=${closing.session.phase.name} '
      'running=${await _running()} startsDelta=${await _starts() - before}');
  await action('pids-userClose');
  await sshAlive('userClose');

  // ---- 通知「全部断开」：这是用户的总开关，SSH 也一起停；之后换网、进出后台都不复活 ----
  // 远端「还在跑」的数里有前面崩溃、强停留下的孤儿（客户端来不及通知服务器），所以和开这个会话之前比，不和 0 比。
  var runningBefore = await _running();
  mosh = await open(controller, moshStored);
  before = await _starts();
  await action('home');
  await action('notify-stop');
  final allDown = await until(
      () => controller.state.sessions.every((s) => !s.connected),
      timeout: const Duration(seconds: 20));
  report('notifyStop', '$allDown ${describe(controller)} running=${await _running()}');
  report('notifyStop.notice', mosh.restoreHold?.message.replaceAll('\n', ' '));
  await action('wifi-toggle');
  await sleep(20);
  await action('foreground');
  await sleep(5);
  report('notifyStop.quiet', 'startsDelta=${await _starts() - before} running=${await _running()} tabs=${describe(controller)}');
  await action('pids-notifyStop');
  expect(allDown, isTrue);
  expect(await _starts(), before);
  expect(await _running(), runningBefore,
      reason: '「全部断开」后远端不该留着这个会话的 mosh-server');

  // ---- 系统停掉保活服务（App 在后台）：和「全部断开」走同一条收尾路，同样不复活 ----
  await open(controller, sshHost('x10-ssh2'));
  runningBefore = await _running();
  mosh = await open(controller, moshStored);
  before = await _starts();
  await action('home');
  await action('stop-service');
  final stopped = await until(
      () => controller.state.sessions.every((s) => !s.connected),
      timeout: const Duration(seconds: 20));
  report('svcStop', '$stopped ${describe(controller)}');
  report('svcStop.notice', mosh.restoreHold?.message.replaceAll('\n', ' '));
  await action('wifi-toggle');
  await sleep(20);
  await action('foreground');
  await sleep(5);
  report('svcStop.quiet', 'startsDelta=${await _starts() - before} running=${await _running()} tabs=${describe(controller)}');
  await action('pids-svcStop');
  report('end', 'moshServerStartsDelta=${await _starts() - starts0}');
  expect(stopped, isTrue);
  expect(await _starts(), before);
  expect(await _running(), runningBefore,
      reason: '服务被停后远端不该留着这个会话的 mosh-server');
}

/// PLG16「强制停止宿主」、MOS07「崩溃」：开着 SSH 和 Mosh 标签（主机存进保险库，标签清单随之写盘），
/// 然后等脚本把宿主进程杀掉。之后看什么、怎么放回标签，都是脚本的事（宿主没了，测试也没了）。
Future<void> _hostkill(
    VaultController vault, SessionController controller) async {
  final host = moshHost('x10-hostkill')..data['label'] = 'x10 mosh';
  await vault.upsertHost(host);
  final data = await vault.ready();
  await vault.replace(data.copyWith(extras: {
    ...data.extras,
    'knownHosts': [
      {
        'hostname': config['sshHost'],
        'port': config['sshPort'],
        'keyType': 'ssh-ed25519',
        'fingerprint': config['fingerprint'],
        'acceptedAt': DateTime.now().millisecondsSinceEpoch,
      },
    ],
  }));
  final stored =
      (await vault.ready()).hosts.firstWhere((value) => value.id == host.id);
  await open(controller, sshHost('x10-hk-ssh'));
  final mosh = await open(controller, stored);
  await echo(controller, mosh, 'before-kill');
  await sleep(2);
  report('SEEDED', describe(controller));
  await action('host-killed', timeout: const Duration(minutes: 30));
}

Future<String> exec(ActiveTerminalSession session, String command) async =>
    utf8.decode(await session.sshClient!.run(command), allowMalformed: true)
        .trim();

/// 验收 3（用户现在的 TailSocks 路径继续 SSH + tmux）的模拟器形态：TailSocks 在手机上就是本机的一个 SOCKS5 端口，
/// 这里是 adb reverse 过来的测试环境 SOCKS5（要用户名密码），后面是只在容器网络里的 target；在上面附着 tmux 会话 x10。
/// 旁边的 Mosh 标签换网、插件崩溃、插件被强停、重新连接、关标签：tmux 标签一直是同一个对象、连着、能跑命令，
/// 远端 tmux 还是那个会话（编号、创建时间不变）、只有一个客户端。
Future<void> _socks(
    VaultController vault, SessionController controller) async {
  final socks = socksConfig['socks'] as Map<String, dynamic>;
  final target = socksConfig['target'] as Map<String, dynamic>;
  final viaSocks = HostProfile({
    'id': 'x10-socks',
    'label': 'x10-socks',
    'hostname': target['name'],
    'port': target['port'],
    'username': socksConfig['user'],
    'password': socksConfig['password'],
    'authMethod': 'password',
    'protocol': 'ssh',
    '_ephemeralTerminal': true,
    'proxyConfig': {
      'type': 'socks5',
      'host': '127.0.0.1',
      'port': socks['port'],
      'username': socks['username'],
      'password': socks['password'],
    },
  });
  Future<bool> trustTarget(HostProfile host, String type, String fp) async =>
      fp == target['fingerprint'];
  final ok = await controller.connect(viaSocks, trustTarget);
  expect(ok, isTrue, reason: '经 SOCKS 连不上 target');
  final plain = controller.state.sessions.last;
  report('socks.route', plain.routePlan?.entry);
  await exec(plain,
      'tmux kill-session -t x10 2>/dev/null; tmux new-session -d -s x10 sh');
  final probe = await const TmuxService()
      .probe(plain.sshClient!, const TmuxSocketSpec.standard());
  final row = probe.sessions.firstWhere((value) => value.name == 'x10');
  await controller.openTmuxTerminal(
      plain,
      targetOf(row,
          hostKey: tmuxHostKeyOf(plain),
          unixUser: probe.unixUser,
          uid: probe.uid!,
          socket: const TmuxSocketSpec.standard()));
  final tmux = controller.state.sessions.last;
  await until(() => tmux.terminal.allText().contains(r'$'));
  Future<String> tmuxFacts() => exec(plain,
      "tmux display -p -t x10 '#{session_id} #{session_created}'; tmux list-clients -t x10 | wc -l");
  final facts0 = await tmuxFacts();
  report('socks.tmux', facts0.replaceAll('\n', ' clients='));

  await vault.upsertHost(moshHost('x10-socks-mosh'));
  var mosh = await open(
      controller,
      (await vault.ready())
          .hosts
          .firstWhere((value) => value.id == 'x10-socks-mosh'));
  report('opened', describe(controller));

  Future<void> tmuxAlive(String step) async {
    final same = identical(
        controller.state.sessions.where((s) => s.id == tmux.id).firstOrNull,
        tmux);
    final ms = await echo(controller, tmux, 'tmux-$step');
    final facts = await tmuxFacts();
    report('$step.tmux',
        'sameTab=$same connected=${tmux.connected} echo=${ms ?? 'TIMEOUT'} ${facts.replaceAll('\n', ' clients=')}');
    expect(same && tmux.connected && ms != null, isTrue,
        reason: '$step：经 SOCKS 的 tmux 标签受了牵连');
    expect(facts, facts0, reason: '$step：tmux 会话或客户端数变了');
  }

  Future<void> moshReconnect(String step) async {
    await until(() => !mosh.connected, timeout: const Duration(seconds: 40));
    final index = controller.state.sessions.indexWhere((s) => s.id == mosh.id);
    await controller.reconnect(mosh.id, verifyHostKey: verifyFixture);
    mosh = controller.state.sessions[index];
    await until(() => mosh.terminal.allText().contains(r'$'));
    report('$step.mosh', '${mosh.connected} echo=${await echo(controller, mosh, 'mosh-$step') ?? 'TIMEOUT'}');
  }

  await action('wifi-on');
  await sleep(45);
  await echo(controller, mosh, 'mosh-wifi');
  await tmuxAlive('wifi');
  await action('wifi-off');
  await echo(controller, mosh, 'mosh-cell');
  await tmuxAlive('cell');
  await action('kill-plugin');
  await moshReconnect('pluginCrash');
  await tmuxAlive('pluginCrash');
  await action('force-stop-plugin');
  await moshReconnect('pluginForceStop');
  await tmuxAlive('pluginForceStop');
  await controller.close(controller.state.sessions.indexOf(mosh));
  await sleep(3);
  await tmuxAlive('moshClosed');
  await exec(plain, 'tmux kill-session -t x10');
  report('end', describe(controller));
}

/// LIFE06 和跨 App 资源在 Mosh 这条路上的样子：Mosh 标签开 → 跑一条命令 → 关，100 轮（先热身 1 轮）。
/// 每 25 轮请脚本量宿主和插件两个进程的 Native Heap、PSS、fd、线程，设备上的 mosh-client 和远端还在跑的 mosh-server。
Future<void> _cycles(
    VaultController vault, SessionController controller) async {
  await vault.upsertHost(moshHost('x10-cycle'));
  final host =
      (await vault.ready()).hosts.firstWhere((value) => value.id == 'x10-cycle');
  var slow = 0;
  Future<void> cycle(int i) async {
    final tab = await open(controller, host);
    controller.typeInto(tab.id, 'echo cycle-$i-\$((6*7))\r');
    if (!await until(() => tab.terminal.allText().contains('cycle-$i-42'))) {
      slow++;
    }
    await controller.close(controller.state.sessions.indexOf(tab));
  }

  final sw = Stopwatch()..start();
  await cycle(0);
  for (var i = 0; i <= 100; i++) {
    if (i % 25 == 0) {
      await sleep(5);
      await action('mem-$i');
    }
    if (i < 100) await cycle(i + 1);
  }
  report('cycles',
      '101 rounds in ${sw.elapsed.inSeconds} s, echoTimeouts=$slow running=${await _running()} tabs=${controller.state.sessions.length}');
  expect(slow, 0);
}

/// 息屏 + 深度 Doze（模拟器上强制进）：Doze 按 uid 断网，前台服务进程豁免。插件进程是被宿主的前台服务绑着的，
/// 按理跟着豁免，这里实测 mosh-client 在 Doze 里还能不能收发。模拟器的 CPU 不会真睡，真机上另说。
Future<void> _doze(SessionController controller) async {
  final starts0 = await _starts();
  final tab = await open(controller, moshHost('x10-doze'));
  final drops = DropWatch(tab);
  await echo(controller, tab, 'awake');
  await action('home');
  await action('doze-on');
  await sleep(30);
  await echo(controller, tab, 'doze-30s');
  await sleep(60);
  await echo(controller, tab, 'doze-90s');
  await action('facts-doze');
  await action('doze-off');
  await action('foreground');
  await echo(controller, tab, 'awake-again');
  drops.stop();
  final starts = await _starts() - starts0;
  report('end', 'moshServerStartsDelta=$starts drops=${drops.drops} connected=${tab.connected}');
  await controller.close(controller.state.sessions.indexOf(tab));
  expect(starts, 1);
  expect(drops.drops, 0);
}

Future<int> _starts() async {
  final monitor = await Monitor.open();
  try {
    return await monitor.starts();
  } finally {
    monitor.close();
  }
}

Future<int> _running() async {
  final monitor = await Monitor.open();
  try {
    return await monitor.running();
  } finally {
    monitor.close();
  }
}
