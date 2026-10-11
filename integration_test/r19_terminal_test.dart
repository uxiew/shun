// R19 设备验证：真实 App 页面 + 真实 SSH（本机 Docker 测试环境），手指滑动、点按、长按、选字复制、点链接、粘贴、
// 远端效果，远端逐字节核对（TER07、TER08、TER09、SEC08、SEC10）。
//
// 这不是 CI 测试。要本机的 Docker 测试环境（tool/fixture-environment，镜像里要有 bash 和 tmux）和一台模拟器或手机：
//   (cd tool/fixture-environment && ./up.sh)
//   adb -s emulator-5580 reverse tcp:22201 tcp:22201
//   另开一个终端预授权通知（不然一连上就弹「允许通知」挡住页面）：
//   until adb -s emulator-5580 shell pm grant top.xdwa.shun android.permission.POST_NOTIFICATIONS 2>/dev/null; do sleep 0.3; done
//   flutter test integration_test/r19_terminal_test.dart -d emulator-5580 \
//     --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py)"
// 输出以 "R19 " 开头的行作为证据。会动手机剪贴板（写入测试文字），不会打开浏览器（启动器换成了记录用的假实现）。
import 'dart:convert';

import 'package:flterm/flterm.dart' as flterm show TerminalView;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:shun/presentation/widgets/tailscale_check_card.dart'
    show externalLinkLauncherProvider;

import 'r18_remote_capture.dart';

void r19(String key, Object? value) => debugPrint('R19 $key=$value');

/// 最近一次 [connectR19] 起的 App 的 provider 容器：测试里直接改设置（「全屏程序里滑动翻页」）。
late ProviderContainer r19Container;

/// 起真 App 页面（终端标签），连上测试环境的边缘 sshd。打开链接换成只记录、不开浏览器。
Future<(ActiveTerminalSession, SessionController, List<Uri>)> connectR19(
  WidgetTester tester,
) async {
  final config = jsonDecode(r18Ssh) as Map<String, dynamic>;
  final repository = await VaultRepository.open();
  final launched = <Uri>[];
  final container = ProviderContainer(overrides: [
    vaultRepositoryProvider.overrideWithValue(repository),
    externalLinkLauncherProvider.overrideWithValue((uri) async {
      launched.add(uri);
      return true;
    }),
  ]);
  addTearDown(container.dispose);
  r19Container = container;
  final controller = container.read(sessionControllerProvider.notifier);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const ShunApp(),
  ));
  container.read(homeTabProvider.notifier).state = 1;
  final connected = controller.connect(
    HostProfile({
      'id': 'r19-ghostty',
      'label': 'r19',
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
  return (session, controller, launched);
}

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

var _runs = 0;

/// 在远端 shell 里跑 [command]，等它跑完（用算术展开的标记，回显里只有算式）。
Future<void> run(
  WidgetTester tester,
  TerminalSessionAdapter terminal,
  String command,
) async {
  final n = 2000 + ++_runs;
  terminal.sendText('$command; echo R19D\$(($n))\r');
  await waitFor(tester, () => terminal.allText().contains('R19D$n'),
      what: command);
  await settle(tester, 300);
}

Future<String> exec(ActiveTerminalSession session, String command) async =>
    utf8.decode(await session.sshClient!.run(command)).trim();

/// 远端逐字节收（见 [captureRemote]），收完另开一个 exec 通道把收到的文件原样读回来。
/// 不用 captureRemote 从屏幕上抄回来的结果：R19 时 xterm2 退出备用屏后旧行的残字混进过 od 的输出里，
/// 抄回来的字节有缺有错（R19 收鼠标滚轮时撞上的），exec 通道读的才是远端实际收到的。
Future<List<int>> capture(
  WidgetTester tester,
  ActiveTerminalSession session,
  Future<void> Function() act, {
  CaptureEnd end = CaptureEnd.timeout,
  int seconds = 8,
  String prelude = '',
  String postlude = '',
}) async {
  await captureRemote(tester, session.terminal, act,
      end: end, seconds: seconds, prelude: prelude, postlude: postlude);
  final dump = await exec(session, 'od -An -tx1 -v /tmp/r18.bin');
  return [
    for (final m in RegExp(r'\b[0-9a-f]{2}\b').allMatches(dump))
      int.parse(m.group(0)!, radix: 16),
  ];
}

/// SGR 鼠标报告里的按钮码；[rest] 是去掉鼠标报告后剩下的字节。
({List<int> buttons, List<int> rest}) sgr(List<int> bytes) {
  final text = latin1.decode(bytes);
  final pattern = RegExp(r'\x1b\[<(\d+);\d+;\d+[Mm]');
  return (
    buttons: [
      for (final m in pattern.allMatches(text)) int.parse(m.group(1)!),
    ],
    rest: latin1.encode(text.replaceAll(pattern, '')),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = r18Ssh.isEmpty ? '没给 R17_SSH，见文件头' : false;

  {
    // R20 起只有 Ghostty。测试名照旧带引擎名，本机手册里的 --plain-name "Ghostty：TER07" 不用改。
    const engine = 'Ghostty';
    const viewType = flterm.TerminalView;

    Future<void> swipe(WidgetTester tester, double dy) async {
      await tester.timedDrag(
        find.byType(viewType),
        Offset(0, dy),
        const Duration(milliseconds: 400),
      );
      await settle(tester);
    }

    /// 视图里第 [row] 行、离左边 [x] 的位置（视图四周留 8 的边）。
    Offset cell(WidgetTester tester, TerminalSessionAdapter terminal, int row,
        double x) {
      final rect = tester.getRect(find.byType(viewType));
      final rowHeight = (rect.height - 16) / terminal.viewRows;
      return Offset(rect.left + 8 + x, rect.top + 8 + (row + .5) * rowHeight);
    }

    Future<void> longPressDrag(
        WidgetTester tester, Offset from, Offset to) async {
      final gesture =
          await tester.startGesture(from, kind: PointerDeviceKind.touch);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(to);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await settle(tester);
    }

    testWidgets(
        '$engine：TER07 普通 shell、全屏、全屏鼠标、tmux copy-mode 下滑动/点按/长按，远端收到什么', (
      tester,
    ) async {
      final (session, _, _) = await connectR19(tester);
      final terminal = session.terminal;
      final failures = <String>[];

      // 1. 普通 shell，300 行历史：滑动翻本地滚动区，一个字节都不发。
      await run(tester, terminal, 'seq 1 300');
      double offset() => (terminal as GhosttyTerminalAdapter)
          .controller
          .scrollbar
          .offset
          .toDouble();
      late double movedBack;
      var bytes = await capture(tester, session, () async {
        final before = offset();
        await swipe(tester, 500);
        movedBack = before - offset();
        await swipe(tester, -500);
      }, end: CaptureEnd.timeout, seconds: 8);
      r19('$engine.TER07.shell', 'bytes=[${hex(bytes)}] movedBack=$movedBack');
      if (bytes.isNotEmpty || movedBack <= 0) failures.add('shell');

      // 2. 全屏程序、没开鼠标报告（less、vim、tmux 没开 mouse）：滑动什么都不发。
      bytes = await capture(tester, session, () async {
        await swipe(tester, 500);
        await swipe(tester, -500);
      },
          end: CaptureEnd.timeout,
          seconds: 8,
          prelude: r'printf "\033[?1049h\033[Hfull-screen\r\n";',
          postlude: r'printf "\033[?1049l";');
      r19('$engine.TER07.altscreen', 'bytes=[${hex(bytes)}]');
      if (bytes.isNotEmpty) failures.add('altscreen');

      // 2b. 10-07：设置开了「全屏程序里滑动翻页」，同一个全屏程序里往下拉发 ↑、往上推发 ↓（每滑过一行一个），没有别的字节；
      // 快捷键栏的 PgUp/PgDn 按远端键盘模式发。测完把设置关回去。
      await r19Container
          .read(settingsControllerProvider.notifier)
          .updateTerminalFullscreenSwipe(true);
      await settle(tester);
      bytes = await capture(tester, session, () async {
        await swipe(tester, 500);
        await swipe(tester, -500);
        await tester.tap(find.text('PgUp').last);
        await settle(tester, 300);
        await tester.tap(find.text('PgDn').last);
        await settle(tester, 300);
      },
          end: CaptureEnd.timeout,
          seconds: 10,
          prelude: r'printf "\033[?1049h\033[Hfull-screen\r\n";',
          postlude: r'printf "\033[?1049l";');
      await r19Container
          .read(settingsControllerProvider.notifier)
          .updateTerminalFullscreenSwipe(false);
      await settle(tester);
      final swipeText = latin1.decode(bytes);
      final ups = RegExp('\x1b[\\[O]A').allMatches(swipeText).length;
      final downs = RegExp('\x1b[\\[O]B').allMatches(swipeText).length;
      final firstDown = swipeText.indexOf(RegExp('\x1b[\\[O]B'));
      final lastUp = swipeText.lastIndexOf(RegExp('\x1b[\\[O]A'));
      final rest = swipeText
          .replaceAll(RegExp('\x1b[\\[O][AB]'), '')
          .replaceAll('\x1b[5~', '')
          .replaceAll('\x1b[6~', '');
      r19('$engine.TER07.altscreenSwipeOn',
          'up=$ups down=$downs upsBeforeDowns=${lastUp < firstDown} pgUp=${swipeText.contains('\x1b[5~')} pgDn=${swipeText.contains('\x1b[6~')} rest=[${hex(latin1.encode(rest))}]');
      if (ups < 3 ||
          downs < 3 ||
          lastUp > firstDown ||
          !swipeText.endsWith('\x1b[5~\x1b[6~') ||
          rest.isNotEmpty) {
        failures.add('altscreen-swipe-on');
      }

      // 3. 全屏 + 鼠标报告（tmux mouse on、htop 打开的就是这几种）：滑动只发滚轮，点按、长按不发。
      final phases = <String>[];
      var mark = 0;
      bytes = await capture(tester, session, () async {
        Future<void> phase(String name, Future<void> Function() act) async {
          await act();
          // 远端是逐字节收的，按到达顺序记下每一步之后累计收到多少，方便看哪一步发了什么。
          await settle(tester, 300);
          phases.add('$name@${++mark}');
        }

        await settle(tester, 1000);
        await phase('swipe-down', () => swipe(tester, 500));
        await phase('swipe-up', () => swipe(tester, -500));
        await phase('tap', () async {
          await tester.tapAt(cell(tester, terminal, 3, 40));
          await settle(tester);
        });
        await phase(
            'long-press',
            () => longPressDrag(tester, cell(tester, terminal, 2, 10),
                cell(tester, terminal, 2, 90)));
      },
          end: CaptureEnd.timeout,
          seconds: 10,
          prelude: r'printf "\033[?1049h\033[?1000h\033[?1002h\033[?1006h'
              r'\033[Hmouse app\r\n";',
          postlude: r'printf "\033[?1006l\033[?1002l\033[?1000l\033[?1049l";');
      // 长按在全屏程序里只在本地选字（R19 时 xterm2 会弹整屏文字）。万一弹了，关掉再往下测，不然后面的滑动落在弹框上。
      final snapshot = find.byKey(const ValueKey('terminal-copy-snapshot'));
      r19('$engine.TER07.mouseLongPressSnapshot',
          snapshot.evaluate().isNotEmpty);
      if (snapshot.evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('关闭'));
        await settle(tester);
      }
      final mouse = sgr(bytes);
      r19('$engine.TER07.mouse',
          'buttons=${mouse.buttons} rest=[${hex(mouse.rest)}] phases=$phases');
      r19('$engine.TER07.mouseRaw',
          latin1.decode(bytes).replaceAll('\x1b', 'ESC'));
      if (mouse.rest.isNotEmpty ||
          !mouse.buttons.contains(64) ||
          !mouse.buttons.contains(65) ||
          mouse.buttons.any((b) => b != 64 && b != 65)) {
        failures.add('mouse');
      }

      // 4. 真 tmux 开着 mouse：手指往下拉，tmux 进 copy-mode；窗格里的程序（dd）什么都没收到。
      await run(tester, terminal, 'tmux -L r19 kill-server 2>/dev/null; true');
      terminal.sendText(
          'tmux -f /dev/null -L r19 new-session -s r19 \\; set -g mouse on\r');
      await waitFor(tester, () => terminal.isAlternateScreen, what: 'tmux 起来');
      await settle(tester, 1000);
      await run(tester, terminal, 'seq 1 400');
      String? inMode;
      bytes = await capture(tester, session, () async {
        await swipe(tester, 500);
        inMode = await exec(session,
            "tmux -L r19 display -p -t r19 '#{pane_in_mode} #{scroll_position}'");
        await exec(session, 'tmux -L r19 send-keys -t r19 -X cancel');
        await settle(tester);
      }, end: CaptureEnd.timeout, seconds: 8);
      r19('$engine.TER07.tmux',
          'pane_in_mode,scroll=$inMode bytes=[${hex(bytes)}]');
      if (bytes.isNotEmpty || !(inMode ?? '').startsWith('1 ')) {
        failures.add('tmux');
      }
      await exec(session, 'tmux -L r19 kill-server');
      await waitFor(tester, () => !terminal.isAlternateScreen, what: '退出 tmux');
      await settle(tester, 500);

      // 5. 历史只按上限裁剪：留下的是最后一段、连号。
      await run(tester, terminal, 'seq 1 20000');
      final numbers = [
        for (final line in terminal.recentLines(1 << 20))
          if (RegExp(r'^\d+$').hasMatch(line.text)) int.parse(line.text),
      ];
      var contiguous = true;
      for (var i = 1; i < numbers.length; i++) {
        if (numbers[i] != numbers[i - 1] + 1) contiguous = false;
      }
      r19('$engine.TER07.history',
          'kept=${numbers.length} first=${numbers.first} last=${numbers.last} contiguous=$contiguous');
      if (numbers.last != 20000 || !contiguous) failures.add('history');

      expect(failures, isEmpty);
    }, skip: skip != false, timeout: const Timeout(Duration(minutes: 6)));

    testWidgets('$engine：TER08 选字复制（中文、emoji、组合字符）、点链接、长按链接、拖链接',
        (tester) async {
      final (session, _, launched) = await connectR19(tester);
      final terminal = session.terminal;
      final failures = <String>[];

      // 组合字符：e 后面跟 U+0301（UTF-8 是 cc 81）。
      await run(tester, terminal,
          r"clear; printf 'A\344\275\240\345\245\275\360\237\221\215e\314\201Z\nsecond line\n'");
      await longPressDrag(
        tester,
        cell(tester, terminal, 0, 2),
        cell(tester, terminal, 1,
            tester.getSize(find.byType(viewType)).width - 30),
      );
      final copyButton = find.byKey(const ValueKey('copy-terminal-selection'));
      final handles = find
          .byKey(const ValueKey('terminal-selection-handle-start'))
          .evaluate()
          .isNotEmpty;
      r19('$engine.TER08.selection',
          'copyButton=${copyButton.evaluate().isNotEmpty} handles=$handles');
      // 先放一段已知文字：复制没成功时读回来的是它，不会把手机剪贴板里原来的东西当成复制结果。
      await Clipboard.setData(const ClipboardData(text: 'r19-before-copy'));
      String? copied;
      if (copyButton.evaluate().isNotEmpty) {
        await tester.tap(copyButton);
        await settle(tester);
        copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      }
      const expected = 'A你好👍e\u{301}Z\nsecond line';
      r19('$engine.TER08.copy',
          'copied=${jsonEncode(copied)} expected=${jsonEncode(expected)}');
      // 中文、emoji、组合字符对不对，两行有没有并成一行，是这一项要看的。
      final okCopy = copied?.trimRight() == expected;
      if (!okCopy) failures.add('copy');

      // 链接（10-07 起）：点一下只叫键盘、不弹框；长按落在链接上，
      // 选字菜单里多「打开链接」，点了才弹框，点「用浏览器打开」才交给（假的）浏览器；从链接上拖动不弹框；远端什么都没收到。
      final openLink = find.byKey(const ValueKey('open-terminal-link'));
      final sheetHost = find.byKey(const ValueKey('terminal-link-host'));
      const url = 'https://example.com/r19-link';
      final linkBytes = await capture(tester, session, () async {
        await tester.tapAt(cell(tester, terminal, 0, 20));
        await settle(tester);
        final sheetAfterTap = sheetHost.evaluate().isNotEmpty;
        final menuAfterTap = openLink.evaluate().isNotEmpty;
        // 手指不拖：flterm 把整个链接选上。
        await longPressDrag(tester, cell(tester, terminal, 0, 20),
            cell(tester, terminal, 0, 20));
        final sheetAfterLongPress = sheetHost.evaluate().isNotEmpty;
        final menu = openLink.evaluate().isNotEmpty;
        var sheetFromMenu = false;
        if (menu) {
          await tester.tap(openLink);
          await settle(tester);
          sheetFromMenu = sheetHost.evaluate().isNotEmpty;
          if (sheetFromMenu) {
            await tester.tap(find.byKey(const ValueKey('terminal-link-open')));
            await settle(tester);
          }
        }
        // 点空白处清掉选区，再从链接上拖。
        await tester.tapAt(cell(tester, terminal, 6, 40));
        await settle(tester);
        await tester.timedDragFrom(cell(tester, terminal, 0, 20),
            const Offset(0, 300), const Duration(milliseconds: 400));
        await settle(tester);
        final sheetAfterDrag = sheetHost.evaluate().isNotEmpty;
        r19(
            '$engine.TER08.link',
            'sheetAfterTap=$sheetAfterTap menuAfterTap=$menuAfterTap sheetAfterLongPress=$sheetAfterLongPress '
                'menuAfterLongPress=$menu sheetFromMenu=$sheetFromMenu sheetAfterDrag=$sheetAfterDrag');
        if (sheetAfterTap || menuAfterTap) failures.add('link-tap');
        if (sheetAfterLongPress || sheetAfterDrag) failures.add('link-gesture');
        if (!menu || !sheetFromMenu) failures.add('link-menu');
      }, end: CaptureEnd.timeout, seconds: 14, prelude: 'clear; echo $url;');
      r19('$engine.TER08.linkOpen',
          'launched=$launched bytes=[${hex(linkBytes)}]');
      if (linkBytes.isNotEmpty) failures.add('link-bytes');
      if (launched.toString() != '[$url]') failures.add('link-open');

      // OSC 8 把「docs-link」标成 javascript: 链接：点一下不弹框；长按后菜单里有「打开链接」，弹框说不能打开、没有打开按钮。
      await run(tester, terminal,
          r"clear; printf '\033]8;;javascript:alert(1)\033\\docs-link\033]8;;\033\\\n'");
      await tester.tapAt(cell(tester, terminal, 0, 20));
      await settle(tester);
      final sheetOnTap = find
          .byKey(const ValueKey('terminal-link-refused'))
          .evaluate()
          .isNotEmpty;
      await longPressDrag(
          tester, cell(tester, terminal, 0, 20), cell(tester, terminal, 0, 20));
      final osc8Menu = openLink.evaluate().isNotEmpty;
      var refused = false;
      var openable = false;
      if (osc8Menu) {
        await tester.tap(openLink);
        await settle(tester);
        refused = find
            .byKey(const ValueKey('terminal-link-refused'))
            .evaluate()
            .isNotEmpty;
        openable = find
            .byKey(const ValueKey('terminal-link-open'))
            .evaluate()
            .isNotEmpty;
      }
      r19('$engine.TER08.osc8Javascript',
          'sheetOnTap=$sheetOnTap menu=$osc8Menu refused=$refused openButton=$openable');
      if (sheetOnTap || openable) failures.add('osc8-open');
      if (!(osc8Menu && refused)) failures.add('osc8-refused');
      if (refused) {
        await tester.tap(find.byKey(const ValueKey('terminal-link-cancel')));
        await settle(tester);
      }

      expect(failures, isEmpty);
    }, skip: skip != false, timeout: const Timeout(Duration(minutes: 4)));

    testWidgets(
        '$engine：TER09 / SEC10 粘贴到真 bash：预览、默认不回车、bracketed paste 开关、断线后不补发', (
      tester,
    ) async {
      var (session, controller, _) = await connectR19(tester);
      final terminal = session.terminal;
      final failures = <String>[];
      final paste = find.byTooltip('粘贴');
      final sheet = find.byKey(const ValueKey('terminal-paste-editor'));
      Future<String> files() =>
          exec(session, 'cd; ls r19-* 2>/dev/null | tr "\\n" " "');

      await exec(session, 'rm -f ~/r19-*');
      terminal.sendText('exec bash --norc --noprofile\r');
      await run(tester, terminal, 'echo bash');

      // 1. 多行 + 末尾换行，bracketed paste 开着（bash 默认）：先预览；点「粘贴」后 bash 等回车，没执行。
      await Clipboard.setData(
          const ClipboardData(text: 'touch ~/r19-a\ntouch ~/r19-b\n'));
      await tester.tap(paste);
      await settle(tester);
      final previewed = sheet.evaluate().isNotEmpty;
      final bracketedNote = find
          .byKey(const ValueKey('terminal-paste-risk-bracketed'))
          .evaluate()
          .isNotEmpty;
      if (previewed) {
        await tester.tap(find.byKey(const ValueKey('terminal-paste-send')));
        await settle(tester, 1500);
      }
      var created = await files();
      r19('$engine.TER09.bracketedOn',
          'preview=$previewed bracketedNote=$bracketedNote files="$created"');
      if (!previewed || !bracketedNote || created.isNotEmpty) {
        failures.add('bracketed-on');
      }
      terminal.sendText('\x15'); // Ctrl-U 清掉输入行

      // 2. 一行普通命令：直接粘贴、不弹框、不回车。
      await Clipboard.setData(const ClipboardData(text: 'touch ~/r19-c'));
      await tester.tap(paste);
      await settle(tester, 1500);
      final single = sheet.evaluate().isNotEmpty;
      created = await files();
      r19('$engine.TER09.singleLine', 'preview=$single files="$created"');
      if (single || created.isNotEmpty) failures.add('single-line');
      terminal.sendText('\x15');

      // 3. 「粘贴并回车」：用户明确点了才执行。
      await Clipboard.setData(const ClipboardData(text: 'touch ~/r19-d\n'));
      await tester.tap(paste);
      await settle(tester);
      if (sheet.evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const ValueKey('terminal-paste-enter')));
        await settle(tester, 1500);
      }
      created = await files();
      r19('$engine.TER09.pasteAndEnter', 'files="$created"');
      if (created.trim() != 'r19-d') failures.add('paste-enter');

      // 4. bracketed paste 关着：预览写明会逐行执行；点了以后第一行执行、最后一行等回车。
      await run(tester, terminal, "bind 'set enable-bracketed-paste off'");
      await Clipboard.setData(
          const ClipboardData(text: 'touch ~/r19-e\ntouch ~/r19-f'));
      await tester.tap(paste);
      await settle(tester);
      final runsNote = find
          .byKey(const ValueKey('terminal-paste-risk-lines-run'))
          .evaluate()
          .isNotEmpty;
      if (sheet.evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const ValueKey('terminal-paste-send')));
        await settle(tester, 1500);
      }
      created = await files();
      r19('$engine.TER09.bracketedOff', 'runsNote=$runsNote files="$created"');
      if (!runsNote || created.trim() != 'r19-d r19-e') {
        failures.add('bracketed-off');
      }
      terminal.sendText('\x15');

      // 5. 预览开着时断线：按钮不可用；恢复成新连接后不补发；要发得点「改发到新连接」。
      await Clipboard.setData(
          const ClipboardData(text: 'touch ~/r19-g\ntouch ~/r19-h'));
      await tester.tap(paste);
      await settle(tester);
      terminal.sendText(r'(sleep 1; kill -9 $PPID) &' '\r');
      await waitFor(tester, () => !session.connected, what: '断线');
      await settle(tester);
      final problem = find
          .byKey(const ValueKey('terminal-paste-target-problem'))
          .evaluate()
          .isNotEmpty;
      final sendEnabled = tester
          .widget<ButtonStyleButton>(
              find.byKey(const ValueKey('terminal-paste-send')))
          .enabled;
      await controller.reconnectDisconnected();
      await waitFor(
          tester,
          () => controller.state.sessions.any((s) =>
              s.id == session.id && s.connected && !identical(s, session)),
          what: '恢复');
      session = controller.state.sessions.single;
      await settle(tester, 2000);
      final retarget = find
          .byKey(const ValueKey('terminal-paste-retarget'))
          .evaluate()
          .isNotEmpty;
      created = await files();
      r19('$engine.SEC10.disconnect',
          'problemShown=$problem sendEnabled=$sendEnabled retargetOffered=$retarget files="$created"');
      if (!problem || sendEnabled || !retarget || created.contains('r19-g')) {
        failures.add('disconnect');
      }
      await tester.tap(find.byKey(const ValueKey('terminal-paste-cancel')));
      await settle(tester);
      await exec(session, 'rm -f ~/r19-*');

      expect(failures, isEmpty);
    }, skip: skip != false, timeout: const Timeout(Duration(minutes: 4)));

    testWidgets('$engine：SEC08 远端读不走、写不进剪贴板，标题不回显', (tester) async {
      final (session, _, _) = await connectR19(tester);
      await Clipboard.setData(const ClipboardData(text: 'phone-secret-r19'));

      // 远端在 dd 已经在收的时候发查询：如果终端应答，应答就进了 dd。
      final bytes = await capture(tester, session, () async {
        await settle(tester, 3000);
      },
          end: CaptureEnd.timeout,
          seconds: 6,
          prelude:
              r'(sleep 1; printf "\033]52;c;?\007\033]2;rm -rf ~\007\033[21t'
              r'\033]52;c;cHduZWQ=\007" >/dev/tty) & ');
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      r19('$engine.SEC08', 'reply=[${hex(bytes)}] clipboard=$clip');
      expect(bytes, isEmpty, reason: '剪贴板查询、标题回报都不能有应答');
      expect(clip, 'phone-secret-r19', reason: '远端写不进手机剪贴板');
    }, skip: skip != false, timeout: const Timeout(Duration(minutes: 2)));
  }
}
