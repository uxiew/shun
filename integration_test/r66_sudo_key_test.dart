// SEC15 设备验证：真的系统 PIN 页、真 SSH、真跳板，远端用 read + od 看收到的每个字节。只用 tool/r66-sudo-key.py 跑：
// 它设锁屏 PIN、按测试打的 `R66 ACTION=<动作>` 输 PIN 或取消，跑完查 logcat。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/app_log.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';

const _raw = String.fromEnvironment('SHUN_FIXTURE');
final Map<String, dynamic> fixture =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

// 连上以后才写进保险库的记号：登录都用测试环境那一个密码，要分清发的是谁的，就得让两台存的不一样。
// 带空格、引号、美元符号，证明一字不差；短，十六进制不会在窄屏上折行。
const edgeSecret = r'E p"w$1';
const targetSecret = r'T p"w$2';

// 命令里写 'R6''6<'：回显出来的命令行不含 R66<，只有真的执行到那一步才有。
// 开着 bracketed paste 等输入：发错成粘贴的话，收到的字节里会有 ESC [ 200 ~。
const probe =
    r"""clear; stty -echo; printf '\033[?2004h'; IFS= read -r x; stty echo; printf '\033[?2004l'; printf 'R6''6<'; printf %s "$x" | od -An -tx1 | tr -d ' \n'; printf '>\n'""";

String hex(String text) => utf8
    .encode(text)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

void report(String key, Object? value) => debugPrint('R66 $key=$value');
void action(String name) => debugPrint('R66 ACTION=$name');

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> until(WidgetTester tester, bool Function() condition,
    {required String what,
    Duration timeout = const Duration(seconds: 60)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SEC15 sudo 键', (tester) async {
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
    final sessions = container.read(sessionControllerProvider.notifier);
    HostProfile login(Map<String, Object?> data) => HostProfile({
          'username': fixture['user'],
          'password': fixture['password'],
          'authMethod': 'password',
          'protocol': 'ssh',
          ...data,
        });
    final edge = login({
      'id': 'r66-edge',
      'label': 'R66-EDGE',
      'hostname': '127.0.0.1',
      'port': fixture['edgePort'],
    });
    final target = login({
      'id': 'r66-target',
      'label': 'R66-TARGET',
      'hostname': fixture['targetName'],
      'port': fixture['targetPort'],
      'hostChain': {
        'hostIds': ['r66-edge'],
      },
    });
    await vault.upsertHost(edge);
    await vault.upsertHost(target);
    Future<bool> verify(_, __, ___) async => true;
    expect(await sessions.connect(edge, verify), isTrue);
    expect(await sessions.connect(target, verify), isTrue);
    await settle(tester, 1000);

    ActiveTerminalSession tab(String hostId) => container
        .read(sessionControllerProvider)
        .sessions
        .singleWhere((session) => session.host.id == hostId);
    final edgeTab = tab('r66-edge');
    final targetTab = tab('r66-target');
    expect(targetTab.routePlan!.jumps, hasLength(1), reason: '确实经跳板');
    report('viaJump', true);

    Future<void> store(String id, String? password) => vault.updateHost(
          id,
          (current) => HostProfile({
            ...current.data,
            'password': password,
          }),
        );
    await store('r66-edge', edgeSecret);
    await store('r66-target', targetSecret);
    // 应用锁开着且刚解过：按键照样要过验证。
    await container.read(settingsControllerProvider.notifier).edit(
        (s) => s.copyWith(appLockEnabled: true, appLockGraceSeconds: 3600));
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester, 1500);

    Future<void> run(ActiveTerminalSession session) async {
      sessions.typeInto(session.id, '$probe\r');
      await until(
        tester,
        () => session.terminal.bracketedPasteMode,
        what: '远端开好 bracketed paste 等输入',
      );
      await settle(tester, 500);
    }

    Future<void> pressKey() async {
      final key = find.byKey(const ValueKey('terminal-action-host-password'));
      if (key.evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
        await settle(tester, 500);
      }
      await tester.tap(key.first);
    }

    // 系统 PIN 页出来了才让脚本动手；回到前台才算过完。
    Future<void> throughPrompt(String what) async {
      await until(
        tester,
        () => tester.binding.lifecycleState != AppLifecycleState.resumed,
        what: '系统验证页弹出来',
      );
      action(what);
      await until(
        tester,
        () => tester.binding.lifecycleState == AppLifecycleState.resumed,
        what: '从系统验证页回来',
      );
      await settle(tester, 1500);
    }

    /// 按回车结束远端的 read，返回它收到的十六进制。
    Future<String> finish(ActiveTerminalSession session) async {
      sessions.typeInto(session.id, '\r');
      final pattern = RegExp(r'R66<([0-9a-f]*)>');
      await until(
        tester,
        () => pattern.hasMatch(session.terminal.allText()),
        what: '远端打出收到的字节',
      );
      final received =
          pattern.allMatches(session.terminal.allText()).last.group(1)!;
      await settle(tester, 300);
      return received;
    }

    // 取消：什么都不发。
    expect(container.read(sessionControllerProvider).active?.id, targetTab.id);
    await run(targetTab);
    await pressKey();
    await throughPrompt('cancel');
    expect(await finish(targetTab), isEmpty);
    report('canceledSentNothing', true);

    // 通过：发目标主机的，不是跳板的；不自动回车；不带 bracketed paste 标记。
    await run(targetTab);
    await pressKey();
    await throughPrompt('pin');
    expect(RegExp(r'R66<').hasMatch(targetTab.terminal.allText()), isFalse,
        reason: '不自动回车：远端的 read 还在等');
    report('noAutoEnter', true);
    final sentToTarget = await finish(targetTab);
    expect(sentToTarget, hex(targetSecret));
    report('viaJumpGotOwnPassword', sentToTarget == hex(targetSecret));
    report('noBracketedPasteMarkers', !sentToTarget.contains('1b'));

    // 亮着的 Ctrl 不吃掉第一个字符。
    await run(targetTab);
    targetTab.input.setModifiers(const {'ctrl'});
    await settle(tester, 300);
    await pressKey();
    await throughPrompt('pin');
    expect(await finish(targetTab), hex(targetSecret));
    expect(targetTab.input.modifiers, isEmpty);
    report('ctrlCleared', true);

    // 切到另一个标签：发那台自己的，另一个标签一个字节都收不到。
    final targetBefore = targetTab.terminal.allText();
    sessions.activate(0);
    await settle(tester, 1000);
    expect(container.read(sessionControllerProvider).active?.id, edgeTab.id);
    await run(edgeTab);
    await pressKey();
    await throughPrompt('pin');
    final sentToEdge = await finish(edgeTab);
    expect(sentToEdge, hex(edgeSecret));
    expect(targetTab.terminal.allText(), targetBefore);
    report('otherTabOwnPassword', true);
    report('firstTabUntouched', true);

    // 目标主机没存密码：没有键，硬调也不发，跳板的密码不会顶上来。
    await store('r66-target', null);
    sessions.activate(1);
    await settle(tester, 1000);
    expect(
      find.byKey(const ValueKey('terminal-action-host-password')),
      findsNothing,
    );
    await run(targetTab);
    await expectLater(
      sessions.sendStoredPassword(targetTab),
      throwsA(isA<StoredPasswordException>()),
    );
    expect(await finish(targetTab), isEmpty);
    report('noPasswordNoKeyNoSend', true);

    // 日志里没有。logcat 脚本查，这里查 App 自己的日志。
    final log = container
        .read(appLogProvider)
        .map((entry) => '${entry.title} ${entry.detail} ${entry.stack}')
        .join('\n');
    final secrets = [edgeSecret, targetSecret, '${fixture['password']}'];
    expect(secrets.where(log.contains), isEmpty);
    report('appLogClean', true);

    await sessions.close(1);
    await sessions.close(0);
    await settle(tester);
  }, skip: fixture.isEmpty, timeout: const Timeout(Duration(minutes: 8)));
}
