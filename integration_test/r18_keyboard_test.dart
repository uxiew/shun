// R18 设备验证：真实 App 页面 + 真软键盘下，终端不被键盘挡住、远端尺寸等于看得见的区域（TER05、TER06），
// 快捷键栏的功能键按远端键盘模式编码、发给有焦点的那个终端（TER04、TER05）。
//
// 这不是 CI 测试。要本机的 Docker 测试环境（tool/fixture-environment）和一台装了 Gboard 的模拟器或手机：
//   (cd tool/fixture-environment && ./up.sh)
//   adb -s emulator-5580 reverse tcp:22201 tcp:22201
//   flutter test integration_test/r18_keyboard_test.dart -d emulator-5580 \
//     --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py)"
// 输出以 "R18 " 开头的行作为证据，也进 logcat。会把屏幕转成横屏再转回来。
//
// 每次 flutter test 都重装 App，一连上 SSH 系统就弹「允许通知」（前台保活服务要），挡在 App 前面，
// 软键盘出不来，表现为「等待软键盘弹出超时」。跑之前在另一个终端先预授权，装上就授：
//   until adb -s emulator-5580 shell pm grant top.xdwa.xwshun android.permission.POST_NOTIFICATIONS 2>/dev/null; do sleep 0.3; done
import 'dart:convert';

import 'package:flterm/flterm.dart' as flterm show TerminalView;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:netcatty_mobile/app.dart';
import 'package:netcatty_mobile/application/home_navigation.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';

const _raw = String.fromEnvironment('R17_SSH');

void report(String key, Object? value) => debugPrint('R18 $key=$value');

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

Future<void> settle(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = _raw.isEmpty ? null : jsonDecode(_raw) as Map<String, dynamic>;
  final skip = config == null ? '没给 R17_SSH，见文件头' : false;

  {
    // R20 起只有 Ghostty。测试名照旧带引擎名。
    const engine = 'Ghostty';
    testWidgets('$engine：横竖屏 + 软键盘，终端不被挡、远端尺寸对得上', (tester) async {
      final repository = await VaultRepository.open();
      final container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
      ]);
      addTearDown(container.dispose);
      addTearDown(() => SystemChrome.setPreferredOrientations(const []));
      final controller = container.read(sessionControllerProvider.notifier);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const NetcattyApp(),
      ));
      container.read(homeTabProvider.notifier).state = 1;
      final host = HostProfile({
        'id': 'r18-$engine',
        'label': 'r18',
        'hostname': '127.0.0.1',
        'port': config!['port'],
        'username': config['user'],
        'password': config['password'],
        'authMethod': 'password',
        'protocol': 'ssh',
        '_ephemeralTerminal': true,
      });
      final connected = controller.connect(
        host,
        (_, __, fingerprint) async => fingerprint == config['fingerprint'],
      );
      await waitFor(tester, () => controller.state.sessions.isNotEmpty,
          what: '连上');
      expect(await connected, isTrue);
      final session = controller.state.sessions.single;
      final terminal = session.terminal;
      final viewFinder = find.byType(flterm.TerminalView);
      await waitFor(tester, () => viewFinder.evaluate().isNotEmpty,
          what: '终端视图');
      await waitFor(tester, () => terminal.allText().trim().isNotEmpty,
          what: '提示符');

      var probe = 0;
      Future<(int, int)> remoteSize() async {
        final tag = 'S${probe++}';
        terminal.sendText('stty size; echo $tag-\$((40+2))\r');
        await waitFor(tester, () => terminal.allText().contains('$tag-42'),
            what: 'stty');
        final lines = terminal.allText().split('\n');
        final i = lines.lastIndexWhere((line) => line.startsWith('$tag-42'));
        final parts = lines[i - 1].trim().split(' ');
        return (int.parse(parts[0]), int.parse(parts[1]));
      }

      // 第一次量（竖屏不弹键盘）时估出行高的上下界。两个视图上下各留 8dp 内边距。
      double? cellLow;
      double? cellHigh;
      Future<void> measure(String name, {required bool keyboard}) async {
        await settle(tester);
        final view = tester.view;
        final screen = view.physicalSize / view.devicePixelRatio;
        final inset = view.viewInsets.bottom / view.devicePixelRatio;
        final keyboardTop = screen.height - inset;
        final rect = tester.getRect(viewFinder);
        final (rows, columns) = await remoteSize();
        report(
          '$engine.$name',
          'screen=${screen.width.round()}x${screen.height.round()} '
              'keyboardInset=${inset.round()} '
              'terminal=${rect.top.round()}..${rect.bottom.round()} '
              'remote=${rows}x$columns viewRows=${terminal.viewRows} '
              'sent=${(terminal as TerminalSessionAdapterBase).sentSize}',
        );
        expect(inset > 0, keyboard, reason: '$name：软键盘${keyboard ? '应该' : '不该'}弹着');
        // 终端整块都在键盘上面，远端行数就是引擎按这块大小算出的行数：看得见的就是远端的。
        expect(rect.bottom, lessThanOrEqualTo(keyboardTop + 0.5),
            reason: '$name：终端被键盘挡住');
        expect(rows, terminal.viewRows, reason: '$name：远端行数和引擎行数不一致');
        final usable = rect.height - 16;
        cellLow ??= usable / (rows + 1);
        cellHigh ??= usable / rows;
        // 远端的行都放得下（不是拿旧尺寸凑数），也没少算（看得见的行远端都知道）。
        expect(rows * cellLow!, lessThanOrEqualTo(usable + 0.5),
            reason: '$name：远端 $rows 行放不进 ${usable.round()}dp');
        expect((rows + 1) * cellHigh!, greaterThan(usable - 0.5),
            reason: '$name：${usable.round()}dp 放得下更多行，远端只有 $rows 行');
        // 横屏弹键盘时本来就只剩两三行（字跟着系统大字体放大时 2 行），不为 0 就行。
        expect(rows, greaterThanOrEqualTo(1), reason: '$name：终端被挤成 0 行');
      }

      Future<void> showKeyboard() async {
        await tester.tap(viewFinder);
        await waitFor(tester, () => tester.view.viewInsets.bottom > 0,
            what: '软键盘弹出');
      }

      Future<void> hideKeyboard() async {
        FocusManager.instance.primaryFocus?.unfocus();
        await waitFor(tester, () => tester.view.viewInsets.bottom == 0,
            what: '软键盘收起');
      }

      Future<void> rotate(List<DeviceOrientation> to, bool landscape) async {
        await SystemChrome.setPreferredOrientations(to);
        await waitFor(
          tester,
          () {
            final size = tester.view.physicalSize;
            return (size.width > size.height) == landscape;
          },
          what: landscape ? '转横屏' : '转竖屏',
        );
      }

      // 终端一挂上就自动拿焦点、弹键盘。
      await waitFor(tester, () => tester.view.viewInsets.bottom > 0,
          what: '软键盘自动弹出');
      await hideKeyboard();
      await measure('portrait', keyboard: false);
      await showKeyboard();
      await measure('portrait+keyboard', keyboard: true);
      await rotate(const [DeviceOrientation.landscapeLeft], true);
      if (tester.view.viewInsets.bottom == 0) await showKeyboard();
      await measure('landscape+keyboard', keyboard: true);
      await hideKeyboard();
      await measure('landscape', keyboard: false);
      await showKeyboard();
      await rotate(const [DeviceOrientation.portraitUp], false);
      if (tester.view.viewInsets.bottom == 0) await showKeyboard();
      await measure('portrait+keyboard again', keyboard: true);
      await hideKeyboard();

      await controller.close(0);
      await settle(tester, 300);
    }, skip: skip != false, timeout: const Timeout(Duration(minutes: 4)));
  }
}
