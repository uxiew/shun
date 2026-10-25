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

/// 查 Dart 堆：第一个和最后一个采样点各取一次分配档案（先 GC），打出实例数、字节数涨得最多的类。
/// 这一轮的 Native Heap 读数不算：取档案本身会留下一大块原生内存。
const _classDiff = bool.fromEnvironment('LIFE06_CLASSDIFF');

/// 每轮都连同一台主机（同一个 ID），和用户反复开关同一台机器一样。不开时每轮是新主机：
/// 按主机记的东西（连接记录每台最多 200 条、一共 1000 条）会一直涨到上限，算进「每轮增长」。
const _sameHost = bool.fromEnvironment('LIFE06_SAME_HOST');

/// 一开始就关掉 Dart 时间线（setVMTimelineFlags 不记任何流）。debug / profile 包的时间线记录器给每个异步事件 ID
/// 存一条元数据、不删，引擎每请求一帧就发一个新 ID：原生内存按帧涨，和开关标签无关。
/// 发布版引擎里这一步是空函数（10-25 看过反汇编），关掉它量出来的更接近发布包。
const _timelineOff = bool.fromEnvironment('LIFE06_TIMELINE_OFF');

/// 和 LIFE06_CLASSDIFF 一起用：这几个类（逗号分隔，写法同「grew=」那一行的 类名@库；
/// auto = 涨得最多的 6 个）打引用链。
/// 输出里每一节是「类.字段」：这个对象放在下一节的哪个字段里（[] 列表、{} Map），最后是 GC 根。
const _retainers = String.fromEnvironment('LIFE06_RETAINERS');

/// 类快照的基线在第几轮取（0 = 第一个采样点）。要等有上限的历史（连接记录每台 200 条、服务器监控 60 条）封顶以后再取，
/// 不然它们还在长的那段会算成增长。
const _classDiffAt = int.fromEnvironment('LIFE06_CLASSDIFF_AT');

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

  /// [vmLevel]：整个 VM 的方法（setVMTimelineFlags 这类），带上 isolateId 会报 Invalid params。
  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> params,
      {bool vmLevel = false}) async {
    final my = '${++_id}';
    final reply = _replies.firstWhere((r) => r['id'] == my);
    _ws.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': my,
      'method': method,
      'params': {if (!vmLevel) 'isolateId': isolateId, ...params},
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
    if (_timelineOff) {
      await vm.call('setVMTimelineFlags', {'recordedStreams': <String>[]},
          vmLevel: true);
      final flags = await vm.call('getVMTimelineFlags', {}, vmLevel: true);
      report('timeline', flags['recordedStreams']);
    }

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
          'id': _sameHost ? 'life06-cycle' : 'life06-${++tabs}',
          'label': _sameHost ? 'life06-cycle' : 'life06-$tabs',
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
    report('cycles',
        '$_cycles every=$_every profileAt=$_profileAt sameHost=$_sameHost timelineOff=$_timelineOff');

    final classIds = <String, String>{};
    Future<Map<String, (int, int)>> classes({bool keepIds = false}) async {
      final profile = await vm.call('getAllocationProfile', {'gc': true});
      final out = <String, (int, int)>{};
      for (final member
          in (profile['members'] as List).cast<Map<String, dynamic>>()) {
        final cls = member['class'] as Map<String, dynamic>;
        final name = '${cls['name']}@${(cls['library'] as Map?)?['uri'] ?? ''}';
        final count = member['instancesCurrent'] as int? ?? 0;
        final bytes = member['bytesCurrent'] as int? ?? 0;
        if (count > 0) {
          final (c0, b0) = out[name] ?? (0, 0);
          out[name] = (c0 + count, b0 + bytes);
          if (keepIds) classIds[name] = cls['id'] as String;
        }
      }
      return out;
    }

    // 涨得多的类各挑一批实例问「谁拿着它」，按引用链的样子归堆：新旧实例混在一起挑不出来，
    // 但谁在攻一个大列表，它的链会在样本里反复出现。
    Future<void> reportRetainers(Iterable<String> names) async {
      for (final name in names) {
        final id = classIds[name];
        if (id == null) continue;
        final set =
            await vm.call('getInstances', {'objectId': id, 'limit': 4000});
        final instances =
            (set['instances'] as List).cast<Map<String, dynamic>>();
        final paths = <String, int>{};
        final step = instances.length <= 60 ? 1 : instances.length ~/ 60;
        for (var i = 0; i < instances.length; i += step) {
          final path = await vm.call('getRetainingPath',
              {'targetId': instances[i]['id'], 'limit': 10});
          // 取的时候已经被回收了：返回的是 Sentinel，没有 elements。
          final elements = (path['elements'] as List? ?? const [])
              .cast<Map<String, dynamic>>();
          final key = [
            for (final e in elements.skip(1))
              '${(e['value'] as Map)['class']?['name'] ?? (e['value'] as Map)['type']}'
                  '${e['parentField'] is String ? '.${e['parentField']}' : e['parentListIndex'] != null ? '[]' : e['parentMapKey'] != null ? '{}' : ''}',
            path['gcRootType'] ?? '',
          ].join(' < ');
          paths[key] = (paths[key] ?? 0) + 1;
        }
        report('retainers',
            '$name total=${set['totalCount']} sampled=${paths.values.fold(0, (a, b) => a + b)}');
        for (final MapEntry(:key, :value) in (paths.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(6)) {
          report('retainedBy', '$value x $key');
        }
      }
    }

    List<(String, int, int)> reportGrowth(
        Map<String, (int, int)> before, Map<String, (int, int)> after) {
      final grown = [
        for (final MapEntry(:key, :value) in after.entries)
          (
            key,
            value.$1 - (before[key]?.$1 ?? 0),
            value.$2 - (before[key]?.$2 ?? 0)
          ),
      ]..sort((a, b) => b.$3.compareTo(a.$3));
      for (final (name, count, bytes) in grown.take(25)) {
        report('grew', '$bytes B, $count instances: $name');
      }
      return grown;
    }

    // 热身的那一段（JIT 编译、缓存长到台阶）不算：第 LIFE06_CLASSDIFF_AT 轮（默认第一个采样点）才取第一份。
    // 第一份压成一个 JSON 字符串存着：留着 Map 的话，它自己的几千个类名字符串和 record 会被
    // 第二份算成「涨了」（10-25 第一次这么量，涨得最多的三个类大半是它）。
    String? firstClasses;
    await sample('c0');
    final watch = Stopwatch()..start();
    for (var c = 1; c <= _cycles; c++) {
      await cycle();
      if (c % _every == 0) {
        report('c$c.elapsedS', watch.elapsed.inSeconds);
        await sample('c$c');
        if (_classDiff && c == (_classDiffAt > 0 ? _classDiffAt : _every)) {
          firstClasses = jsonEncode({
            for (final MapEntry(:key, :value) in (await classes()).entries)
              key: [value.$1, value.$2],
          });
        }
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
    if (firstClasses != null) {
      // 先取第二份、再解码第一份：反过来的话解码出来的几千个 record 和字符串又被算成「涨了」。
      final after = await classes(keepIds: true);
      final before = {
        for (final MapEntry(:key, :value)
            in (jsonDecode(firstClasses) as Map<String, dynamic>).entries)
          key: ((value as List)[0] as int, value[1] as int),
      };
      final grown = reportGrowth(before, after);
      await reportRetainers(_retainers == 'auto'
          ? grown.where((g) => g.$2 > 0).take(6).map((g) => g.$1)
          : _retainers.split(',').where((n) => n.isNotEmpty));
    }
    for (var i = controller.state.sessions.length - 1; i >= 0; i--) {
      await controller.close(i);
    }
    await settle(tester, 1500);
  }, skip: ssh == null, timeout: const Timeout(Duration(minutes: 90)));
}
