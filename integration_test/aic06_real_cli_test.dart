// AIC06：真的 Claude Code、Codex（tool/ai-cli-fixture 容器），模型接口换成容器里的假服务
// （tool/ai-cli-fixture/mock-model.mjs），不用账号、不花额度。界面、SSH、tmux、Ghostty、加密存储都是真的。
// 跑法：tool/aic06-real-cli.sh（它会重建容器、接上假服务），见 docs/dev/README.md。
//
// 「续上的是不是同一段对话」靠三样互相独立的东西判断，不只看屏幕：
// 1. 假服务只按请求里带的历史回话：MOCK-RECALL 只有工具把之前 MOCK-REMEMBER 那句一起发来才答得出口令；
// 2. 假服务日志里工具自报的会话 ID（Claude 的 x-claude-code-session-id 头，Codex 的 prompt_cache_key）；
// 3. 工具自己的会话文件（~/.claude/projects/*/<ID>.jsonl、~/.codex/sessions/**/rollout-*-<ID>.jsonl）。
// 真实模型和账号那一侧（登录过期、限流、服务端的会话处理）这里测不到，那是 AIC09。
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/ai_cli.dart';
import 'package:shun/domain/ai_cli_identity.dart';
import 'package:shun/domain/ai_cli_work.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/tmux/ai_cli_tmux_run.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/ai_cli_preferences.dart';
import 'package:shun/infrastructure/storage/ai_cli_recent_work.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:shun/presentation/widgets/ai_cli_tools_sheet.dart';

const config = String.fromEnvironment('AIC06_CONFIG');
const claude = '/usr/local/bin/claude';
const codex = '/usr/local/bin/codex';
// Claude Code 1.0.0：还没有 --session-id。mock-model.sh 装的，经「补充目录」让 App 检测到。
const oldClaude = '/home/fixture/old-claude/node_modules/.bin/claude';
const repo = '/home/fixture/aic/repo';
const worktree = '/home/fixture/aic/repo-wt';
const codexProject = '/home/fixture/aic/codex';
const recent = SecureAiCliRecentWork();

void aic(String key, Object? value) => debugPrint('AIC06 $key=$value');

Future<void> frames(WidgetTester tester, [int count = 8]) async {
  for (var n = 0; n < count; n++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

List<String> screen(ActiveTerminalSession s) => [
      for (final line in s.terminal.recentLines(s.terminal.viewRows))
        line.text.trimRight(),
    ];

String onScreen(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .where((t) => t.trim().isNotEmpty)
    .join(' | ');

Future<void> waitFor(WidgetTester tester, bool Function() ready, String what,
    {int seconds = 40}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out: $what. On screen: ${onScreen(tester)}');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets('AIC06 real Claude Code / Codex sessions with a mock model',
      (tester) async {
    final cfg = jsonDecode(config) as Map<String, dynamic>;
    final host = HostProfile({
      'id': 'aic06-device',
      'label': 'AIC06 fixture',
      'hostname': '127.0.0.1',
      'port': cfg['port'],
      'username': cfg['user'],
      'password': cfg['password'],
      'authMethod': 'password',
      'protocol': 'ssh',
    });
    final scope = aiCliHostScope(host);
    Future<bool> verify(HostProfile _, String __, String fp) async =>
        fp == cfg['fingerprint'];
    Future<String> remote(String command) => SshService().withVerifiedClient(
        routePlan:
            resolveRoutePlan(host, hosts: [host], proxyProfiles: const []),
        verifyHostKey: verify,
        attempt: ConnectionAttempt(),
        query: (client) async => utf8
            .decode(await client.run(command), allowMalformed: true)
            .trim());

    Future<List<Map<String, dynamic>>> mainRequests() async => [
          for (final line in const LineSplitter()
              .convert(await remote('cat ~/mock-model/requests.jsonl')))
            if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>
        ].where((r) => r['main'] == true).toList();

    // 工具发不发请求是异步的：屏幕上已经有回复时，日志一定已经写了（先记日志再回话）。
    Future<Map<String, dynamic>> lastMain() async =>
        (await mainRequests()).last;

    final rnd = Random();
    String token(String prefix) => '$prefix${1000 + rnd.nextInt(9000)}';

    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    final vault = container.read(vaultControllerProvider.notifier);
    final data = await vault.ready();
    await vault.replace(data.copyWith(hosts: [
      host
    ], extras: {
      ...data.extras,
      'knownHosts': [
        {
          'hostname': host.hostname,
          'port': host.port,
          'keyType': 'ssh-ed25519',
          'fingerprint': cfg['fingerprint'],
          'acceptedAt': DateTime.now().millisecondsSinceEpoch
        }
      ]
    }));
    await recent.clear(scope);
    await const SecureAiCliPreferences().save(
        scope,
        AiCliScanRequest(
            directories: const ['~/old-claude/node_modules/.bin']));

    // 每轮从干净的项目目录开始。Codex 的后台 app-server 也停掉：它拿着上一轮的状态，历史列表可能带出旧对话。
    aic('versions', (await remote(r'''
tmux kill-server 2>/dev/null || :
tmux -L aic06decoy kill-server 2>/dev/null || :
pkill -f 'codex app-serve[r]' || :
rm -rf ~/aic ~/aic-moved
mkdir -p ~/aic/codex ~/aic-moved
git init -q ~/aic/repo
git -C ~/aic/repo -c user.name=aic06 -c user.email=aic06@invalid commit -q --allow-empty -m init
git -C ~/aic/repo worktree add -q ~/aic/repo-wt 2>/dev/null
: > ~/mock-model/requests.jsonl
printf '%s | ' "$(/usr/local/bin/claude --version)" "$(/usr/local/bin/codex --version)" \
  "old $(~/old-claude/node_modules/.bin/claude --version)" "$(tmux -V)" "debian $(cat /etc/debian_version)" "node $(node --version)"
''')));

    final controller = container.read(sessionControllerProvider.notifier);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const ShunApp()));
    await frames(tester, 20);
    container.read(homeTabProvider.notifier).state = 0;
    await frames(tester);

    Finder sheetScroll() => find
        .descendant(
            of: find.byType(AiCliToolsSheet), matching: find.byType(Scrollable))
        .first;

    /// 打开工具列表并等检测做完：「核对并返回 tmux」「按会话 ID 继续」要检测过才能点。
    /// 头一次从主机详情进；有了最近工作就从首页卡片进（和 r56 一样）。首页卡片对「原终端还连着」
    /// 的普通记录会直接切回终端、不开列表，所以调用前要先关掉这类标签。
    Future<void> toolsSheet({bool fromHome = true}) async {
      container.read(homeTabProvider.notifier).state = 0;
      await frames(tester);
      if (fromHome) {
        await waitFor(
            tester,
            () => find
                .byKey(const ValueKey('vault-recent-ai-work'))
                .evaluate()
                .isNotEmpty,
            'recent homepage card');
        await tester.tap(find.byKey(const ValueKey('vault-recent-ai-work')));
      } else {
        await tester.tap(find.text(host.label).first);
        await frames(tester);
        await tester.tap(find.byKey(const ValueKey('host-ai-cli')));
      }
      await waitFor(tester, () {
        final scroll = find.descendant(
            of: find.byType(AiCliToolsSheet),
            matching: find.byType(Scrollable));
        if (scroll.evaluate().isNotEmpty) {
          final state = tester.state<ScrollableState>(scroll.first);
          state.position.jumpTo(state.position.maxScrollExtent);
        }
        // 一次检测同时出全部结果，看到一个就是做完了；另外两个在 launch() 里滚动去找。
        return find
            .byKey(const ValueKey('ai-cli-launch-$claude'))
            .evaluate()
            .isNotEmpty;
      }, 'discovery');
      await frames(tester);
    }

    Future<void> launch(String path, String directory,
        {bool tmux = false}) async {
      final button = find.byKey(ValueKey('ai-cli-launch-$path'));
      // 列表按需构建，滚到底时上面的项可能已经拆掉：回到顶上再往下找。
      tester.state<ScrollableState>(sheetScroll()).position.jumpTo(0);
      await frames(tester);
      await tester.scrollUntilVisible(button, 250, scrollable: sheetScroll());
      await frames(tester);
      await tester.tap(button);
      await frames(tester);
      await tester.enterText(
          find.byKey(const ValueKey('ai-cli-project-directory')), directory);
      if (tmux) await tester.tap(find.byType(CheckboxListTile));
      await tester.tap(find.byKey(const ValueKey('ai-cli-confirm-launch')));
      await frames(tester);
    }

    /// App 是终端连上之后才写最近工作（ai_cli_tools_sheet.dart 的 _launch），中间有一小段空档：
    /// 一看到标签连上就去读，会读到还没写进去的空列表。
    Future<AiCliWorkItem> item(bool Function(AiCliWorkItem) test) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (true) {
        final found = (await recent.load(scope)).where(test);
        if (found.isNotEmpty) return found.first;
        if (DateTime.now().isAfter(deadline)) {
          fail('No matching recent work. On screen: ${onScreen(tester)}');
        }
        await frames(tester, 4);
      }
    }

    /// 点最近工作里那条记录的主按钮，点之前确认按钮上的字是 [label]（就是 App 打算做的事）。
    Future<void> tapRecent(AiCliWorkItem it, String label) async {
      final button = find.byKey(ValueKey('ai-cli-recent-${it.id}'));
      await tester.scrollUntilVisible(button, -250, scrollable: sheetScroll());
      await waitFor(
          tester,
          () => find
              .descendant(of: button, matching: find.text(label))
              .evaluate()
              .isNotEmpty,
          'recent button "$label"');
      await frames(tester);
      await tester.tap(button);
      await frames(tester);
    }

    Future<ActiveTerminalSession> opened(
        bool Function(ActiveTerminalSession) test, String what) async {
      await waitFor(tester, () => controller.state.sessions.any(test), what);
      return controller.state.sessions.lastWhere(test);
    }

    Future<void> waitScreen(ActiveTerminalSession s, Pattern text, String what,
        {int seconds = 40}) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!s.terminal.allText().contains(text)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Timed out: $what. Screen: ${jsonEncode(screen(s))}');
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> waitRemote(String check, String what,
        {int seconds = 30}) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (await remote(check) != 'yes') {
        if (DateTime.now().isAfter(deadline)) fail('Timed out: $what');
        await frames(tester, 10);
      }
    }

    /// 文字和回车分两次发：一次发过去的话，两个工具都把末尾的回车当成粘贴进来的换行，不提交。
    Future<void> say(ActiveTerminalSession s, String text) async {
      s.terminal.sendText(text);
      await frames(tester, 12);
      s.terminal.sendText('\r');
      await frames(tester, 4);
    }

    Future<void> shot(String name) async {
      debugPrint('AIC06 SHOT=$name');
      await frames(tester, 50);
    }

    Future<void> closeTab(ActiveTerminalSession s) async {
      final index = controller.state.sessions.indexOf(s);
      if (index >= 0) await controller.close(index);
      await frames(tester);
    }

    // tmux 标签只附着窗格、不挂启动参数（aiLaunch 是空的），参数从远端窗格进程读：
    // 窗格里跑的是 `exec <工具> <参数>`（AiCliLaunchSpec.sshCommand），panePid 就是工具本身。
    // Codex 0.166 的 npm 入口还会再 exec 成包里自带的原生程序（命令行变成 …/vendor/…/bin/codex），
    // 正赶上 exec 时读到的是空串，所以轮询到命令行对上为止。[pattern] 是 grep -E，命令行末尾带一个空格。
    Future<String> paneRuns(
        AiCliTmuxRun run, String pattern, String what) async {
      final cmdline = "tr '\\0' ' ' < /proc/${run.panePid}/cmdline";
      await waitRemote(
          "$cmdline | grep -qE -- '$pattern' && echo yes || echo no", what);
      return remote(cmdline);
    }

    Future<String> claudeFile(String id) =>
        remote('find ~/.claude/projects -name "$id.jsonl"');
    Future<String> claudeFilesIn(String dir) =>
        remote('ls "$dir" | grep "\\.jsonl\$" | sort | tr "\\n" " "');
    Future<String> cwdOf(String pattern) => remote(
        'readlink "/proc/\$(pgrep -f -- "$pattern" | head -1)/cwd" 2>/dev/null');

    // ---- Claude：在 tmux 里新建（App 指定 --session-id）----
    final tokA = token('a');
    await toolsSheet(fromHome: false);
    await launch(claude, repo, tmux: true);
    final a1 =
        await opened((s) => s.aiTmuxRun != null && s.connected, 'Claude tmux');
    final runA = a1.aiTmuxRun!;
    final itemA = await item((i) => i.tool == AiCliKind.claude);
    final idA = itemA.claudeSessionId!;
    expect(a1.aiLaunch, isNull);
    aic(
        'claude.pane',
        await paneRuns(runA, '$claude --session-id $idA \$',
            'Claude started with the assigned ID'));
    await waitScreen(a1, 'Claude Code v', 'Claude started');
    await frames(tester, 40);
    await say(a1, 'MOCK-REMEMBER $tokA');
    await waitScreen(a1, 'OK $tokA', 'Claude reply');
    expect((await lastMain())['headerSession'], idA,
        reason: 'Claude 用的是 App 指定的会话 ID');
    final fileA = await claudeFile(idA);
    expect(fileA, endsWith('/$idA.jsonl'));
    final projectA = fileA.substring(0, fileA.lastIndexOf('/'));
    aic('claude.new', 'id=$idA file=$fileA tmux=${runA.target.sessionId}');
    await shot('claude-new');

    // ---- 留在 tmux 里：断线后从最近工作返回，还是同一个进程、同一段对话 ----
    a1.sshClient!.close();
    await waitFor(tester, () => !a1.connected, 'Claude transport closed');
    await frames(tester, 20);
    await toolsSheet();
    await tapRecent(await item((i) => i.claudeSessionId == idA), '核对并返回 tmux');
    final a2 = await opened(
        (s) => s.connected && s.aiTmuxRun?.sameAs(runA) == true,
        'exact tmux return');
    expect(await remote('pgrep -fc -- "[-]-session-id $idA"'), '1',
        reason: '没有第二个 Claude 进程');
    await frames(tester, 20);
    await say(a2, 'MOCK-RECALL t2');
    await waitScreen(a2, 'RECALL t2 $tokA', 'recall after tmux return');
    final afterReturn = await lastMain();
    expect(afterReturn['headerSession'], idA);
    expect(afterReturn['userMessages'], 2);
    aic('claude.tmuxReturn', 'sameProcess=1 session=$idA userMessages=2');
    await shot('claude-tmux-return');

    // ---- 进程结束：tmux 目标没了，App 不附着别的，改成「按会话 ID 继续」 ----
    await say(a2, '/exit');
    await waitRemote(
        "tmux has-session -t '${runA.target.sessionId}' 2>/dev/null && echo no || echo yes",
        'Claude tmux session ended');
    await waitFor(tester, () => !a2.connected, 'tmux client ended');
    await closeTab(a2);
    await closeTab(a1);

    // 同目录里另造一段更新的对话。按 ID 继续必须回到 idA，而不是「最近一段」（--continue 会选中它）。
    final decoyA = token('d');
    expect(
        // </dev/null：-p 模式下标准输入不是终端就会等它读完，SSH exec 的标准输入一直开着。
        await remote(
            "cd ~/aic/repo && /usr/local/bin/claude -p 'MOCK-REMEMBER $decoyA' </dev/null"),
        contains('OK $decoyA'));
    final filesBefore = await claudeFilesIn(projectA);
    expect(filesBefore.trim().split(' '), hasLength(2), reason: 'idA 和那段更新的对话');
    final decoyId = (await lastMain())['headerSession'] as String;
    expect(decoyId, isNot(idA));
    final decoyLines = await remote('wc -l < "$projectA/$decoyId.jsonl"');

    await toolsSheet();
    await tapRecent(await item((i) => i.claudeSessionId == idA), '核对并返回 tmux');
    await waitFor(
        tester,
        () =>
            find.textContaining('已经不在了').evaluate().isNotEmpty ||
            find.textContaining('已结束').evaluate().isNotEmpty,
        'tmux target gone message');
    expect(controller.state.sessions, isEmpty, reason: '目标没了就不附着、不新建');
    await tapRecent(await item((i) => i.claudeSessionId == idA), '按会话 ID 继续');
    final a3 = await opened(
        (s) => s.connected && s.aiTmuxRun == null, 'Claude exact resume');
    expect(a3.aiLaunch!.arguments, ['--resume', idA]);
    await waitScreen(a3, 'Claude Code v', 'Claude resumed');
    await frames(tester, 40);
    await say(a3, 'MOCK-RECALL t3');
    await waitScreen(a3, 'RECALL t3 $tokA', 'recall after exact resume');
    final resumed = await lastMain();
    expect(resumed['headerSession'], idA);
    expect(resumed['userMessages'], 3);
    expect(await cwdOf('[-]-resume $idA'), repo);
    expect(await claudeFilesIn(projectA), filesBefore,
        reason: '按 ID 继续没有新建会话文件');
    expect(await remote('wc -l < "$projectA/$decoyId.jsonl"'), decoyLines,
        reason: '更新的那段对话没被动过');
    aic('claude.exactResume',
        'args=--resume,$idA cwd=$repo userMessages=3 decoy=$decoyId untouched');
    await shot('claude-exact-resume');
    await say(a3, '/exit');
    await waitFor(tester, () => !a3.connected, 'Claude resumed process ended');
    await closeTab(a3);

    // ---- 另一个 worktree：同一个仓库的另一个目录，各续各的 ----
    final tokB = token('b');
    await toolsSheet();
    await launch(claude, worktree);
    final b1 = await opened(
        (s) => s.connected && s.aiLaunch?.projectDirectory == worktree,
        'Claude in worktree');
    final idB = b1.aiLaunch!.arguments.last;
    expect(idB, isNot(idA));
    await waitScreen(b1, 'Claude Code v', 'Claude worktree started');
    await frames(tester, 40);
    await say(b1, 'MOCK-REMEMBER $tokB');
    await waitScreen(b1, 'OK $tokB', 'Claude worktree reply');
    expect((await lastMain())['headerSession'], idB);
    final fileB = await claudeFile(idB);
    expect(fileB, contains('repo-wt/'));
    await say(b1, '/exit');
    await waitFor(tester, () => !b1.connected, 'Claude worktree ended');
    await closeTab(b1);
    await toolsSheet();
    await tapRecent(await item((i) => i.claudeSessionId == idB), '按会话 ID 继续');
    final b2 = await opened(
        (s) => s.connected && s.aiLaunch?.arguments.last == idB, 'resume B');
    expect(b2.aiLaunch!.arguments, ['--resume', idB]);
    await waitScreen(b2, 'Claude Code v', 'Claude worktree resumed');
    await frames(tester, 40);
    await say(b2, 'MOCK-RECALL t5');
    await waitScreen(b2, 'RECALL t5 $tokB', 'worktree recall');
    expect((await lastMain())['headerSession'], idB);
    expect(await cwdOf('[-]-resume $idB'), worktree);
    aic('claude.worktree', 'id=$idB file=$fileB cwd=$worktree recall=$tokB');
    await say(b2, '/exit');
    await waitFor(tester, () => !b2.connected, 'Claude worktree resume ended');
    await closeTab(b2);

    // ---- 会话文件没了（被删、换了机器）：工具报错退出，App 不改用 --continue、不新建 ----
    await remote('mv "$fileA" ~/aic-moved/');
    final requestsBefore = (await mainRequests()).length;
    await toolsSheet();
    await tapRecent(await item((i) => i.claudeSessionId == idA), '按会话 ID 继续');
    final a4 = await opened(
        (s) => s.aiLaunch?.arguments.last == idA, 'resume missing A');
    expect(a4.aiLaunch!.arguments, ['--resume', idA]);
    await waitScreen(a4, 'No conversation found', 'missing ID refused');
    await waitFor(tester, () => !a4.connected, 'missing ID process ended');
    expect((await mainRequests()).length, requestsBefore, reason: '没有发出任何对话请求');
    expect(await claudeFilesIn(projectA), '$decoyId.jsonl', reason: '没有新建会话');
    expect(
        (await item((i) =>
                i.tool == AiCliKind.claude &&
                i.projectDirectory == repo &&
                i.executable == claude))
            .claudeSessionId,
        idA,
        reason: '记录还指着原 ID，没被换成别的');
    aic('claude.missingId',
        'refused; requests=$requestsBefore unchanged; no new session');
    await shot('claude-missing-id');
    await closeTab(a4);
    await remote('mv ~/aic-moved/$idA.jsonl "$projectA/"');

    // ---- 配置身份换了：主机上的环境变量能让工具换一个账号/历史目录，旧记录不再显示 ----
    container.read(homeTabProvider.notifier).state = 0;
    await vault.upsertHost(HostProfile({
      ...host.data,
      'environmentVariables': [
        {'name': 'CLAUDE_CONFIG_DIR', 'value': '/home/fixture/.claude-other'}
      ],
    }));
    await frames(tester, 20);
    expect(find.byKey(const ValueKey('vault-recent-ai-work')), findsNothing);
    await vault.upsertHost(host);
    await frames(tester, 20);
    expect(find.byKey(const ValueKey('vault-recent-ai-work')), findsOneWidget);
    aic('claude.configIdentity',
        'CLAUDE_CONFIG_DIR change hides records; restore shows them');

    // ---- 不支持的版本：1.0.0 不认 --session-id，App 不替它换成不带 ID 的启动 ----
    await toolsSheet();
    await launch(oldClaude, repo);
    final o1 =
        await opened((s) => s.aiLaunch?.executable == oldClaude, 'old Claude');
    expect(o1.aiLaunch!.arguments.first, '--session-id');
    final idOld = o1.aiLaunch!.arguments.last;
    await waitScreen(
        o1, "unknown option '--session-id'", 'old version refused');
    await waitFor(tester, () => !o1.connected, 'old version exited');
    await closeTab(o1);
    await toolsSheet();
    await tapRecent(await item((i) => i.claudeSessionId == idOld), '按会话 ID 继续');
    final o2 = await opened(
        (s) => s.aiLaunch?.executable == oldClaude, 'old Claude resume');
    expect(o2.aiLaunch!.arguments, ['--resume', idOld]);
    await waitScreen(o2, 'No conversation found', 'old version resume refused');
    await waitFor(tester, () => !o2.connected, 'old version resume exited');
    expect((await mainRequests()).length, requestsBefore);
    expect(
        await remote(
            'find ~/.claude/projects -maxdepth 2 -name "*.jsonl" | wc -l'),
        '3',
        reason: 'idA、那段更新的对话、idB，旧版本没建任何会话');
    aic('claude.unsupportedVersion',
        'unknown option; resume refused; no request; no session');
    await closeTab(o2);

    // ---- Codex：没有可靠的会话 ID，进程结束后由用户在 Codex 自己的历史列表里选 ----
    final tokC = token('c');
    await toolsSheet();
    await launch(codex, codexProject, tmux: true);
    final c1 =
        await opened((s) => s.connected && s.aiTmuxRun != null, 'Codex tmux');
    final runC = c1.aiTmuxRun!;
    // 末尾就是程序名：不带 resume/--last 这类参数。
    aic('codex.pane',
        await paneRuns(runC, '/codex \$', 'Codex started without arguments'));
    await waitScreen(c1, 'OpenAI Codex', 'Codex started');
    await frames(tester, 40);
    await say(c1, 'MOCK-REMEMBER $tokC');
    await waitScreen(c1, 'OK $tokC', 'Codex reply');
    final sidC = (await lastMain())['session'] as String;
    expect(await remote('find ~/.codex/sessions -name "*-$sidC.jsonl" | wc -l'),
        '1');
    await shot('codex-new');
    c1.sshClient!.close();
    await waitFor(tester, () => !c1.connected, 'Codex transport closed');
    await frames(tester, 20);
    await toolsSheet();
    await tapRecent(await item((i) => i.tool == AiCliKind.codex), '核对并返回 tmux');
    final c2 = await opened(
        (s) => s.connected && s.aiTmuxRun?.sameAs(runC) == true,
        'Codex tmux return');
    await frames(tester, 20);
    await say(c2, 'MOCK-RECALL t9');
    await waitScreen(c2, 'RECALL t9 $tokC', 'Codex recall after tmux return');
    expect((await lastMain())['session'], sidC);
    aic('codex.tmuxReturn', 'session=$sidC');
    await say(c2, '/exit');
    await waitRemote(
        "tmux has-session -t '${runC.target.sessionId}' 2>/dev/null && echo no || echo yes",
        'Codex tmux session ended');
    await waitFor(tester, () => !c2.connected, 'Codex tmux client ended');
    await closeTab(c2);
    await closeTab(c1);

    // 同目录里另开一段更新的交互式对话（codex exec 开的不进历史列表）。列表默认选中最新的：
    // App 不替用户选（不用 --last），用户移到原来那段再回车。
    final decoyC = token('e');
    await remote('''
cd ~/aic/codex
tmux -L aic06decoy new-session -d -x 100 -y 30 /usr/local/bin/codex
sleep 7; tmux -L aic06decoy send-keys -l 'MOCK-REMEMBER $decoyC'; sleep 0.5; tmux -L aic06decoy send-keys Enter; sleep 5
tmux -L aic06decoy send-keys -l /exit; sleep 0.5; tmux -L aic06decoy send-keys Enter; sleep 3
tmux -L aic06decoy kill-server 2>/dev/null || :
''');
    final decoySession = await lastMain();
    expect(decoySession['token'], decoyC);
    expect(decoySession['session'], isNot(sidC));
    await toolsSheet();
    await tapRecent(await item((i) => i.tool == AiCliKind.codex), '核对并返回 tmux');
    await waitFor(
        tester,
        () =>
            find.textContaining('已经不在了').evaluate().isNotEmpty ||
            find.textContaining('已结束').evaluate().isNotEmpty,
        'Codex tmux target gone message');
    await tapRecent(
        await item((i) => i.tool == AiCliKind.codex), '选择 Codex 历史');
    final c3 = await opened(
        (s) =>
            s.connected &&
            s.aiTmuxRun == null &&
            s.aiLaunch?.executable == codex,
        'Codex history picker');
    expect(c3.aiLaunch!.arguments, ['resume']);
    await waitScreen(c3, 'MOCK-REMEMBER $decoyC', 'picker shows newer session');
    await waitScreen(
        c3, 'MOCK-REMEMBER $tokC', 'picker shows original session');
    String selected() =>
        screen(c3).firstWhere((l) => l.contains('›'), orElse: () => '');
    expect(selected(), contains(decoyC), reason: 'Codex 自己默认选最新的');
    await shot('codex-picker');
    c3.terminal.sendKey(TerminalSpecialKey.arrowDown);
    await frames(tester, 10);
    expect(selected(), contains(tokC));
    c3.terminal.sendText('\r');
    // 列表里只显示第一句提问；看到那段的回复重画出来，才算真的续上、输入框可以打字了。
    await waitScreen(c3, 'OK $tokC', 'Codex history redrawn');
    await frames(tester, 20);
    await say(c3, 'MOCK-RECALL t10');
    await waitScreen(c3, 'RECALL t10 $tokC', 'Codex recall after picker');
    expect((await lastMain())['session'], sidC);
    expect(await remote('find ~/.codex/sessions -name "*.jsonl" | wc -l'), '2',
        reason: '原来那段和更新的那段，没有因为继续而多出一段');
    aic('codex.picker',
        'args=resume defaultSelected=newer userPicked=$sidC recall=$tokC');
    await shot('codex-picked');
    await say(c3, '/exit');
    await waitFor(tester, () => !c3.connected, 'Codex resumed ended');
    await closeTab(c3);

    // 历史列表和终端里显示过的提问不进 App 的存储：最近工作只有工具、目录、会话 ID、tmux 目标这些指针。
    // 存储本身是加密的，直接 grep 私有文件搜不到也说明不了什么，所以查解密后写进去的那份。
    final items = await recent.load(scope);
    final stored = jsonEncode([for (final i in items) i.toJson()]);
    for (final t in [tokA, tokB, tokC, decoyA, decoyC, 'MOCK-']) {
      expect(stored, isNot(contains(t)), reason: '最近工作里不该有对话内容');
    }
    aic('noPromptStored', 'items=${items.length} promptsFound=0');

    expect(tester.takeException(), isNull);
    aic('PASS',
        'claude-new-tmux,tmux-return,exit-exact-resume,newer-same-dir,worktree,missing-id,config-identity,unsupported-version,codex-new-tmux,tmux-return,picker,no-prompt-stored');
  }, skip: config.isEmpty, timeout: const Timeout(Duration(minutes: 12)));
}
