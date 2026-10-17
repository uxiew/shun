// R42 设备验证（真 Mosh 插件）：真 App 页面 + 独立安装的 Mosh 插件 APK + Mosh 测试环境里的 tmux。
//
// 验 UX08 / UX11 需要真插件的那一半，全部从界面上点（徽标 → 菜单 → 切换 / 设为默认 / 重新连接 / 安装…）：
//   1. tmux 标签 SSH → Mosh → SSH 原地切：标签还是那一个，tmux 会话编号和创建时间不变，
//      客户端从 sshd 那侧换到 mosh-server 那侧再换回来，会话里的程序一个字节都没收到。
//   2. 普通标签两个方向：另开一个，原标签还连着。
//   3. 设为默认：只改保险库里的协议。
//   4. Mosh 普通标签里 exit 以后「重新连接」：新起一个 mosh-server，还在原来的位置。
//   5. Mosh-tmux 标签被远端分离后重新连接：只附着原来那个会话；同名重建后再重新连接：停下、不附着、不新建。
//   6. 服务器缺 mosh-server：给安装、卸载命令；「安装…」取消时远端一次安装都没有，确认后正好一次。
//      测试环境里的 sudo / apk 是记账脚本：只记一行就失败返回，不会真的装。
//   7. 经 SOCKS5 代理的主机：Mosh 项变灰、写「只能直连」，点了什么都不发（代理起在 App 进程里，只认一个名字）。
//
// 这不是 CI 测试。先（详见 docs/dev/README.md 第 2 节「Mosh」）：
//   (cd tool/mosh-fixture && ./up.sh)
//   adb -s emulator-5580 shell svc wifi disable          # 否则 10.0.2.2 的 TCP 不通
//   adb -s emulator-5580 install -r plugins/mosh/build/outputs/apk/release/mosh-release.apk
//   flutter test integration_test/r42_plugin_test.dart -d emulator-5580 \
//     --dart-define=X09_MOSH="$(python3 tool/mosh-fixture/x08_config.py)"
// 输出以 "R42P " 开头的行作为证据。前后各跑一次 tool/mosh-fixture/counts.sh 看登录和安装次数。
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/application/connection_switch.dart';
import 'package:shun/application/mosh_session.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/presentation/widgets/connection_transport_sheet.dart';

import '../test/fixtures/net/socks5_fixture.dart';
import 'mosh_session_test.dart'
    show Monitor, config, settle, startApp, verifyFixture, waitFor;

void report(String key, Object? value) => debugPrint('R42P $key=$value');

/// nomosh 那台的独立检查通道（和 Monitor 一样算一次登录）。
Future<SSHClient> openNomosh() async => SSHClient(
      await SSHSocket.connect(
          config['sshHost'] as String, config['nomoshPort'] as int),
      username: config['user'] as String,
      onPasswordRequest: () => config['password'] as String,
      onVerifyHostKey: (_, fp) =>
          utf8.decode(fp) == config['nomoshFingerprint'],
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = config.isEmpty ? '没给 X09_MOSH，见文件头' : false;

  testWidgets('R42 真插件：原地切换、另开、设为默认、重新连接、同名重建、缺 mosh-server 时安装',
      (tester) async {
    final monitor = await Monitor.open();
    addTearDown(monitor.close);
    await monitor.run(
        'pkill -x mosh-server; tmux kill-server 2>/dev/null; rm -f /tmp/r42-input; '
        'tmux new-session -d -s r42 -x 80 -y 24 "stty raw -echo; exec cat > /tmp/r42-input"');
    addTearDown(() => monitor
        .run('tmux kill-server 2>/dev/null; pkill -x mosh-server; true'));
    final nomosh = await openNomosh();
    addTearDown(nomosh.close);
    Future<String> onNomosh(String command) async =>
        utf8.decode(await nomosh.run(command)).trim();

    String ident() =>
        "tmux display-message -p -t r42 '#{session_id} #{session_created}'";
    final ident0 = await monitor.run(ident());
    report('tmux.ident', ident0);
    Future<List<String>> clients() async {
      final out = await monitor
          .run("tmux list-clients -t r42 -F '#{client_pid}' 2>/dev/null; true");
      return out.isEmpty ? const [] : out.split('\n');
    }

    /// 客户端的父进程是谁：busybox 的 ps 没有 -p，直接读 /proc。
    Future<String> parentOf(String pid) => monitor.run(
        // 进程名可能带空格（tmux 客户端叫「tmux: client」），先切掉「…) 」再数字段：第 2 个是父进程号。
        "pp=\$(sed 's/.*) //' /proc/$pid/stat | awk '{print \$2}'); echo \"\$pp \$(cat /proc/\$pp/comm)\"");
    Future<String> inputBytes() => monitor.run('wc -c < /tmp/r42-input');

    /// 等远端的 mosh-server 全部退出，返回用了多久（毫秒）；60 秒还没退完返回 -1。
    /// mosh-server 在里面的程序退出后还要通知客户端、等回应，等不到会重试一阵，所以不是立刻没。
    Future<int> moshServersGone() async {
      final sw = Stopwatch()..start();
      while (await monitor.running() > 0) {
        if (sw.elapsed > const Duration(seconds: 60)) return -1;
        await settle(tester, 250);
      }
      return sw.elapsedMilliseconds;
    }

    final (container, controller) = await startApp(tester);
    final vault = container.read(vaultControllerProvider.notifier);
    HostProfile host(String id, {int? port, String protocol = 'ssh'}) =>
        HostProfile({
          'id': id,
          'label': id,
          'hostname': config['sshHost'],
          'port': port ?? config['sshPort'],
          'username': config['user'],
          'password': config['password'],
          'authMethod': 'password',
          'protocol': protocol,
          'shunMoshPorts': (config['udpPorts'] as List).join(':'),
        });
    final box = host('r42');
    await vault.upsertHost(box);

    Finder key(String value) => find.byKey(ValueKey(value));
    // 指纹框的正文是 SelectableText，不是 Text：两种都收。
    String texts(Finder within) => [
          for (final t in tester.widgetList<Text>(
              find.descendant(of: within, matching: find.byType(Text))))
            t.data ?? t.textSpan?.toPlainText() ?? '',
          for (final t in tester.widgetList<SelectableText>(find.descendant(
              of: within, matching: find.byType(SelectableText))))
            t.data ?? t.textSpan?.toPlainText() ?? '',
        ].where((t) => t.isNotEmpty).join(' | ');
    var hostKeyPrompts = 0;

    /// 等条件成立；中间弹出「确认服务器指纹」就核对指纹、点「接受并记住」（用户第一次连一台时也这样）。
    Future<void> until(bool Function() condition, String what,
        {Duration timeout = const Duration(seconds: 60)}) async {
      final deadline = DateTime.now().add(timeout);
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) {
          // 超时先把现场写下来：待连接卡片到了哪一步、为什么失败、页面上写着什么。
          for (final pending in controller.state.pendingConnections) {
            report('timeout.pending',
                '${pending.host.label} ${pending.phase} ${pending.stage?.describe()} ${pending.error}');
          }
          report(
              'timeout.sessions',
              controller.state.sessions
                  .map(
                      (s) => '${s.host.label}:${transportOf(s)}:${s.connected}')
                  .join(', '));
          report(
              'timeout.pane',
              texts(find
                  .byKey(const ValueKey('terminal-connection-status-dialog'))));
          report('timeout.snackbar', texts(find.byType(SnackBar)));
          fail('等待$what超时');
        }
        final accept = find.text('接受并记住');
        if (accept.evaluate().isNotEmpty) {
          final dialog = texts(find.byType(AlertDialog));
          hostKeyPrompts++;
          report('hostKey.prompt.$hostKeyPrompts', dialog);
          expect(
              dialog.contains('${config['fingerprint']}') ||
                  dialog.contains('${config['nomoshFingerprint']}'),
              isTrue,
              reason: '指纹是测试环境的');
          await tester.tap(accept);
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<String> openMenu() async {
      await tester.tap(key('terminal-transport-badge'));
      await waitFor(tester, () => key('transport-switch').evaluate().isNotEmpty,
          what: '连接方式菜单');
      await settle(tester, 400);
      return texts(find.byType(TransportSheet));
    }

    String badge() => texts(key('terminal-transport-badge'));
    ActiveTerminalSession tab(int index) => controller.state.sessions[index];

    // ---- 普通 SSH 标签，再从「选 tmux 会话」开 tmux 标签 ----
    expect(await controller.connect(box, verifyFixture), isTrue);
    final shell = tab(0);
    await waitFor(tester, () => shell.terminal.allText().contains(r'$'),
        what: '远端提示符');
    await settle(tester);
    await openMenu();
    await tester.tap(key('transport-pick-tmux'));
    final row = find.byWidgetPredicate((w) =>
        w.key is ValueKey &&
        '${(w.key! as ValueKey).value}'.startsWith('tmux-pick-'));
    await waitFor(tester, () => row.evaluate().isNotEmpty, what: 'tmux 会话列表');
    await settle(tester, 400);
    await tester.tap(row);
    await until(
        () => controller.state.sessions.length == 2 && tab(1).tmux != null,
        'tmux 标签');
    final tmuxId = tab(1).id;
    for (var i = 0; i < 50 && (await clients()).length != 1; i++) {
      await settle(tester, 200);
    }
    final sshClient = (await clients()).single;
    report('ssh.client', '$sshClient parent=${await parentOf(sshClient)}');
    expect(await parentOf(sshClient), isNot(endsWith('mosh-server')));
    await settle(tester);

    // ---- 1a. tmux 标签 SSH → Mosh，原地 ----
    expect(badge(), 'SSH');
    final tmuxMenu = await openMenu();
    report('tmux.ssh.menu', tmuxMenu);
    expect(tester.widget<ListTile>(key('transport-switch')).enabled, isTrue);
    expect(tmuxMenu, isNot(contains('漫游')));
    expect(tmuxMenu, isNot(contains('切网不断')));
    var starts = await monitor.starts();
    final sw = Stopwatch()..start();
    await tester.tap(key('transport-switch'));
    await until(
        () =>
            controller.state.switching.isEmpty &&
            transportOf(tab(1)) == TabTransport.mosh,
        'tmux 标签切到 Mosh');
    report('toMosh.ms', sw.elapsedMilliseconds);
    for (var i = 0; i < 50 && (await clients()).contains(sshClient); i++) {
      await settle(tester, 200);
    }
    final moshClients = await clients();
    report('toMosh.tab',
        '${tab(1).id == tmuxId} index=1 sessions=${controller.state.sessions.length}');
    report('toMosh.clients', moshClients);
    report('toMosh.parent', await parentOf(moshClients.single));
    report('toMosh.ident', await monitor.run(ident()));
    report('toMosh.starts', '${await monitor.starts() - starts}');
    report('toMosh.input.bytes', await inputBytes());
    await settle(tester);
    report('toMosh.badge', badge());
    expect(tab(1).id, tmuxId);
    expect(controller.state.sessions, hasLength(2));
    expect(badge(), 'MOSH');
    expect(moshClients.single, isNot(sshClient));
    expect(await parentOf(moshClients.single), endsWith('mosh-server'));
    expect(await monitor.run(ident()), ident0);
    expect(await monitor.starts(), starts + 1);
    expect(await inputBytes(), '0');
    expect(tab(1).tmux!.target.sessionId, ident0.split(' ').first);

    // ---- 1b. 再切回 SSH，原地 ----
    report('tmux.mosh.menu', await openMenu());
    sw.reset();
    await tester.tap(key('transport-switch'));
    await until(
        () =>
            controller.state.switching.isEmpty &&
            transportOf(tab(1)) == TabTransport.ssh,
        'tmux 标签切回 SSH');
    report('toSsh.ms', sw.elapsedMilliseconds);
    for (var i = 0;
        i < 50 && (await clients()).contains(moshClients.single);
        i++) {
      await settle(tester, 200);
    }
    for (var i = 0; i < 50 && await monitor.running() > 0; i++) {
      await settle(tester, 200);
    }
    final backClients = await clients();
    report('toSsh.clients', backClients);
    report('toSsh.parent', await parentOf(backClients.single));
    report('toSsh.ident', await monitor.run(ident()));
    report('toSsh.moshServerRunning', await monitor.running());
    report('toSsh.input.bytes', await inputBytes());
    await settle(tester);
    expect(tab(1).id, tmuxId);
    expect(badge(), 'SSH');
    expect(await parentOf(backClients.single), isNot(endsWith('mosh-server')));
    expect(await monitor.run(ident()), ident0);
    expect(await monitor.running(), 0, reason: 'Mosh 那侧分离以后 mosh-server 跟着退出');
    expect(await inputBytes(), '0');

    // ---- 2a. 普通 SSH 标签 → Mosh：另开一个 ----
    controller.activate(0);
    await settle(tester);
    final plainMenu = await openMenu();
    report('plain.ssh.menu', plainMenu);
    starts = await monitor.starts();
    await tester.tap(key('transport-switch'));
    await until(() => controller.state.sessions.length == 3, '另开的 Mosh 标签');
    final moshTab = tab(2);
    await until(() => moshTab.terminal.allText().contains(r'$'), 'Mosh 标签的提示符');
    report('plain.toMosh',
        '${transportOf(moshTab)} original.connected=${shell.connected} same=${identical(tab(0), shell)}');
    expect(transportOf(moshTab), TabTransport.mosh);
    expect(identical(tab(0), shell), isTrue);
    expect(shell.connected, isTrue);
    expect(await monitor.starts(), starts + 1);

    // ---- 3. 设为默认：只改保险库的协议 ----
    await settle(tester);
    final moshMenu = await openMenu();
    report('plain.mosh.menu', moshMenu);
    await tester.tap(key('transport-set-default'));
    await settle(tester, 800);
    final saved = (await vault.ready()).hosts.singleWhere((h) => h.id == 'r42');
    report('default.protocol', saved.protocol.name);
    expect(saved.protocol, HostProtocol.mosh);
    expect(saved.data['shunMoshPorts'], box.data['shunMoshPorts']);
    if (find.byType(TransportSheet).evaluate().isNotEmpty) {
      Navigator.of(tester.element(find.byType(TransportSheet))).pop();
      await settle(tester, 600);
    }

    // ---- 4. Mosh 普通标签 exit 以后重新连接 ----
    controller.typeInto(moshTab.id, 'exit\r');
    await until(() => key('terminal-reconnect').evaluate().isNotEmpty,
        'Mosh 结束后的重新连接按钮');
    await settle(tester, 400);
    report('mosh.ended.banner', texts(key('terminal-connection-banner')));
    starts = await monitor.starts();
    await tester.tap(key('terminal-reconnect'));
    await until(
        () =>
            controller.state.sessions.length == 3 &&
            !identical(tab(2), moshTab) &&
            tab(2).connected &&
            tab(2).terminal.allText().contains(r'$'),
        '重新连上的 Mosh 标签');
    report('mosh.reconnect',
        '${transportOf(tab(2))} starts+${await monitor.starts() - starts} sessions=${controller.state.sessions.length}');
    expect(transportOf(tab(2)), TabTransport.mosh);
    expect(await monitor.starts(), starts + 1, reason: '重新连接是新会话');

    // ---- 2b. Mosh 普通标签 → SSH：另开一个，Mosh 不关 ----
    final mosh2 = tab(2);
    await settle(tester);
    await openMenu();
    await tester.tap(key('transport-switch'));
    await until(() => controller.state.sessions.length == 4, '另开的 SSH 标签');
    await until(() => tab(3).terminal.allText().contains(r'$'), 'SSH 标签的提示符');
    report('plain.toSsh',
        '${transportOf(tab(3))} mosh.connected=${mosh2.connected} same=${identical(tab(2), mosh2)}');
    expect(transportOf(tab(3)), TabTransport.ssh);
    expect(identical(tab(2), mosh2), isTrue);
    expect(mosh2.connected, isTrue);
    expect((mosh2.plugin! as MoshTerminalProvider).active, isTrue);

    // ---- 关普通 Mosh 标签：服务器上它的 mosh-server 跟着退出（后面数 mosh-server 也就只剩 tmux 那一路） ----
    await controller.close(controller.state.sessions.indexOf(mosh2));
    final closedGone = await moshServersGone();
    report('plain.mosh.close.moshServerGone.ms', closedGone);
    expect(closedGone, isNot(-1), reason: '关 Mosh 标签，服务器上那个 mosh-server 一起退出');
    expect(tab(1).id, tmuxId);

    // ---- 5. Mosh-tmux 标签被远端分离后重新连接；同名重建后再重新连接 ----
    controller.activate(1);
    await settle(tester);
    await openMenu();
    await tester.tap(key('transport-switch'));
    await until(
        () =>
            controller.state.switching.isEmpty &&
            transportOf(tab(1)) == TabTransport.mosh,
        'tmux 标签再切到 Mosh');
    for (var i = 0; i < 50 && (await clients()).length != 1; i++) {
      await settle(tester, 200);
    }
    final moshClient2 = (await clients()).single;
    expect(await parentOf(moshClient2), endsWith('mosh-server'));
    await monitor.run(
        "tmux detach-client -t \$(tmux list-clients -t r42 -F '#{client_tty}' | head -1)");
    await until(() => key('terminal-reconnect').evaluate().isNotEmpty,
        'Mosh-tmux 结束后的重新连接按钮',
        timeout: const Duration(seconds: 90));
    await settle(tester, 400);
    report('moshTmux.ended.banner', texts(key('terminal-connection-banner')));
    report('moshTmux.ended.moshServerGone.ms', await moshServersGone());
    starts = await monitor.starts();
    await tester.tap(key('terminal-reconnect'));
    await until(
        () =>
            tab(1).connected &&
            tab(1).tmux != null &&
            transportOf(tab(1)) == TabTransport.mosh,
        'Mosh-tmux 重新连上');
    for (var i = 0; i < 50 && (await clients()).length != 1; i++) {
      await settle(tester, 200);
    }
    final moshClient3 = (await clients()).single;
    report('moshTmux.reconnect',
        'client=$moshClient3 parent=${await parentOf(moshClient3)} ident=${await monitor.run(ident())} starts+${await monitor.starts() - starts}');
    expect(await parentOf(moshClient3), endsWith('mosh-server'));
    expect(await monitor.run(ident()), ident0);
    expect(await inputBytes(), '0');

    // 同名重建：服务器上只剩一个同叫 r42 的新会话。重新连接必须停下：不附着它，也不新建。
    await monitor.run(
        "tmux detach-client -t \$(tmux list-clients -t r42 -F '#{client_tty}' | head -1)");
    await until(() => key('terminal-reconnect').evaluate().isNotEmpty, '再次结束',
        timeout: const Duration(seconds: 90));
    report('moshTmux.ended2.moshServerGone.ms', await moshServersGone());
    await monitor.run('tmux kill-server 2>/dev/null; sleep 0.3; '
        'tmux new-session -d -s r42 -x 80 -y 24 "stty raw -echo; exec cat > /tmp/r42-input2"');
    final ident1 = await monitor.run(ident());
    report('rebuilt.ident', ident1);
    expect(ident1, isNot(ident0));
    starts = await monitor.starts();
    await tester.tap(key('terminal-reconnect'));
    await settle(tester, 6000);
    await until(() => controller.state.switching.isEmpty, '重新连接结束');
    await settle(tester, 1000);
    report('rebuilt.banner', texts(key('terminal-connection-banner')));
    report('rebuilt.snackbar', texts(find.byType(SnackBar)));
    report(
        'rebuilt.sessions',
        await monitor
            .run("tmux list-sessions -F '#{session_id} #{session_name}'"));
    report('rebuilt.clients', await clients());
    report('rebuilt.starts', '${await monitor.starts() - starts}');
    report('rebuilt.running', await monitor.running());
    expect(await clients(), isEmpty, reason: '同名但不是原来那个，不附着');
    expect(
        await monitor.run("tmux list-sessions -F '#{session_id}' | wc -l"), '1',
        reason: '没有暗建');
    expect(await monitor.run(ident()), ident1);
    final gone = await moshServersGone();
    report('rebuilt.moshServerGone.ms', gone);
    expect(gone, isNot(-1), reason: '附着不上就停，服务器上不留 mosh-server');

    // ---- 6. 服务器缺 mosh-server：安装提示；取消不发，确认才装，正好一次 ----
    final noMoshHost = host('r42-nomosh', port: config['nomoshPort'] as int);
    await vault.upsertHost(noMoshHost);
    Future<int> attempts() async => int.parse(await onNomosh(
        'cat /var/log/shun/install-attempts.log 2>/dev/null | wc -l'));
    final attempts0 = await attempts();
    Future<bool> trustNomosh(HostProfile _, String __, String fp) async =>
        fp == config['nomoshFingerprint'];
    expect(await controller.connect(noMoshHost, trustNomosh), isTrue);
    final noMoshTab = controller.state.sessions.last;
    await waitFor(tester, () => noMoshTab.terminal.allText().contains(r'$'),
        what: 'nomosh 提示符');
    await settle(tester);
    await openMenu();
    await tester.tap(key('transport-switch'));
    await until(() => key('mosh-install-run').evaluate().isNotEmpty, '安装提示');
    await settle(tester, 400);
    final hint = texts(find.byType(MoshInstallHintSheet));
    report('hint', hint);
    expect(hint, contains('sudo apk add mosh'));
    expect(hint, contains('sudo apk del mosh'));
    expect(hint, contains('UDP ${(config['udpPorts'] as List).join('–')}'));
    await tester.tap(key('mosh-install-run'));
    await waitFor(
        tester, () => key('mosh-install-confirm').evaluate().isNotEmpty,
        what: '安装确认框');
    await settle(tester, 400);
    report('confirm', texts(key('mosh-install-confirm')));
    await tester.tap(find.text('取消').last);
    await settle(tester, 1500);
    report('cancel.attempts', '${await attempts() - attempts0}');
    expect(await attempts(), attempts0, reason: '取消就什么都不发');
    final tabsBefore = controller.state.sessions.length;
    await tester.tap(key('mosh-install-run'));
    await waitFor(
        tester, () => key('mosh-install-confirm-run').evaluate().isNotEmpty,
        what: '安装确认框');
    await settle(tester, 400);
    await tester.tap(key('mosh-install-confirm-run'));
    await until(() => controller.state.sessions.length == tabsBefore + 1,
        '安装用的 SSH 标签');
    final installTab = controller.state.sessions.last;
    await until(
        () => installTab.terminal
            .allText()
            .contains('disabled in this test fixture'),
        '记账脚本的回应');
    await settle(tester, 1000);
    final log = await onNomosh(
        'tail -n ${await attempts() - attempts0} /var/log/shun/install-attempts.log | cut -d" " -f2-');
    report(
        'install.tab', '${installTab.host.label} ${transportOf(installTab)}');
    report('install.attempts', '${await attempts() - attempts0}');
    report('install.log', log);
    expect(installTab.host.label, '安装 mosh · r42-nomosh');
    expect(await attempts(), attempts0 + 1, reason: '确认后正好一次');
    expect(log, 'sudo apk add mosh');

    // ---- 7. 经代理的主机：Mosh 项变灰写原因，不能把 Mosh 设为默认，也不碰服务器 ----
    // 代理就起在 App 进程里，只认 mosh-via-socks 这一个名字：手机自己解析不了它，连得上就说明真经了代理。
    final socks = await Socks5Fixture.start(names: {
      'mosh-via-socks': (
        host: config['sshHost'] as String,
        port: config['sshPort'] as int
      ),
    });
    addTearDown(socks.close);
    final proxied = HostProfile({
      ...host('r42-proxy').data,
      'hostname': 'mosh-via-socks',
      'proxyConfig': {'type': 'socks5', 'host': socks.host, 'port': socks.port},
    });
    await vault.upsertHost(proxied);
    expect(await controller.connect(proxied, verifyFixture), isTrue);
    final proxiedTab = controller.state.sessions.last;
    await waitFor(tester, () => proxiedTab.terminal.allText().contains(r'$'),
        what: '经代理的提示符');
    await settle(tester);
    final startsBeforeProxy = await monitor.starts();
    final proxyMenu = await openMenu();
    report(
        'proxy.socks.requested',
        socks.attempts
            .map((a) => '${a.requestedHost}:${a.requestedPort}')
            .join(','));
    report('proxy.menu', proxyMenu);
    report('proxy.switch.enabled',
        tester.widget<ListTile>(key('transport-switch')).enabled);
    expect(socks.attempts.single.requestedHost, 'mosh-via-socks');
    expect(tester.widget<ListTile>(key('transport-switch')).enabled, isFalse);
    expect(proxyMenu, contains('Mosh 只能直连'));
    expect(key('transport-set-default'), findsNothing,
        reason: '主机默认就是 SSH，也不会给经代理的主机设 Mosh');
    await tester.tap(key('transport-switch'), warnIfMissed: false);
    await settle(tester, 1500);
    expect(await monitor.starts(), startsBeforeProxy, reason: '变灰的项点了也什么都不发');
    expect(socks.attempts, hasLength(1), reason: '没有为 Mosh 再开连接');

    report('hostKey.prompts', hostKeyPrompts);
    report('input.bytes.final', await inputBytes());
    expect(await inputBytes(), '0');
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 10)));
}
