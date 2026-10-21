// R25 外观设备验证：真 App、真 SSH（测试环境的 ssh-edge）、真模拟器。
// 浅色 / 深色下同一屏彩色输出各截一张；设置里拖字号，服务器上 stty 看到的列数跟着变（不点保存）；
// 全屏程序里右上角不再浮「复制」、标签条「复制屏幕文字」弹快照；驱动脚本把系统字体调到 1.3、2 倍、
// 转横屏，逐页截图，全程布局溢出一处都不许有。
//
// 不是 CI 测试，只用 tool/r25-appearance-device.py 跑：它只认项目专用模拟器，转端口、传测试环境登录、
// 按下面的标记截图和改系统设置，跑完把字体、方向改回去、清掉 App 数据。输出以 "R25 " 开头的行是证据：
//   R25 SHOT <名字>          驱动脚本截一张屏
//   R25 FONT <倍数> <n>      驱动脚本设系统字体大小，设完在 App 私有目录放 r25-ack-<n>
//   R25 ROTATE <0|1> <n>     驱动脚本锁定竖屏 / 横屏，同上
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';

const _raw = String.fromEnvironment('R25_SSH');
final Map<String, dynamic> config =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

void report(String key, Object? value) => debugPrint('R25 $key=$value');

/// 真实时钟下一帧一帧地等：终端光标在闪，pumpAndSettle 等不到「静止」。
Future<void> waitFor(WidgetTester tester, bool Function() condition,
    {Duration timeout = const Duration(seconds: 30),
    String what = '条件'}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip =
      config.isEmpty ? '没给 R25_SSH，用 tool/r25-appearance-device.py 跑' : false;

  testWidgets('R25 外观：终端配色、字号即时生效、全屏程序不盖字、系统字体放大和横屏', (tester) async {
    final private = (await getApplicationSupportDirectory()).path;
    final overflows = <String>[];
    var where = '启动';
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final message = details.exceptionAsString();
      if (!message.contains('overflowed')) return previous?.call(details);
      final source = RegExp(r'package:shun/[^\s:]+\.dart:\d+')
              .firstMatch(details.toString())
              ?.group(0) ??
          '';
      overflows.add('$where: ${message.split('\n').first} $source');
    };

    // 中途断言失败也要把 onError 还原：测试框架在测试体结束时就检查，等 addTearDown 来不及。
    try {
      final repository = await VaultRepository.open();
      final container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
      ]);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const ShunApp(),
      ));
      await settle(tester, 1500);

      final vault = container.read(vaultControllerProvider.notifier);
      final controller = container.read(sessionControllerProvider.notifier);
      Finder key(String value) => find.byKey(ValueKey(value));
      Future<void> shot(String name) async {
        await settle(tester, 800);
        debugPrint('R25 SHOT $name');
        await settle(tester, 1200);
      }

      var acks = 0;
      Future<void> driver(String command) async {
        final n = ++acks;
        final ack = File('$private/r25-ack-$n');
        if (ack.existsSync()) ack.deleteSync();
        debugPrint('R25 $command $n');
        await waitFor(tester, ack.existsSync, what: '驱动脚本 $command');
        await settle(tester, 1500);
      }

      Future<void> openTab(IconData icon) async {
        await tester.tap(find.byIcon(icon));
        await settle(tester, 800);
      }

      final host = HostProfile({
        'id': 'r25-look',
        'label': 'R25 外观',
        'hostname': '127.0.0.1',
        'port': config['edgePort'],
        'username': config['user'],
        'password': config['password'],
        'authMethod': 'password',
        'protocol': 'ssh',
      });
      await vault.upsertHost(host);
      await settle(tester, 500);
      expect(
        await controller.connect(
          host,
          (h, _, fingerprint) async => fingerprint == config['edgeFingerprint'],
        ),
        isTrue,
      );
      container.read(homeTabProvider.notifier).state = 1;
      await settle(tester, 1500);
      final session = container.read(sessionControllerProvider).active!;
      String screen() => session.terminal.allText();
      var marks = 0;
      Future<String> run(String command) async {
        final mark = 'R25-DONE-${++marks}';
        controller.typeInto(session.id, '$command; echo $mark\r');
        // 命令行本身也带着标记，要等它单独成行（echo 的输出）。
        await waitFor(tester,
            () => screen().split('\n').any((line) => line.trim() == mark),
            what: command);
        await settle(tester, 300);
        return screen();
      }

      // 一、配色。同一屏输出在浅色、深色下各截一张：黄、亮黄、白、亮白在默认背景上，
      // 再加两段程序自己配了背景的（不该被调）。
      where = '配色';
      await run(
          r"clear; printf '\e[33myellow \e[93mbright-yellow \e[37mwhite \e[97mbright-white \e[32mgreen \e[34mblue \e[90mgray\e[0m\n\e[30;47m black-on-white \e[0m \e[97;44m white-on-blue \e[0m \e[33;43m yellow-on-yellow \e[0m\n'");
      await openTab(Icons.settings_outlined);
      await tester.tap(find.text('浅色'));
      await settle(tester, 800);
      await openTab(Icons.terminal_outlined);
      await shot('01-light-colors');
      await openTab(Icons.settings_outlined);
      await tester.tap(find.text('深色'));
      await settle(tester, 800);
      await openTab(Icons.terminal_outlined);
      await shot('02-dark-colors');

      // 二、字号。拖完松手就存，开着的终端马上按新字号重排，服务器收到新的行列数。
      where = '字号';
      (int, int) size(String text, int n) {
        final lines = text.split('\n').map((l) => l.trim()).toList();
        final at = lines.lastIndexWhere((l) => l == 'R25-DONE-$n');
        final match = RegExp(r'^(\d+) (\d+)$').firstMatch(lines[at - 1])!;
        return (int.parse(match.group(1)!), int.parse(match.group(2)!));
      }

      final before = size(await run('stty size'), marks);
      await openTab(Icons.settings_outlined);
      final slider = key('settings-terminal-font-size');
      await tester.ensureVisible(slider);
      await settle(tester, 300);
      await shot('03-font-slider-before');
      await tester.drag(slider, const Offset(120, 0));
      await settle(tester, 800);
      final saved = (await repository.loadSettings()).terminalFontSize;
      report('fontSize.saved', saved);
      await shot('04-font-slider-after');
      await openTab(Icons.terminal_outlined);
      final after = size(await run('stty size'), marks);
      report('stty.before', '${before.$1}x${before.$2}');
      report('stty.after', '${after.$1}x${after.$2}');
      expect(saved, greaterThan(14));
      expect(after.$2, lessThan(before.$2), reason: '字大了，一行放得下的字变少');
      await shot('05-terminal-bigger-font');

      // 三、全屏程序。进备用屏幕、在右上角写标记：没选字时终端上不该有任何浮动按钮。
      where = '全屏程序';
      final cols = after.$2;
      controller.typeInto(
        session.id,
        "clear; printf '\\e[?1049h\\e[2J\\e[1;${cols - 9}HTOPRIGHT\\e[3;1Hfull-screen app'; sleep 60\r",
      );
      await waitFor(tester, () => screen().contains('TOPRIGHT'),
          what: '全屏程序画出来');
      await settle(tester, 500);
      report(
          'alt.floatingCopy', key('copy-terminal-selection').evaluate().length);
      expect(key('copy-terminal-selection'), findsNothing);
      await shot('06-full-screen-no-overlay');
      await tester.tap(key('terminal-copy-screen'));
      await settle(tester, 1000);
      final snapshot = tester
          .widget<TextField>(key('terminal-copy-snapshot'))
          .controller!
          .text;
      report('snapshot.hasTopRight', snapshot.contains('TOPRIGHT'));
      expect(snapshot, contains('TOPRIGHT'));
      await shot('07-copy-snapshot');
      await tester.binding.handlePopRoute();
      await settle(tester, 800);
      controller.typeInto(session.id, '\x03');
      await settle(tester, 300);
      await run(r"printf '\e[?1049l'");

      // 四、系统字体放大、横屏。终端里的字不跟系统字体变，其余页面要放得下。
      for (final scale in ['1.3', '2.0']) {
        where = '系统字体 $scale';
        await driver('FONT $scale');
        final scaler = MediaQuery.textScalerOf(
            tester.element(find.byType(Scaffold).first));
        report('textScaler.$scale', scaler);
        await openTab(Icons.dns_outlined);
        await shot('08-vault-font-$scale');
        await openTab(Icons.terminal_outlined);
        await shot('09-terminal-font-$scale');
        await openTab(Icons.settings_outlined);
        await shot('10-settings-font-$scale');
      }
      where = '横屏，系统字体 2.0';
      await driver('ROTATE 1');
      await shot('11-settings-landscape');
      await openTab(Icons.terminal_outlined);
      await shot('12-terminal-landscape');
      final landscape = size(await run('stty size'), marks);
      report('stty.landscape', '${landscape.$1}x${landscape.$2}');
      expect(landscape.$2, greaterThan(after.$2), reason: '横过来一行更宽');
      await driver('ROTATE 0');
      await driver('FONT 1.0');
      await settle(tester, 500);

      await controller.close(0);
      await settle(tester, 500);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    } finally {
      FlutterError.onError = previous;
    }
    report('overflows', overflows.length);
    for (final line in overflows.toSet()) {
      debugPrint('R25 OVERFLOW $line');
    }
    expect(overflows, isEmpty);
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 6)));
}
