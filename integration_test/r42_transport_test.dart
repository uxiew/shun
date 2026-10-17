// R42 设备验证（不含真 Mosh 插件的那一半）：真 App 页面、真 SSH 连 Mosh 测试环境里的 tmux。
//
// 验的是不需要 Mosh 插件的部分：标签条上的 SSH 徽标、菜单里写的主机 / tmux 目标 / 状态、
// 插件没装时 Mosh 项变灰并写原因、「选 tmux 会话」只读列出并附着、关 tmux 标签只分离。
// 真插件的原地切换（UX08 / UX11 的 Mosh 部分）要等 Mosh 插件的签名定下来，见 evidence/R42.md。
//
// 这不是 CI 测试。先（详见 docs/dev/README.md 第 2 节「Mosh」）：
//   (cd tool/mosh-fixture && ./up.sh)
//   adb -s emulator-5580 shell svc wifi disable          # 否则 10.0.2.2 的 TCP 不通
//   adb -s emulator-5580 uninstall top.xdwa.shun.mosh    # 这组要的就是「插件没装」
//   flutter test integration_test/r42_transport_test.dart -d emulator-5580 \
//     --dart-define=X09_MOSH="$(python3 tool/mosh-fixture/x08_config.py)"
// 输出以 "R42 " 开头的行作为证据。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/widgets/connection_transport_sheet.dart';

import 'mosh_session_test.dart' show Monitor, config, verifyFixture, waitFor, settle;

void report(String key, Object? value) => debugPrint('R42 $key=$value');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = config.isEmpty ? '没给 X09_MOSH，见文件头' : false;

  testWidgets('R42 无插件：徽标、菜单原因、选 tmux 会话、关 tmux 标签只分离', (tester) async {
    final monitor = await Monitor.open();
    addTearDown(monitor.close);
    await monitor.run('tmux kill-server 2>/dev/null; rm -f /tmp/r42-input; '
        'tmux new-session -d -s r42 -x 80 -y 24 "stty raw -echo; exec cat > /tmp/r42-input"');
    addTearDown(() => monitor.run('tmux kill-server 2>/dev/null; true'));
    final sessionId = await monitor.run("tmux display-message -p -t r42 '#{session_id} #{session_created}'");
    Future<List<String>> clients() async {
      final out = await monitor.run(
          "tmux list-clients -t r42 -F '#{client_pid} #{session_id}' 2>/dev/null; true");
      return out.isEmpty ? const [] : out.split('\n');
    }

    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    container.read(homeTabProvider.notifier).state = 1;
    final host = HostProfile({
      'id': 'r42',
      'label': 'r42',
      'hostname': config['sshHost'],
      'port': config['sshPort'],
      'username': config['user'],
      'password': config['password'],
      'authMethod': 'password',
      'protocol': 'ssh',
    });
    await container.read(vaultControllerProvider.notifier).upsertHost(host);

    Finder key(String value) => find.byKey(ValueKey(value));
    String texts(Finder within) => tester
        .widgetList<Text>(find.descendant(of: within, matching: find.byType(Text)))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .where((t) => t.isNotEmpty)
        .join(' | ');
    Future<void> openMenu() async {
      await tester.tap(key('terminal-transport-badge'));
      await waitFor(tester, () => key('transport-switch').evaluate().isNotEmpty,
          what: '连接方式菜单');
      await settle(tester, 400);
    }

    Future<void> closeSheet() async {
      Navigator.of(tester.element(key('transport-status'))).pop();
      await settle(tester, 600);
    }

    // ---- 普通 SSH 标签 ----
    expect(await controller.connect(host, verifyFixture), isTrue);
    final shell = controller.state.sessions.single;
    await waitFor(tester, () => shell.terminal.allText().contains(r'$'), what: '远端提示符');
    await settle(tester);
    report('plain.badge', texts(key('terminal-transport-badge')));
    expect(texts(key('terminal-transport-badge')), 'SSH');
    await openMenu();
    final plainMenu = texts(find.byType(TransportSheet));
    report('plain.menu', plainMenu);
    final plainSwitch = tester.widget<ListTile>(key('transport-switch'));
    report('plain.switch.enabled', plainSwitch.enabled);
    expect(plainSwitch.enabled, isFalse, reason: 'Mosh 插件没装');
    expect(plainMenu, contains('普通 shell'));
    expect(plainMenu, contains('状态：已连接'));
    expect(plainMenu, contains('Mosh'));
    expect(plainMenu, isNot(contains('漫游')));
    expect(plainMenu, isNot(contains('切网不断')));

    // ---- 选 tmux 会话：只读列出，选了在新标签里按 R21 附着 ----
    expect(await clients(), isEmpty);
    await tester.tap(key('transport-pick-tmux'));
    final row = find.byWidgetPredicate((w) =>
        w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('tmux-pick-'));
    await waitFor(tester, () => row.evaluate().isNotEmpty, what: 'tmux 会话列表');
    await settle(tester, 400);
    report('picker.rows', row.evaluate().length);
    report('picker.text', texts(row.first));
    expect(row, findsOneWidget);
    final sessionsBefore = await monitor.run("tmux list-sessions -F '#{session_id}'");
    await tester.tap(row);
    await waitFor(tester, () => controller.state.sessions.length == 2,
        timeout: const Duration(seconds: 40), what: 'tmux 标签');
    final tmuxTab = controller.state.sessions[1];
    await waitFor(tester, () => tmuxTab.tmux != null, what: 'tmux 绑定');
    for (var i = 0; i < 50 && (await clients()).length != 1; i++) {
      await settle(tester, 200);
    }
    report('tmux.clients', await clients());
    expect((await clients()).single, startsWith('${tmuxTab.tmux!.clientPid} '));
    expect(await monitor.run("tmux list-sessions -F '#{session_id}'"), sessionsBefore,
        reason: '选会话没有新建');

    // ---- tmux 标签的菜单：写目标全名，插件没装时原地切换变灰 ----
    await settle(tester);
    await openMenu();
    final tmuxMenu = texts(find.byType(TransportSheet));
    report('tmux.menu', tmuxMenu);
    expect(tmuxMenu, contains('tmux 会话 r42（${tmuxTab.tmux!.target.sessionId}）'));
    expect(tmuxMenu, contains('${config['user']}@${config['sshHost']}:${config['sshPort']}'));
    expect(tester.widget<ListTile>(key('transport-switch')).enabled, isFalse);
    await closeSheet();

    // ---- 关 tmux 标签：只分离，会话和里面的程序留在远端 ----
    final delete = MaterialLocalizations.of(tester.element(find.byType(TerminalScreen)))
        .deleteButtonTooltip;
    await tester.tap(find.descendant(
        of: key('terminal-tab-${tmuxTab.id}'), matching: find.byTooltip(delete)));
    await settle(tester, 600);
    final dialog = texts(find.byType(AlertDialog));
    report('close.dialog', dialog);
    expect(dialog, contains('只分离这个标签的 tmux 客户端'));
    await tester.tap(find.text('断开并关闭'));
    await settle(tester, 1500);
    for (var i = 0; i < 50 && (await clients()).isNotEmpty; i++) {
      await settle(tester, 200);
    }
    report('after.close.clients', await clients());
    report('after.close.session', await monitor.run("tmux display-message -p -t r42 '#{session_id} #{session_created}'"));
    report('input.bytes', await monitor.run('wc -c < /tmp/r42-input'));
    expect(await clients(), isEmpty);
    expect(await monitor.run("tmux display-message -p -t r42 '#{session_id} #{session_created}'"),
        sessionId);
    expect(await monitor.run('wc -c < /tmp/r42-input'), '0');
    expect(controller.state.sessions.single, same(shell));
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 4)));
}
