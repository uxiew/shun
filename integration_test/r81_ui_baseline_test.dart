// R81: the current ShunApp in profile mode, on the disposable project AVD.
// Run only through tool/r81-ui-baseline.py. No production account is needed.
// These JSON files contain raw FrameTiming records, NOT a full VM timeline.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import '../test/support/home_navigation.dart';
import 'package:shun/presentation/home_shell.dart';
import 'package:shun/presentation/screens/settings_screen.dart';
import 'package:shun/presentation/screens/tailscale_settings_screen.dart';
import 'package:shun/presentation/screens/vault_screen.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/session_overview.dart';

const _rawFixture = String.fromEnvironment('R81_FIXTURE');
const _runId = String.fromEnvironment('R81_RUN_ID');
const _smoke = bool.fromEnvironment('R81_SMOKE');
const _warmSeconds = _smoke ? 1 : 5;
const _sampleSeconds = _smoke ? 3 : 30;
const _repeats = _smoke ? 1 : 3;
const _cycles = _smoke ? 3 : 100;
const _seedBytesPerSession = 1310720; // Four sessions: exactly 5 MiB of corpus.
const _sceneNames = [
  'settings-scroll',
  'hosts-scroll',
  'host-editor',
  'tailscale-nonmodal',
  'input-panel',
  'tabs',
  'vt-overview',
];

void _mark(String message) => debugPrint('R81 $message');
Finder _key(String key) => find.byKey(ValueKey(key));
Future<void> _delay(int milliseconds) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

Future<void> _waitFor(bool Function() ready, String reason,
    {int seconds = 30}) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed.inSeconds >= seconds) fail('R81 timeout: $reason');
    await _delay(25);
  }
}

/// Same self-VM JSON-RPC transport used by LIFE06. Avoid getAllocationProfile:
/// its allocation report changes the native-heap baseline being measured.
class _Vm {
  _Vm(this.socket, this.replies, this.isolateId);
  final WebSocket socket;
  final Stream<Map<String, dynamic>> replies;
  final String isolateId;
  var serial = 0;

  static Future<_Vm> connect() async {
    final info = await developer.Service.getInfo();
    WebSocket? socket;
    for (var attempt = 0; socket == null; attempt++) {
      try {
        socket = await WebSocket.connect(info.serverWebSocketUri.toString());
      } on SocketException {
        if (attempt >= 40) rethrow;
        await _delay(500);
      }
    }
    return _Vm(
      socket,
      socket
          .map((event) => jsonDecode(event as String) as Map<String, dynamic>)
          .asBroadcastStream(),
      developer.Service.getIsolateId(Isolate.current)!,
    );
  }

  Future<Map<String, dynamic>> call(String method,
      [Map<String, Object?> parameters = const {}, bool vmLevel = false]) async {
    final id = '${++serial}';
    final answer = replies.firstWhere((event) => event['id'] == id);
    socket.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': {if (!vmLevel) 'isolateId': isolateId, ...parameters},
    }));
    final result = await answer.timeout(const Duration(seconds: 20));
    if (result['error'] != null) {
      throw StateError('R81 VM method failed: $method ${result['error']}');
    }
    return result['result'] as Map<String, dynamic>;
  }

  Future<void> close() async {
    await socket.close();
  }
}

class _Evidence {
  _Evidence(this.root);
  final Directory root;
  final files = <String>[];
  final memory = <String, Map<String, Object?>>{};

  Future<void> gate(String verb, String name) async {
    final ack = File('${root.path}/ack-${verb.toLowerCase()}-$name');
    if (await ack.exists()) await ack.delete();
    _mark('$verb $name');
    await _waitFor(ack.existsSync, 'host $verb $name', seconds: 60);
    await ack.delete();
  }

  Future<void> write(String name, Object value) async {
    await File('${root.path}/$name').writeAsString(jsonEncode(value), flush: true);
    files.add(name);
    await gate('FILE', name);
  }

  Future<void> sample(_Vm vm, String name) async {
    // Outside frame capture. Raw and normalized readings are kept separately.
    await _delay(750);
    final raw = await vm.call('getMemoryUsage');
    memory['$name-raw'] = {
      ...raw,
      'rssBytes': ProcessInfo.currentRss,
      'gc': 'natural',
    };
    await gate('MEM', '$name-raw');
    await vm.call('_collectAllGarbage');
    await _delay(500);
    // The host asks ART to collect DirectByteBuffers, then captures dumpsys.
    await gate('JAVAGC', '$name-allgc');
    final normalized = await vm.call('getMemoryUsage');
    memory['$name-allgc'] = {
      ...normalized,
      'rssBytes': ProcessInfo.currentRss,
      'gc': 'dart-and-art',
    };
  }
}

Future<int> _repeatFor(
    Duration duration, Future<void> Function() action) async {
  final watch = Stopwatch()..start();
  var actions = 0;
  while (watch.elapsed < duration) {
    await action();
    actions++;
  }
  return actions;
}

double _percentile(List<int> values, double fraction) {
  final sorted = [...values]..sort();
  final index = (sorted.length * fraction).ceil() - 1;
  return sorted[index] / 1000;
}

Future<Map<String, Object?>> _capture(
  WidgetTester tester,
  _Evidence evidence,
  String scene,
  int repetition,
  Future<void> Function() action,
) async {
  final timings = <FrameTiming>[];
  final startUs = developer.Timeline.now;
  var endUs = 1 << 62;
  void collect(List<FrameTiming> batch) {
    for (final frame in batch) {
      final at = frame.timestampInMicroseconds(FramePhase.vsyncStart);
      if (at >= startUs && at < endUs) timings.add(frame);
    }
  }

  final hz = tester.view.display.refreshRate;
  expect(hz, greaterThan(0), reason: 'A real refresh rate is required');
  SchedulerBinding.instance.addTimingsCallback(collect);
  var actions = 0;
  try {
    actions = await _repeatFor(
        const Duration(seconds: _sampleSeconds), action);
    endUs = developer.Timeline.now;
    // Profile timings arrive in batches. Let the last batch arrive, filtering
    // by the engine timestamp so neither warm-up nor the drain joins the window.
    await _delay(350);
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(collect);
  }
  expect(timings.length, greaterThan(1),
      reason: 'No usable natural FrameTiming samples; this is not a baseline');
  expect(tester.view.display.refreshRate, hz,
      reason: 'Refresh rate changed during capture');
  final budgetUs = 1000000 / hz;
  final builds = [for (final frame in timings) frame.buildDuration.inMicroseconds];
  final rasters = [for (final frame in timings) frame.rasterDuration.inMicroseconds];
  final janky = timings.where((frame) =>
      frame.buildDuration.inMicroseconds > budgetUs ||
      frame.rasterDuration.inMicroseconds > budgetUs).length;
  final summary = <String, Object?>{
    'scene': scene,
    'repetition': repetition,
    'windowStartUs': startUs,
    'windowEndUs': endUs,
    'measuredSeconds': (endUs - startUs) / 1000000,
    'actions': actions,
    'frames': timings.length,
    'refreshHz': hz,
    'frameBudgetMs': 1000 / hz,
    'buildP95Ms': _percentile(builds, .95),
    'rasterP95Ms': _percentile(rasters, .95),
    'jankFrames': janky,
    'jankRatio': janky / timings.length,
  };
  await evidence.write('$scene-$repetition.frames.json', {
    'format': 'shun-r81-frame-timings-v1',
    'traceKind': 'raw-frame-records-not-vm-timeline',
    ...summary,
    'frameTimings': [
      for (final frame in timings)
        {
          'vsyncStartUs': frame.timestampInMicroseconds(FramePhase.vsyncStart),
          'buildStartUs': frame.timestampInMicroseconds(FramePhase.buildStart),
          'buildFinishUs': frame.timestampInMicroseconds(FramePhase.buildFinish),
          'rasterStartUs': frame.timestampInMicroseconds(FramePhase.rasterStart),
          'rasterFinishUs': frame.timestampInMicroseconds(FramePhase.rasterFinish),
          'buildUs': frame.buildDuration.inMicroseconds,
          'rasterUs': frame.rasterDuration.inMicroseconds,
          'totalSpanUs': frame.totalSpan.inMicroseconds,
        },
    ],
  });
  timings.clear(); // Do not retain raw traces while sampling process memory.
  return summary;
}

String _recent(ActiveTerminalSession session) =>
    session.terminal.recentLines(30).map((line) => line.text).join('\n');

int _tick(ActiveTerminalSession session, int index) {
  final matches = RegExp('R81T$index:([0-9]+)').allMatches(_recent(session));
  return matches.isEmpty ? -1 : int.parse(matches.last.group(1)!);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Respect the app/engine's frame requests; never manufacture frames by pumping.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('R81 current UI: profile frames, fixture SSH and resources',
      (tester) async {
    expect(kProfileMode, isTrue, reason: 'Use flutter drive --profile --no-dds');
    expect(Platform.isAndroid, isTrue);
    expect(_rawFixture, isNotEmpty, reason: 'Use tool/r81-ui-baseline.py');
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(_runId), isTrue);
    final fixture = jsonDecode(_rawFixture) as Map<String, dynamic>;
    final root = Directory(
        '${(await getApplicationSupportDirectory()).path}/r81');
    await root.create(recursive: true);
    final evidence = _Evidence(root);
    await evidence.gate('CONFIG', 'run');
    final config = jsonDecode(await File('${root.path}/config.json').readAsString())
        as Map<String, dynamic>;
    final stage = config['stage'] as String;
    const groups = <String, List<String>>{
      'all': _sceneNames,
      'lists': ['settings-scroll', 'hosts-scroll'],
      'panels': ['host-editor', 'tailscale-nonmodal', 'input-panel'],
      'terminal': ['tabs', 'vt-overview'],
      'lifecycle': [],
    };
    expect(groups.containsKey(stage), isTrue);
    expect(_smoke || stage != 'all', isTrue,
        reason: 'Run the baseline in four bounded stages');
    final sceneNames = groups[stage]!;
    final cycles = stage == 'all' || stage == 'lifecycle' ? _cycles : 0;
    final repository = await VaultRepository.open();
    await repository.saveSettings(const AppSettings(
      themeMode: 'dark',
      uiThemeId: 'tokyo-night',
      language: 'zh-CN',
      serverViewMode: 'list',
      terminalInputMode: terminalInputKeys,
      terminalFontSize: 14,
    ));
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    final vault = container.read(vaultControllerProvider.notifier);
    await vault.ready();
    await vault.replace(VaultData.fromJson({
      'hosts': [
        for (var i = 0; i < 100; i++)
          {
            'id': 'r81-host-$i',
            'label': 'R81 主机 ${i.toString().padLeft(3, '0')}',
            'hostname': '127.0.0.1',
            'port': fixture['port'],
            'username': 'fixture',
            'protocol': 'ssh',
            'group': '',
          },
      ],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'identities': const [],
      'proxyProfiles': const [],
    }));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await _waitFor(
        () => find.byType(HomeShell).evaluate().isNotEmpty, 'HomeShell');
    await _delay(1000);
    final service = await developer.Service.getInfo();
    await evidence.gate('VMPORT', '${service.serverWebSocketUri!.port}');
    final vm = await _Vm.connect();
    addTearDown(vm.close);
    await vm.call('setVMTimelineFlags', {'recordedStreams': <String>[]}, true);
    final flags = await vm.call('getVMTimelineFlags', const {}, true);
    expect(flags['recordedStreams'], isEmpty,
        reason: 'VM timeline must be off for the native-heap baseline');

    final controller = container.read(sessionControllerProvider.notifier);
    Future<void> select(int tab) async {
      container.read(homeTabProvider.notifier).state = tab;
      await _delay(400);
    }

    HostProfile host(String id) => HostProfile({
      'id': id,
      'label': id.replaceFirst('r81-', ''),
      'hostname': '127.0.0.1',
      'port': fixture['port'],
      'username': fixture['user'],
      'password': fixture['password'],
      'authMethod': 'password',
      'protocol': 'ssh',
      '_ephemeralTerminal': true,
    });

    Future<ActiveTerminalSession> connect(String id) async {
      final before = controller.state.sessions.length;
      final connected = await controller.connect(
        host(id),
        (_, __, fingerprint) async => fingerprint == fixture['fingerprint'],
      ).timeout(const Duration(seconds: 40));
      expect(connected, isTrue, reason: 'Controlled fixture SSH must connect');
      expect(controller.state.sessions.length, before + 1);
      final session = controller.state.sessions.last;
      expect(session.terminal.engine, 'Ghostty');
      await _waitFor(() => _recent(session).trim().isNotEmpty, 'SSH prompt');
      return session;
    }

    final sessions = <ActiveTerminalSession>[];
    // Always clean up connections, including when a scenario fails.
    addTearDown(() async {
      for (var i = controller.state.sessions.length - 1; i >= 0; i--) {
        await controller.close(i);
      }
    });
    await select(1);
    for (var i = 0; i < 4; i++) {
      sessions.add(await connect('r81-live-$i'));
    }
    final remote = '/tmp/shun-r81-$_runId-$stage';
    const producer = r'''#!/bin/sh
limit="$2"
index="$1"
i=0
trap 'exit 0' INT TERM
while [ "$i" -lt "$limit" ]; do
  printf '\033[3%dmR81T%s:%06d 中文输出 abc 0123456789\033[0m\r\n' "$((i%8))" "$index" "$i"
  i=$((i+1))
  sleep 0.05
done
''';
    final encoded = base64.encode(utf8.encode(producer));
    final setup = '''
mkdir -p $remote &&
awk 'BEGIN{for(i=0;i<60000;i++) printf "\\033[3%dm第%05d行 中文输出 abc 0123456789\\033[0m\\n", i%8, i}' > $remote/source &&
head -c $_seedBytesPerSession $remote/source > $remote/load &&
rm $remote/source &&
printf '%s' '$encoded' | base64 -d > $remote/stream.sh
''';
    await sessions.first.sshClient!.run(setup);
    final corpusSize = utf8.decode(
        await sessions.first.sshClient!.run('wc -c < $remote/load')).trim();
    expect(int.parse(corpusSize), _seedBytesPerSession);
    addTearDown(() async {
      if (sessions.first.connected) {
        await sessions.first.sshClient!.run('rm -rf $remote');
      }
    });

    Future<void> load(ActiveTerminalSession session, int marker,
        {bool small = false}) async {
      session.terminal.sendText(
          '${small ? 'head -c 65536' : 'cat'} $remote/load; '
          "printf '\\033[0m\\r\\n'; echo R81_SEED_\$(($marker))\r");
      await _waitFor(
          () => _recent(session).contains('R81_SEED_$marker'), 'VT corpus',
          seconds: 90);
    }

    for (var i = 0; i < sessions.length; i++) {
      controller.activate(i);
      await load(sessions[i], 8000 + i);
    }
    controller.activate(0);
    await _delay(500);
    final hide = _key('terminal-action-hide-keyboard');
    final toggle = _key('terminal-action-input-panel');
    final panel = _key('terminal-input-panel');
    Future<void> hidePanel() async {
      if (panel.evaluate().isNotEmpty) {
        await tester.tap(hide);
        await _waitFor(() => panel.evaluate().isEmpty, 'close input panel');
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await _delay(450);
    }
    await hidePanel();
    final media = MediaQuery.of(tester.element(find.byType(HomeShell)));
    final manifest = <String, Object?>{
      'format': 'shun-r81-ui-baseline-v1',
      'mode': _smoke ? 'smoke-not-baseline' : 'baseline',
      'runId': _runId,
      'stage': stage,
      'processBoundary': 'fresh process and the same fixture per stage',
      'profile': kProfileMode,
      'framePolicy': binding.framePolicy.name,
      'timelineStreams': flags['recordedStreams'],
      'warmupSeconds': _warmSeconds,
      'sampleSeconds': _sampleSeconds,
      'repetitions': _repeats,
      'cycles': cycles,
      'hostCount': 100,
      'activeSessions': 4,
      'corpusBytesPerSession': _seedBytesPerSession,
      'corpusTotalBytes': _seedBytesPerSession * 4,
      'scrollbackMaxLines': 5000,
      'scrollbackMaxBytes': 8 * 1024 * 1024,
      'theme': 'dark/tokyo-night',
      'language': 'zh-CN',
      'terminalFontSize': 14,
      'logicalSize': [media.size.width, media.size.height],
      'devicePixelRatio': media.devicePixelRatio,
      'textScaleAt14': media.textScaler.scale(14) / 14,
      'refreshHz': tester.view.display.refreshRate,
      'continuousProducer': 'four SSH PTYs, one ANSI/CJK line per 50ms target',
      'nonModalProbe': 'Tailscale persistent sheet; cancel and real background navigation tap',
      'inputPanelSurface': 'embedded terminal input column, separate from the non-modal sheet',
      'scope': 'emulator regression baseline; no phone smoothness claim',
      'notMeasured': [
        'input-to-SSH-write latency',
        '50 real system keyboard changes',
        'complete VM timeline',
        'listener instance counts',
      ],
    };
    final runs = <Map<String, Object?>>[];
    final streamProgress = <Map<String, Object?>>[];
    await evidence.sample(vm, 'loaded');

    for (final scene in sceneNames) {
      for (var repetition = 1; repetition <= _repeats; repetition++) {
        _mark('SCENE $scene $repetition');
        var actionIndex = 0;
        late Future<void> Function() action;
        if (scene == 'settings-scroll' || scene == 'hosts-scroll') {
          final isSettings = scene == 'settings-scroll';
          await select(isSettings ? 4 : 0);
          final within = isSettings
              ? find.byType(SettingsScreen)
              : find.byType(VaultScreen);
          // VaultScreen has horizontal search/chip scrollables before its
          // host list. Choose the actual vertical viewport, not the first one.
          final scrollable = find.descendant(
            of: within,
            matching: find.byWidgetPredicate((widget) =>
                widget is Scrollable &&
                (widget.axisDirection == AxisDirection.down ||
                    widget.axisDirection == AxisDirection.up)),
          ).first;
          tester.state<ScrollableState>(scrollable).position.jumpTo(0);
          await _delay(350);
          action = () async {
            final position = tester.state<ScrollableState>(scrollable).position;
            final before = position.pixels;
            await tester.timedDrag(scrollable,
                Offset(0, (actionIndex++).isEven ? -420 : 420),
                const Duration(milliseconds: 400));
            await _delay(100);
            expect((position.pixels - before).abs(), greaterThan(1),
                reason: 'The content list must actually move');
          };
        } else if (scene == 'host-editor') {
          await select(0);
          action = () async {
            // The production entry is a modal bottom sheet, not a pushed route.
            await tester.tap(find.byTooltip('添加连接'));
            await _delay(450);
            expect(find.byType(HostEditor), findsOneWidget);
            await tester.tap(_key('host-editor-cancel'));
            await _delay(450);
            expect(find.byType(HostEditor), findsNothing);
          };
        } else if (scene == 'tailscale-nonmodal') {
          await select(0);
          action = () async {
            // This is the same public entry called by VaultScreen. No account
            // or API key is supplied, and cancellation performs no API request.
            final closed = openTailscaleSettings(
                tester.element(find.byType(VaultScreen)));
            await _delay(450);
            expect(find.byType(TailscaleSettingsScreen), findsOneWidget);
            if ((actionIndex++).isEven) {
              await tester.tap(_key('ts-settings-cancel'));
            } else {
              // A real hit outside the sheet proves that it does not trap
              // background interaction; the production tab listener closes it.
              // Do not count global ModalBarriers: root routes may own a
              // nonblocking barrier that is unrelated to this sheet.
              // R85: located by the stable entry key, not the bar's widget type.
              await tester.tap(homeNavigationEntry(4));
              expect(container.read(homeTabProvider), 4);
            }
            await closed.timeout(const Duration(seconds: 5));
            await _delay(350);
            expect(find.byType(TailscaleSettingsScreen), findsNothing);
            await select(0);
          };
        } else if (scene == 'input-panel') {
          await select(1);
          await hidePanel();
          action = () async {
            await tester.tap(toggle);
            await _delay(450);
            expect(panel, findsOneWidget);
            await tester.tap(hide);
            await _delay(450);
            expect(panel, findsNothing);
          };
        } else if (scene == 'tabs') {
          await select(1);
          await hidePanel();
          action = () async {
            final index = actionIndex++ % 5;
            await tester.tap(homeNavigationEntry(index));
            await _delay(350);
            expect(container.read(homeTabProvider), index);
            if (index == 1) {
              controller.activate((actionIndex ~/ 5) % 4);
              await _delay(350);
            }
          };
        } else {
          await select(1);
          await hidePanel();
          controller.activate(0);
          final limit = (_warmSeconds + _sampleSeconds + 20) * 20;
          for (var i = 0; i < sessions.length; i++) {
            sessions[i].terminal.sendText(
                'sh $remote/stream.sh $i $limit\r');
          }
          await _waitFor(
              () => sessions.indexed.every((entry) =>
                  _tick(entry.$2, entry.$1) >= 0), 'continuous SSH output');
          action = () async {
            container.read(sessionOverviewRequestProvider.notifier).state++;
            await _delay(350);
            expect(find.byType(SessionOverview), findsOneWidget);
            final scrim = tester.getRect(_key('session-overview-scrim'));
            await tester.tapAt(scrim.topLeft + const Offset(20, 25));
            await _delay(350);
            expect(find.byType(SessionOverview), findsNothing);
          };
        }
        final warmActions = await _repeatFor(
            const Duration(seconds: _warmSeconds), action);
        final beforeTicks = scene == 'vt-overview'
            ? [for (var i = 0; i < 4; i++) _tick(sessions[i], i)]
            : <int>[];
        final result =
            await _capture(tester, evidence, scene, repetition, action);
        result['warmupActions'] = warmActions;
        runs.add(result);
        if (scene == 'vt-overview') {
          final afterTicks = [
            for (var i = 0; i < 4; i++) _tick(sessions[i], i),
          ];
          for (var i = 0; i < 4; i++) {
            expect(afterTicks[i] - beforeTicks[i],
                greaterThan(_sampleSeconds * 2),
                reason: 'Each real SSH PTY must keep producing during capture');
            sessions[i].terminal.sendText('\x03');
          }
          await _delay(500);
          streamProgress.add({
            'repetition': repetition,
            'beforeTicks': beforeTicks,
            'afterTicks': afterTicks,
          });
        }
        expect(tester.takeException(), isNull);
        expect(controller.state.sessions.length, 4);
        await evidence.sample(vm, '$scene-$repetition');
      }
    }

    // 100 real connect / receive 64KiB / close cycles, with a fixed host ID.
    // Same-host logs are bounded; unique host IDs would grow history instead.
    await select(1);
    await hidePanel();
    final closed = <WeakReference<GhosttyTerminalAdapter>>[];
    final resources = <Map<String, Object?>>[];
    if (cycles > 0) await evidence.sample(vm, 'cycle-0');
    for (var cycle = 1; cycle <= cycles; cycle++) {
      final session = await connect('r81-churn');
      final terminal = session.terminal as GhosttyTerminalAdapter;
      await _waitFor(() => terminal.hasActiveView, 'new terminal view');
      await load(session, 9000 + cycle, small: true);
      await controller.close(controller.state.sessions.indexOf(session));
      await _waitFor(() => terminal.engineReleased, 'native engine release');
      expect(terminal.isDisposed, isTrue);
      expect(terminal.hasActiveView, isFalse);
      expect(controller.state.sessions.length, 4);
      expect(controller.state.pendingConnections, isEmpty);
      closed.add(WeakReference(terminal));
      controller.activate(0);
      await _delay(100);
      if (cycle % 25 == 0 || cycle == cycles) {
        await evidence.sample(vm, 'cycle-$cycle');
        resources.add({
          'cycle': cycle,
          'sessions': controller.state.sessions.length,
          'closedAdaptersStillReachable':
              closed.where((ref) => ref.target != null).length,
          'closedEnginesNotReleased':
              closed.where((ref) => ref.target?.engineReleased == false).length,
          'closedActiveViews':
              closed.where((ref) => ref.target?.hasActiveView == true).length,
        });
      }
    }
    await sessions.first.sshClient!.run('rm -rf $remote');
    for (var i = controller.state.sessions.length - 1; i >= 0; i--) {
      await controller.close(i);
    }
    await _waitFor(
        () => sessions.every((session) =>
            (session.terminal as GhosttyTerminalAdapter).engineReleased),
        'all four engines released');
    expect(controller.state.sessions, isEmpty);
    await evidence.sample(vm, 'closed');
    manifest.addAll({
      'runs': runs,
      'streamProgress': streamProgress,
      'resourceCycles': resources,
      'memory': evidence.memory,
      'frameFiles': [...evidence.files],
      'allSessionEnginesReleased': true,
      'completed': true,
    });
    await evidence.write('manifest.json', manifest);
    binding.reportData = {
      'r81Mode': _smoke ? 'smoke-not-baseline' : 'baseline',
      'runCount': runs.length,
      'completedCycles': cycles,
      'manifest': 'manifest.json',
    };
    _mark('COMPLETE ${_smoke ? 'smoke-not-baseline' : 'baseline'}');
  }, timeout: const Timeout(Duration(minutes: 35)));
}
