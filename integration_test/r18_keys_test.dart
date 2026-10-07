// R18 设备验证（TER04）：硬件键盘的 Ctrl/Alt/Esc/Tab/方向键、快捷键栏的一次性修饰键配硬件键和软键盘，
// 一次物理操作只出一次正确的字节，修饰键用完就复位。远端用 dd 逐字节收（Ctrl-C 也当数据收）。
// 10-07 加：硬件 Ctrl+K、Ctrl+A 发给服务器，Ctrl+Shift+K/A 是本地清滚动区/全选，Ctrl+a..z 挨个按看有没有被吃掉。
//
// 硬件键用 sendevent 往模拟器的虚拟硬件键盘写真实扫描码：AVD 要 hw.keyboard = yes（测完改回）、adb root。
// 软键盘的字用回放输入法（plugins/fixture-replayime）提交。跑法：
//   tool/ime-replay.sh emulator-5580 Ghostty integration_test/r18_keys_test.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'r18_remote_capture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = r18Ssh.isEmpty ? '没给 R17_SSH，见 tool/ime-replay.sh' : false;

  {
    // R20 起只有 Ghostty。测试名、报告的键名照旧带引擎名。
    const engine = 'Ghostty';
    testWidgets('$engine：硬件键、快捷键栏修饰键，远端逐字节核对', (tester) async {
      final (session, controller) = await connectR18(tester);
      final terminal = session.terminal;
      final failures = <String>[];

      Future<void> check(
        String name,
        Future<void> Function() act,
        List<int> expected, {
        int seconds = 6,
      }) async {
        final bytes = await captureRemote(tester, terminal, act,
            end: CaptureEnd.timeout, seconds: seconds);
        report('$engine.$name',
            'bytes=[${hex(bytes)}] expected=[${hex(expected)}]');
        if (!_same(bytes, expected)) failures.add(name);
      }

      Future<void> tapToolbar(String label) async {
        await tester.tap(find.text(label).last);
        await tester.pump(const Duration(milliseconds: 200));
      }

      // 硬件键：Ctrl+C、Ctrl+D、Alt+x、Tab、↑、Shift+Tab，最后一个 a 证明组合键之后修饰键没粘住。
      // 没有 Esc：模拟器虚拟键盘的键位表 qwerty2.kl 里没有任何扫描码映射到 ESCAPE（扫描码 1 是 BACK），
      // 硬件 Esc 只能用真蓝牙/USB 键盘测。
      await check(
        'hardware combos',
        () async => report('READY', 'hw:combo'),
        [
          0x03,
          0x04,
          0x1b,
          0x78,
          0x09,
          0x1b,
          0x5b,
          0x41,
          0x1b,
          0x5b,
          0x5a,
          0x61
        ],
      );

      // 快捷键栏的 Ctrl 只管下一个硬件键：c c → Ctrl-C、c。
      await check(
        'toolbar Ctrl + hardware c c',
        () async {
          await tapToolbar('Ctrl');
          report('READY', 'hw:cc');
        },
        [0x03, 0x63],
      );

      // 快捷键栏的 Ctrl 配软键盘（回放输入法提交 c）：Ctrl-C；再打一个 c 是普通的 c。
      await check(
        'toolbar Ctrl + soft keyboard c c',
        () async {
          await tapToolbar('Ctrl');
          report('READY', 'type_c');
          await tester.pump(const Duration(milliseconds: 800));
          report('READY', 'type_c');
        },
        [0x03, 0x63],
      );

      // 10-07：硬件 Ctrl+K、Ctrl+A 发给服务器（原来一个是清屏、一个是全选，发不到服务器）。
      await check(
        'hardware Ctrl+K Ctrl+A',
        () async => report('READY', 'hw:ctrl-ka'),
        [0x0b, 0x01],
      );

      // Ctrl+a 到 Ctrl+z 挨个按（跳过 Ctrl+V：App 的粘贴预览），看有没有被本地吃掉。
      // 10-07 实测 Ghostty 的 Ctrl+I、Ctrl+M 什么都不发（上游照 fixterms 编 CSI u，设备上的按键事件又不带字符）；
      // R20 前 fork 改成发 09、0d，和 xterm2 一样（所有者 10-07 定）。
      await check(
        'hardware Ctrl+a..z without v',
        () async => report('READY', 'hw:ctrl-letters'),
        [
          for (var code = 1; code <= 26; code++)
            if (code != 0x16) code,
        ],
        seconds: 12,
      );

      // Ctrl+[ 是 Esc 的另一种按法（不少外接键盘的 Esc 不好按，模拟器上 Esc 键还被映射成返回）：发 1b，和 xterm2 一样。
      await check(
        'hardware Ctrl+[',
        () async => report('READY', 'hw:ctrl-bracket'),
        [0x1b],
      );

      // Ctrl+Shift+K 清本地滚动区（Ghostty 沿用 flterm 的清屏，给服务器发一个 Ctrl+L），Ctrl+Shift+A 全选，都不发别的。
      await check(
        'hardware Ctrl+Shift+K Ctrl+Shift+A',
        () async => report('READY', 'hw:ctrl-shift-ka'),
        [0x0c],
      );
      report(
          '$engine.selectionAfterCtrlShiftA',
          find
              .byKey(const ValueKey('copy-terminal-selection'))
              .evaluate()
              .isNotEmpty);
      // 有选区时（上面 Ctrl+Shift+A 全选的）：Ctrl+Shift+C 复制、不发任何字节；Ctrl+C 照样发 ^C（R20 前所有者定）。
      // 先放一段已知文字：复制没成功时读回来的是它。
      await Clipboard.setData(const ClipboardData(text: 'r20-before-copy'));
      await check(
        'hardware Ctrl+Shift+C then Ctrl+C with a selection',
        () async => report('READY', 'hw:copy-then-interrupt'),
        [0x03],
      );
      final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      report('$engine.copiedByCtrlShiftC', jsonEncode(copied?.length));
      if (copied == null || copied == 'r20-before-copy' || copied.isEmpty) {
        failures.add('Ctrl+Shift+C 没复制');
      }

      // 点一下终端清掉全选。
      await tester.tapAt(tester.getCenter(find.byType(Scaffold).first));
      await tester.pump(const Duration(milliseconds: 600));

      // 快捷键栏自己的键：Alt 套在 Tab 上只套一次；Esc；方向键。
      await check(
        'toolbar Alt + Tab, Esc, ↑',
        () async {
          await tapToolbar('Alt');
          await tapToolbar('Tab');
          await tapToolbar('Esc');
          await tapToolbar('↑');
        },
        [0x1b, 0x09, 0x1b, 0x1b, 0x5b, 0x41],
      );

      await controller.close(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(failures, isEmpty, reason: '不对的：$failures');
    }, skip: skip != false, timeout: const Timeout(Duration(minutes: 6)));
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
