// LIFE06 查来源：开关标签时 Native Heap 每轮涨的那部分，是真漏，还是「等 GC 才还」的原生内存。
//
// R20 / R22 量到的约 40 KiB/次是在没强制 GC 时读的 dumpsys meminfo。两类原生内存要等 GC 才释放：
// Flutter 引擎里挂在 Dart 对象上的原生对象（段落、路径、图层……，Dart 对象被回收才 free），
// 和 Java 侧的 DirectByteBuffer（平台通道每条消息都用，Java GC 后才 free）。这里每个采样点读三次：
// 不 GC、Dart GC 后、再加 Java GC 后，看斜率在哪一步消失。
//
// 不是 CI 测试，只用 tool/life06-device.py 跑。输出以 "LIFE06 " 开头的行是证据，也是给脚本的指令：
//   LIFE06 VMSERVICE=<ws 地址>  脚本把同一个端口 adb reverse 回电脑（测试要连自己的 VM service 做 Dart GC）
//   LIFE06 MEM <名字>          脚本抓一次 dumpsys meminfo，抓完在私有目录放 life06-<名字>-done
//   LIFE06 JAVAGC <名字>       脚本用 run-as 发 SIGUSR1（ART 收到就做一次完整 GC）、等 3 秒、再抓 meminfo
// LIFE06_MODE：view 终端页显示着开关（和 R20 resources 一样吃 64 KiB 输出）；hidden 停在保险库页只开关 SSH。
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';

const _ssh = String.fromEnvironment('R17_SSH');
const _mode = String.fromEnvironment('LIFE06_MODE', defaultValue: 'view');
const _cycles = int.fromEnvironment('LIFE06_CYCLES', defaultValue: 300);
const _every = int.fromEnvironment('LIFE06_EVERY', defaultValue: 50);

/// 对照用：在第几轮采完样后调一次 getAllocationProfile(gc: true)，和 R20 / R22 的 resources 场景一样。
/// 那两次量的「第 100 → 500 次 +15 MiB」中间夹着一次这个调用。0 = 不调。
const _profileAt = int.fromEnvironment('LIFE06_PROFILE_AT');

void report(String key, Object? value) => debugPrint('LIFE06 $key=$value');

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> waitFor(WidgetTester tester, bool Function() condition,
    {Duration timeout = const Duration(seconds: 30),
    String what = '条件'}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 本进程自己的 VM service（debug 包才有），用 dart:io 的 WebSocket 发 JSON-RPC。和 r20_gate_test 的一样。
class _Vm {
  _Vm._(this._ws, this._replies, this.isolateId);
  final WebSocket _ws;
  final Stream<Map<String, dynamic>> _replies;
  final String isolateId;
  var _id = 0;

  static Future<_Vm> connect() async {
    final info = await developer.Service.getInfo();
    WebSocket? socket;
    for (var attempt = 0; socket == null; attempt++) {
      try {
        socket = await WebSocket.connect(info.serverWebSocketUri.toString());
      } on SocketException {
        if (attempt >= 60) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    final replies = socket
        .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
        .asBroadcastStream();
    return _Vm._(
        socket, replies, developer.Service.getIsolateId(Isolate.current)!);
  }

  Future<Map<String, dynamic>> call(
      String method, Map<String, dynamic> params) async {
    final my = '${++_id}';
    final reply = _replies.firstWhere((r) => r['id'] == my);
    _ws.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': my,
      'method': method,
      'params': {'isolateId': isolateId, ...params},
    }));
    final result = await reply;
    if (result['error'] != null) {
      throw StateError('$method: ${result['error']}');
    }
    return result['result'] as Map<String, dynamic>;
  }

  Future<void> close() => _ws.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final ssh = _ssh.isEmpty ? null : jsonDecode(_ssh) as Map<String, dynamic>;

  testWidgets('LIFE06：开关标签，每个采样点读不 GC / Dart GC / 再加 Java GC 三次 Native Heap',
      (tester) async {
    final private = (await getApplicationSupportDirectory()).path;
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    container.read(homeTabProvider.notifier).state = _mode == 'view' ? 1 : 0;
    await settle(tester, 1500);
    final controller = container.read(sessionControllerProvider.notifier);

    final info = await developer.Service.getInfo();
    debugPrint('LIFE06 VMSERVICE=${info.serverWebSocketUri}');
    final vm = await _Vm.connect();
    addTearDown(vm.close);

    Future<void> host(String verb, String name) async {
      final done = File('$private/life06-$name-done');
      if (done.existsSync()) done.deleteSync();
      debugPrint('LIFE06 $verb $name');
      await waitFor(tester, done.existsSync,
          timeout: const Duration(seconds: 60), what: '脚本 $verb $name');
    }

    Future<void> sample(String name) async {
      await settle(tester, 1000);
      await host('MEM', '$name-raw');
      // 只做 GC，不取分配档案：getAllocationProfile 要把几千个类序列化成 JSON，第一次试时
      // Native Heap 因此多了约 15 MB，把要量的东西盖住了。
      await vm.call('_collectAllGarbage', {});
      final usage = await vm.call('getMemoryUsage', {});
      report('$name.dart',
          'heapKiB=${(usage['heapUsage'] as int) ~/ 1024} externalKiB=${(usage['externalUsage'] as int) ~/ 1024}');
      await settle(tester, 1000);
      await host('MEM', '$name-dartgc');
      await host('JAVAGC', '$name-allgc');
    }

    var tabs = 0;
    var runs = 0;
    Future<void> cycle() async {
      final before = controller.state.sessions.length;
      final connected = controller.connect(
        HostProfile({
          'id': 'life06-${++tabs}',
          'label': 'life06-$tabs',
          'hostname': '127.0.0.1',
          'port': ssh!['port'],
          'username': ssh['user'],
          'password': ssh['password'],
          'authMethod': 'password',
          'protocol': 'ssh',
          '_ephemeralTerminal': true,
        }),
        (_, __, fingerprint) async => fingerprint == ssh['fingerprint'],
      );
      await waitFor(tester, () => controller.state.sessions.length > before,
          what: '连上');
      expect(await connected, isTrue);
      final ActiveTerminalSession session = controller.state.sessions.last;
      if (_mode == 'view') {
        controller.activate(controller.state.sessions.indexOf(session));
        final n = 5000 + ++runs;
        // 截在 64 KiB 处可能正好切在颜色序列中间（\033[3），后面的完成标记会被终端当成序列参数吞掉；
        // 先补一个 ESC 开头的复位，把没完的序列打断。
        session.terminal.sendText(
            "head -c 65536 /tmp/life06.txt; printf '\\033[0m\\n'; echo L6D\$(($n))\r");
        await waitFor(
            tester, () => session.terminal.allText().contains('L6D$n'),
            what: '输出');
      } else {
        await session.sshClient!.run('true');
      }
      await controller.close(controller.state.sessions.indexOf(session));
      await settle(tester, 150);
    }

    // 一个常驻标签：生成输出素材，也让终端页一直有东西（和 R20 resources 一样不是空页开关）。
    await cycle(); // 热一下连接路径
    final keeper = controller.connect(
      HostProfile({
        'id': 'life06-keeper',
        'label': 'life06-keeper',
        'hostname': '127.0.0.1',
        'port': ssh!['port'],
        'username': ssh['user'],
        'password': ssh['password'],
        'authMethod': 'password',
        'protocol': 'ssh',
        '_ephemeralTerminal': true,
      }),
      (_, __, fingerprint) async => fingerprint == ssh['fingerprint'],
    );
    expect(await keeper, isTrue);
    await controller.state.sessions.last.sshClient!.run(
        r"""awk 'BEGIN{for(i=0;i<3000;i++) printf "\033[3%dm第%05d行 中文输出 🙂 abc\033[0m\n", i%8, i}' > /tmp/life06.txt""");
    report('mode', _mode);
    report('cycles', '$_cycles every=$_every profileAt=$_profileAt');

    await sample('c0');
    final watch = Stopwatch()..start();
    for (var c = 1; c <= _cycles; c++) {
      await cycle();
      if (c % _every == 0) {
        report('c$c.elapsedS', watch.elapsed.inSeconds);
        await sample('c$c');
        if (c == _profileAt) {
          final profile = await vm.call('getAllocationProfile', {'gc': true});
          report('c$c.allocationProfileClasses',
              (profile['members'] as List).length);
          // 调完马上再量一次：多出来的就是这一下留下的，和开关标签无关。
          await sample('c${c}p');
        }
      }
    }
    report('sessionsLeft', controller.state.sessions.length);
    for (var i = controller.state.sessions.length - 1; i >= 0; i--) {
      await controller.close(i);
    }
    await settle(tester, 1500);
  }, skip: ssh == null, timeout: const Timeout(Duration(minutes: 90)));
}
