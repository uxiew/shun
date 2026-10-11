// R17 设备验证：Ghostty 引擎在真 Android 上跑（原生库加载、视图、真实 SSH、全屏程序、尺寸、反复建和释放）。
//
// 这不是 CI 测试。要本机的 Docker 测试环境（tool/fixture-environment）和一台模拟器或手机：
//   (cd tool/fixture-environment && ./up.sh)
//   adb -s emulator-5580 reverse tcp:22201 tcp:22201
//   flutter test integration_test/ghostty_engine_test.dart -d emulator-5580 \
//     --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py)"
// 不给 R17_SSH 时只跑不需要 SSH 的两条。输出以 "R17 " 开头的行作为证据，也进 logcat。
//
// 只连 127.0.0.1（adb reverse 转到本机）：模拟器直连 10.0.2.2 时 OrbStack 转发的端口收不到数据。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' as flterm show TerminalView;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/terminal_engine.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/terminal/ghostty_terminal_view.dart';
import 'package:shun/presentation/terminal/terminal_view.dart';

const _raw = String.fromEnvironment('R17_SSH');

/// 给了 --dart-define=R17_HOLD=true 时，在几个画面上停 5 秒，方便在本机用 adb screencap 截图核对。
const _hold = bool.fromEnvironment('R17_HOLD');

void report(String key, Object? value) => debugPrint('R17 $key=$value');

Future<void> hold(WidgetTester tester, String name) async {
  if (!_hold) return;
  report('hold', name);
  for (var i = 0; i < 50; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// 真实时钟下一帧一帧地等，最多 [timeout]。终端光标在闪，pumpAndSettle 等不到「静止」。
Future<void> waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  String what = '条件',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = _raw.isEmpty ? null : jsonDecode(_raw) as Map<String, dynamic>;
  final skipSsh = config == null ? '没给 R17_SSH，见文件头' : false;

  testWidgets('原生库在这台设备上能加载：建终端、写、读', (tester) async {
    final terminal = GhosttyTerminalAdapter();
    addTearDown(terminal.dispose);
    terminal.feed(_bytes('中文 🙂 ok\r\n\x1b[31mred\x1b[0m'));
    // 屏幕 24 行，字写在最上面两行。
    expect(terminal.recentLines(24).take(2).map((line) => line.text), [
      '中文 🙂 ok',
      'red',
    ]);
    report('platform', Platform.operatingSystemVersion);
    report('engine', terminal.engine);
  });

  testWidgets('LIFE06（引擎部分）100 轮挂视图、写、卸下、释放：原生控制器都释放，RSS 不逐轮涨', (tester) async {
    final chunk = _bytes(List.generate(
      3000,
      (i) => '\x1b[3${i % 8}mline $i 中文 🙂\x1b[0m',
    ).join('\r\n'));
    const options = TerminalViewOptions(
      fontSize: 14,
      secureKeyboard: false,
      interactive: false,
      transparentBackground: false,
    );
    Future<void> cycle() async {
      final terminal = GhosttyTerminalAdapter();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GhosttyTerminalView(adapter: terminal, options: options),
        ),
      ));
      terminal.feed(chunk);
      await tester.pump();
      terminal.dispose(); // 视图还挂着：只做标记
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(terminal.engineReleased, isTrue);
    }

    for (var i = 0; i < 20; i++) {
      await cycle();
    }
    final before = ProcessInfo.currentRss;
    for (var i = 0; i < 100; i++) {
      await cycle();
    }
    final growth = (ProcessInfo.currentRss - before) / (1 << 20);
    report('life06.rssBeforeMiB', (before / (1 << 20)).toStringAsFixed(1));
    report('life06.rssGrowthMiB', growth.toStringAsFixed(1));
    expect(growth, lessThan(32));
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('真实 SSH：终端页用 Ghostty 显示，尺寸、vim、大量输出、关标签', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      terminalAdapterFactoryProvider
          .overrideWithValue(GhosttyTerminalAdapter.new),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);
    final host = HostProfile({
      'id': 'r17',
      'label': 'r17',
      'hostname': '127.0.0.1',
      'port': config!['port'],
      'username': config['user'],
      'password': config['password'],
      'authMethod': 'password',
      'protocol': 'ssh',
      '_ephemeralTerminal': true,
    });
    final height = ValueNotifier<double>(700);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<double>(
            valueListenable: height,
            builder: (_, value, __) => Align(
              alignment: Alignment.topCenter,
              child: SizedBox(height: value, child: const TerminalScreen()),
            ),
          ),
        ),
      ),
    ));

    final connected = controller.connect(
      host,
      (_, __, fingerprint) async => fingerprint == config['fingerprint'],
    );
    await waitFor(tester, () => controller.state.sessions.isNotEmpty,
        what: '连上');
    expect(await connected, isTrue);
    final session = controller.state.sessions.single;
    final terminal = session.terminal as GhosttyTerminalAdapter;
    await waitFor(
        tester, () => find.byType(flterm.TerminalView).evaluate().isNotEmpty,
        what: 'flterm 视图');
    await waitFor(tester, () => terminal.allText().trim().isNotEmpty,
        what: '提示符');

    // TER06：远端 PTY 的尺寸就是视图量出来的尺寸。
    Future<(int, int)> remoteSize(String tag) async {
      terminal.sendText('stty size; echo $tag-\$((40+2))\r');
      await waitFor(tester, () => terminal.allText().contains('$tag-42'),
          what: 'stty');
      final lines = terminal.allText().split('\n');
      final i = lines.lastIndexWhere((line) => line.startsWith('$tag-42'));
      report('stty.$tag', '${lines.sublist(i < 3 ? 0 : i - 3, i + 1)} '
          'sent=${terminal.sentSize} viewRows=${terminal.viewRows}');
      final parts = lines[i - 1].trim().split(' ');
      return (int.parse(parts[0]), int.parse(parts[1]));
    }

    final (rows, columns) = await remoteSize('A');
    report('ter06.initial', '${rows}x$columns viewRows=${terminal.viewRows}');
    expect(rows, terminal.viewRows);
    expect(columns, greaterThan(20));

    terminal.sendText(
      "clear; printf '中文 宽字符 🙂 e\u0301\\n\\033[31m红\\033[32m绿\\033[34m蓝\\033[0m "
      "\\033[1m粗\\033[0m \\033[4m下划线\\033[0m\\n'; ls -la --color=always /etc | head -15\r",
    );
    await tester.pump(const Duration(seconds: 1));
    await hold(tester, 'colors');

    // 像软键盘弹出那样一帧缩一点，最后尺寸要对上，中途不出 0 行。
    for (var i = 1; i <= 15; i++) {
      height.value = 700 - i * 20;
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 400));
    final (shrunkRows, shrunkColumns) = await remoteSize('B');
    report(
        'ter06.afterShrink',
        '${shrunkRows}x$shrunkColumns '
            'viewRows=${terminal.viewRows}');
    expect(shrunkRows, terminal.viewRows);
    expect(shrunkRows, lessThan(rows));
    expect(shrunkColumns, columns);

    // TER03：vim 进出备用屏。
    terminal.sendText('clear; echo MAIN-\$((6*7))\r');
    await waitFor(tester, () => terminal.allText().contains('MAIN-42'));
    terminal.sendText('vim -u NONE -N /tmp/r17.txt\r');
    await waitFor(tester, () => terminal.isAlternateScreen, what: '进 vim');
    terminal.sendText('iINSIDE-VIM');
    await waitFor(tester, () => terminal.allText().contains('INSIDE-VIM'));
    await hold(tester, 'vim');
    terminal.sendText('\x1b:q!\r');
    await waitFor(tester, () => !terminal.isAlternateScreen, what: '出 vim');
    terminal.sendText('echo AFTER-\$((2+3))\r');
    await waitFor(tester, () => terminal.allText().contains('AFTER-5'));
    final text = terminal.allText();
    expect(text, isNot(contains('INSIDE-VIM')));
    expect(text.indexOf('MAIN-42'), lessThan(text.indexOf('AFTER-5')));
    report('ter03', 'vim 进出备用屏正常');

    // TER10：视图一直在画的情况下收约 2 MB，一行不丢。
    final watch = Stopwatch()..start();
    final rssBefore = ProcessInfo.currentRss;
    terminal.sendText('seq 1 300000; echo DONE-\$((6*7))\r');
    await waitFor(tester, () => terminal.allText().contains('DONE-42'),
        timeout: const Duration(seconds: 120), what: 'seq');
    watch.stop();
    final numbers = [
      for (final line in terminal.recentLines(1 << 20))
        if (RegExp(r'^\d+$').hasMatch(line.text)) int.parse(line.text),
    ];
    expect(numbers.last, 300000);
    for (var i = 1; i < numbers.length; i++) {
      expect(numbers[i], numbers[i - 1] + 1, reason: '第 $i 行断号');
    }
    report(
        'ter10',
        '${watch.elapsedMilliseconds}ms kept=${numbers.length} '
            'rssGrowthMiB=${((ProcessInfo.currentRss - rssBefore) / (1 << 20)).toStringAsFixed(1)}');

    // 关标签：会话关掉，终端释放，视图卸下后原生控制器释放。
    await controller.close(0);
    await waitFor(tester, () => terminal.engineReleased, what: '原生控制器释放');
    expect(tester.takeException(), isNull);
    report('close', 'engineReleased=${terminal.engineReleased}');
  }, skip: skipSsh != false, timeout: const Timeout(Duration(minutes: 5)));
}
