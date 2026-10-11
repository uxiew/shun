// R25 第一部分设备验证：终端输入面板（按键面板 / 大输入框）。真实 App 页面 + 真实 SSH（本机 Docker 测试环境），
// 远端逐字节核对；大输入框里的字由「回放输入法」按真实输入法（微信语音、Gboard 拼音）的调用顺序打进去。
//
// 这不是 CI 测试。要本机的 Docker 测试环境（tool/fixture-environment，镜像里要有 bash）和一台模拟器，经 tool/ime-replay.sh 跑：
//   (cd tool/fixture-environment && ./up.sh)
//   (cd plugins && ./build-fixtures.sh)        # 只要 plugins/out/replayime.apk
//   tool/ime-replay.sh emulator-5580 Ghostty integration_test/r25_input_panel_test.dart
// 脚本装回放输入法、临时设成默认、预授权通知、转发 22201，跑完换回原输入法并卸载。回放输入法自己的键盘有 200dp 高，
// 下面说的「系统键盘」就是它。输出以 "R25 " 开头的行作为证据。会把屏幕转成横屏再转回来。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';

import 'r18_remote_capture.dart';

void r25(String key, Object? value) => debugPrint('R25 $key=$value');

/// all：全部；layout：只跑面板切换的尺寸和横屏（不要回放输入法，可以拿系统自带的 Gboard 跑）。
const r25Scenario = String.fromEnvironment('R25_SCENARIO', defaultValue: 'all');

/// 截图用：打出 "R25 SHOT=<名字>" 后停 3 秒，让电脑那边用 adb screencap 截下这个画面。
const r25Shots = bool.fromEnvironment('R25_SHOTS');

Future<void> shot(WidgetTester tester, String name) async {
  if (!r25Shots) return;
  debugPrint('R25 SHOT=$name');
  await settle(tester, 3000);
}

Future<void> settle(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final _panel = find.byKey(const ValueKey('terminal-input-panel'));
final _toggle = find.byKey(const ValueKey('terminal-action-input-panel'));
final _editor = find.byKey(const ValueKey('terminal-compose-editor'));
Finder _panelKey(String label) =>
    find.descendant(of: _panel, matching: find.text(label));

Future<String> exec(ActiveTerminalSession session, String command) async =>
    utf8.decode(await session.sshClient!.run(command)).trim();

var _runs = 0;

/// 在远端 shell 里跑 [command]，等它跑完（用算术展开的标记，回显里只有算式）。
Future<void> run(
  WidgetTester tester,
  TerminalSessionAdapter terminal,
  String command,
) async {
  final n = 3000 + ++_runs;
  terminal.sendText('$command; echo R25D\$(($n))\r');
  await waitFor(tester, () => terminal.allText().contains('R25D$n'),
      what: command);
  await settle(tester, 300);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 点不中（被别的东西挡着、在屏幕外）就当失败：不然会点到底下的导航栏，切到别的页面去。
  WidgetController.hitTestWarningShouldBeFatal = true;
  final skip = r18Ssh.isEmpty ? '没给 R17_SSH，见文件头' : false;

  {
    // R20 起只有 Ghostty。测试名、报告的键名照旧带引擎名。
    const engine = 'Ghostty';
    testWidgets('$engine：按键面板、大输入框、切换时的尺寸，远端逐字节核对', (tester) async {
      addTearDown(() => SystemChrome.setPreferredOrientations(const []));
      var (session, controller) = await connectR18(tester);
      final terminal = session.terminal;
      final failures = <String>[];
      final viewFinder = find
          .byWidgetPredicate((w) => w.runtimeType.toString() == 'TerminalView');

      Future<void> tap(Finder finder) async {
        await tester.tap(finder);
        await settle(tester, 400);
      }

      // ---------- 1. 按键面板：每个键按远端键盘模式发，走和快捷键栏同一个出口 ----------
      await waitFor(tester, () => tester.view.viewInsets.bottom > 0,
          what: '系统键盘（回放输入法）弹出');
      await tap(_toggle);
      await waitFor(tester, () => tester.view.viewInsets.bottom == 0,
          what: '打开面板后系统键盘收起');
      await settle(tester, 1000);
      Map<String, Object> geometry() {
        final view = tester.view;
        final panelRect =
            _panel.evaluate().isEmpty ? null : tester.getRect(_panel);
        final terminalRect = tester.getRect(viewFinder.first);
        return {
          'screen': '${(view.physicalSize / view.devicePixelRatio)}',
          'inset': (view.viewInsets.bottom / view.devicePixelRatio).round(),
          'padding': (view.padding.bottom / view.devicePixelRatio).round(),
          'terminal':
              '${terminalRect.top.round()}..${terminalRect.bottom.round()}',
          'panel': panelRect == null
              ? '-'
              : '${panelRect.top.round()}..${panelRect.bottom.round()}',
          'rowArrow': _panelKey('←').evaluate().isEmpty
              ? '-'
              : tester.getCenter(_panelKey('←')).dy.round(),
        };
      }

      r25('$engine.panel.open', geometry());
      await shot(tester, '$engine-1-keys-portrait');
      if (r25Scenario == 'all') {
        var bytes = await captureRemote(tester, terminal, () async {
          for (final label in ['Esc', 'Tab', '⌫', '⏎', '↑', '←', 'PgUp', '|']) {
            await tap(_panelKey(label));
          }
          await tap(find.byKey(const ValueKey('terminal-key-page-function')));
          await tap(_panelKey('F1'));
          await tap(_panelKey('F12'));
          await tap(find.byKey(const ValueKey('terminal-key-page-control')));
          await tap(_panelKey('Ctrl+R'));
          await tap(find.byKey(const ValueKey('terminal-key-page-common')));
          // 修饰键一次性：Ctrl 再按符号页的 [，就是 Esc；之后的 / 不再带 Ctrl。
          await tap(_panelKey('Ctrl'));
          await tap(find.byKey(const ValueKey('terminal-key-page-symbols')));
          await tap(_panelKey('['));
          await tap(_panelKey('/'));
          await tap(find.byKey(const ValueKey('terminal-key-page-common')));
        }, end: CaptureEnd.timeout, seconds: 20);
        const expectedKeys = [
          0x1b, 0x09, 0x7f, 0x0d, 0x1b, 0x5b, 0x41, 0x1b, 0x5b, 0x44, //
          0x1b, 0x5b, 0x35, 0x7e, 0x7c, 0x1b, 0x4f, 0x50, //
          0x1b, 0x5b, 0x32, 0x34, 0x7e, 0x12, 0x1b, 0x2f,
        ];
        r25('$engine.keys',
            'bytes=[${hex(bytes)}] expected=[${hex(expectedKeys)}]');
        if (hex(bytes) != hex(expectedKeys)) failures.add('keys');

        // ---------- 2. 大输入框：回放输入法的微信语音（边说边改）、拼音，框里改完再发 ----------
        await tap(find.byKey(const ValueKey('terminal-input-tab-compose')));
        await waitFor(tester, () => tester.view.viewInsets.bottom > 0,
            what: '点进大输入框后系统键盘弹出');
        String editorText() =>
            tester.widget<TextField>(_editor).controller!.text;
        for (final (script, expected) in [
          ('wechat_voice', '你好啊，你是谁？在一'),
          ('pinyin', '你 ok'),
        ]) {
          report('READY', script);
          // 回放脚本最后会提交一个 Ctrl-C（给终端那边结束收数用的）：在框里它只是个控制字符，发的时候去掉。
          await waitFor(tester, () => editorText().contains('\x03'),
              timeout: const Duration(seconds: 20), what: '回放 $script');
          await settle(tester, 300);
          final inBox = editorText();
          bytes = await captureRemote(tester, terminal, () async {
            await tap(find.byKey(const ValueKey('terminal-compose-send')));
          }, end: CaptureEnd.timeout, seconds: 6);
          final want = [...utf8.encode(expected), 0x0d];
          r25('$engine.compose.$script',
              'box=${jsonEncode(inBox)} bytes=[${hex(bytes)}] expected=[${hex(want)}] boxAfter=${jsonEncode(editorText())}');
          if (hex(bytes) != hex(want) || editorText().isNotEmpty) {
            failures.add('compose-$script');
          }
        }

        // ---------- 3. 大输入框发到真 bash：bracketed paste 开/关、只填入、断线不发、恢复后要改发 ----------
        FocusManager.instance.primaryFocus?.unfocus();
        await settle(tester);
        Future<String> files() =>
            exec(session, 'cd; ls r25-* 2>/dev/null | tr "\\n" " "');
        void setBox(String text) =>
            tester.widget<TextField>(_editor).controller!.text = text;
        await exec(session, 'rm -f ~/r25-*');
        terminal.sendText('exec bash --norc --noprofile\r');
        await run(tester, terminal, 'echo bash');

        setBox('touch ~/r25-a\ntouch ~/r25-b');
        await settle(tester);
        final bracketedNote = find
            .byKey(const ValueKey('terminal-compose-risk-bracketed'))
            .evaluate()
            .isNotEmpty;
        await tap(find.byKey(const ValueKey('terminal-compose-fill')));
        await settle(tester, 1500);
        var created = await files();
        r25('$engine.bash.fillBracketed',
            'note=$bracketedNote files="$created"');
        if (!bracketedNote || created.isNotEmpty) {
          failures.add('fill-bracketed');
        }
        terminal.sendText('\x15');

        setBox('touch ~/r25-c\ntouch ~/r25-d');
        await settle(tester);
        await tap(find.byKey(const ValueKey('terminal-compose-send')));
        await settle(tester, 1500);
        created = await files();
        r25('$engine.bash.sendBracketed', 'files="$created"');
        if (created.trim() != 'r25-c r25-d') failures.add('send-bracketed');

        await run(tester, terminal, "bind 'set enable-bracketed-paste off'");
        setBox('touch ~/r25-e\ntouch ~/r25-f');
        await settle(tester);
        final linesRunNote = find
            .byKey(const ValueKey('terminal-compose-risk-lines-run'))
            .evaluate()
            .isNotEmpty;
        await tap(find.byKey(const ValueKey('terminal-compose-fill')));
        await settle(tester, 1500);
        created = await files();
        r25('$engine.bash.fillLinesRun', 'note=$linesRunNote files="$created"');
        if (!linesRunNote || created.trim() != 'r25-c r25-d r25-e') {
          failures.add('fill-lines-run');
        }
        terminal.sendText('\x15');

        // 断线：不发、字留着；自动恢复成新连接后也不发，点「改发到新连接」才发。
        setBox('touch ~/r25-g');
        await settle(tester);
        terminal.sendText(r'(sleep 1; kill -9 $PPID) &' '\r');
        await waitFor(tester, () => !session.connected, what: '断线');
        await settle(tester);
        final sendEnabledOffline = tester
                .widget<FilledButton>(
                    find.byKey(const ValueKey('terminal-compose-send')))
                .onPressed !=
            null;
        await controller.reconnectDisconnected();
        await waitFor(
            tester,
            () => controller.state.sessions.any((s) =>
                s.id == session.id && s.connected && !identical(s, session)),
            what: '恢复');
        session = controller.state.sessions.single;
        await settle(tester, 2000);
        final retarget =
            find.byKey(const ValueKey('terminal-compose-retarget'));
        final retargetOffered = retarget.evaluate().isNotEmpty;
        created = await files();
        final notResent = !created.contains('r25-g');
        if (retargetOffered) await tap(retarget);
        await tap(find.byKey(const ValueKey('terminal-compose-send')));
        await settle(tester, 1500);
        created = await files();
        r25(
            '$engine.bash.disconnect',
            'sendEnabledOffline=$sendEnabledOffline retargetOffered=$retargetOffered '
                'notResentBeforeRetarget=$notResent filesAfterRetarget="$created"');
        if (sendEnabledOffline ||
            !retargetOffered ||
            !notResent ||
            !created.contains('r25-g')) {
          failures.add('disconnect');
        }
        await exec(session, 'rm -f ~/r25-*');
      }

      // ---------- 4. 切换时终端尺寸：远端每次切换最多收到一次窗口变化（SIGWINCH），最后和看得见的行数一致 ----------
      // 前台跑一个只数 WINCH 的 bash：每收到一次就把当时的 stty size 追加到文件里；用另一个 exec 通道读文件。
      // （不能在交互 shell 里 trap：断线恢复后的新 shell 是 busybox sh，它的 WINCH trap 不记数。）
      final shell = session.terminal;
      await exec(session, 'rm -f /tmp/r25-winch');
      shell.sendText("bash -c 'trap \"stty size >> /tmp/r25-winch\" WINCH; "
          "stty size > /tmp/r25-winch0; while :; do sleep 0.1; done'\r");
      await settle(tester, 1500);
      Future<List<String>> winches() async {
        final text = await exec(session, 'cat /tmp/r25-winch 2>/dev/null');
        return [
          for (final line in text.split('\n'))
            if (line.trim().isNotEmpty) line.trim(),
        ];
      }

      var lastSize = await exec(session, 'cat /tmp/r25-winch0');
      Future<void> step(String name, Future<void> Function() act) async {
        final before = (await winches()).length;
        await act();
        await settle(tester, 1500);
        final all = await winches();
        final added = all.sublist(before);
        if (added.isNotEmpty) lastSize = added.last;
        final parts = lastSize.split(' ');
        final rows = int.parse(parts[0]);
        final panelRect =
            _panel.evaluate().isEmpty ? null : tester.getRect(_panel);
        final terminalRect = tester.getRect(viewFinder.first);
        final inset =
            tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
        r25(
            '$engine.resize.$name',
            'winches=${added.length} sizes=$added remote=$lastSize viewRows=${shell.viewRows} '
                'terminal=${terminalRect.top.round()}..${terminalRect.bottom.round()} '
                'panel=${panelRect == null ? '-' : '${panelRect.top.round()}..${panelRect.bottom.round()}'} '
                'keyboardInset=${inset.round()}');
        // 转屏不是面板切换，按 R18 的规矩合并（先发第一个、100ms 后补最后一个），不按这一条算。
        if (added.length > 1 && !name.startsWith('rotate')) {
          failures.add('resize-$name: ${added.length} 次');
        }
        if (rows != shell.viewRows || rows < 1) {
          failures.add('resize-$name: 远端 $rows 行，引擎 ${shell.viewRows} 行');
        }
        if (panelRect != null && terminalRect.bottom > panelRect.top + 0.5) {
          failures.add('resize-$name: 终端被面板挡住');
        }
      }

      await step('keysPage', () async {
        FocusManager.instance.primaryFocus?.unfocus();
        await settle(tester);
        await tap(find.byKey(const ValueKey('terminal-input-tab-keys')));
      });
      await step('hidePanel', () async {
        await tap(find.byKey(const ValueKey('terminal-action-hide-keyboard')));
      });
      await step('tapTerminalReopens', () async {
        await tester.tapAt(tester.getCenter(viewFinder.first));
      });
      await step('backToSystemKeyboard', () async {
        await tap(find.byKey(const ValueKey('terminal-input-system-keyboard')));
        await waitFor(tester, () => tester.view.viewInsets.bottom > 0,
            what: '换回系统键盘后键盘弹出');
      });
      await step('keyboardToPanel', () async {
        await tap(_toggle);
      });
      await step('composeFocus', () async {
        await tap(find.byKey(const ValueKey('terminal-input-tab-compose')));
        await waitFor(tester, () => tester.view.viewInsets.bottom > 0,
            what: '大输入框的键盘');
      });
      await shot(tester, '$engine-2-compose-keyboard-portrait');
      await step('composeBlur', () async {
        FocusManager.instance.primaryFocus?.unfocus();
        await waitFor(tester, () => tester.view.viewInsets.bottom == 0,
            what: '键盘收起');
      });

      // ---------- 5. 横屏：面板开着、大输入框弹着键盘，终端都不被挤成 0 行 ----------
      await step('rotateLandscape', () async {
        await SystemChrome.setPreferredOrientations(
            const [DeviceOrientation.landscapeLeft]);
        await waitFor(tester, () {
          final size = tester.view.physicalSize;
          return size.width > size.height;
        }, what: '转横屏');
      });
      await step('landscapeKeys', () async {
        await tap(find.byKey(const ValueKey('terminal-input-tab-keys')));
      });
      await shot(tester, '$engine-3-keys-landscape');
      await step('landscapeCompose', () async {
        await tap(find.byKey(const ValueKey('terminal-input-tab-compose')));
        await settle(tester, 2000);
        r25(
            '$engine.landscapeCompose.afterTab',
            'focus=${FocusManager.instance.primaryFocus} editor=${_editor.evaluate().isNotEmpty} '
                'inset=${tester.view.viewInsets.bottom}');
        if (tester.view.viewInsets.bottom == 0 &&
            _editor.evaluate().isNotEmpty) {
          await tap(_editor);
          await settle(tester, 2000);
          r25('$engine.landscapeCompose.afterEditorTap',
              'focus=${FocusManager.instance.primaryFocus} inset=${tester.view.viewInsets.bottom}');
        }
        await waitFor(tester, () => tester.view.viewInsets.bottom > 0,
            what: '横屏大输入框的键盘');
      });
      r25(
          '$engine.landscapeCompose.dense',
          find
              .byKey(const ValueKey('terminal-compose-more'))
              .evaluate()
              .isNotEmpty);
      await shot(tester, '$engine-4-compose-landscape');
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChrome.setPreferredOrientations(
          const [DeviceOrientation.portraitUp]);
      await waitFor(tester, () {
        final size = tester.view.physicalSize;
        return size.width < size.height;
      }, what: '转回竖屏');
      await settle(tester, 1500);
      shell.sendText('\x03');
      await settle(tester, 500);

      await controller.close(0);
      await settle(tester, 300);
      expect(failures, isEmpty, reason: failures.join('\n'));
    }, skip: skip != false, timeout: const Timeout(Duration(minutes: 8)));
  }
}
