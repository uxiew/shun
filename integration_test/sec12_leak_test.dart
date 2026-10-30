// SEC12 设备验证：崩溃、通知、Intent、最近任务截图和整机日志里，有没有密码、代理口令、私钥、按键和终端原文。
// 真 App 页面 + 真 SSH（测试环境的 ssh-edge / dante / target）：密码、经带口令的 SOCKS、私钥三种登录各连一次，
// 错密码、错代理口令各连一次；在终端里打字、让远端输出一段字，再发改标题、发通知、写剪贴板的控制序列；
// 切到最近任务再回来；最后停在这里等驱动脚本把 App 弄崩。上面这些字都是驱动脚本每轮随机生成的标记，
// 脚本事后在 logcat、dropbox、通知、Activity/最近任务记录、私有目录里搜它们。
//
// 不是 CI 测试，只用 tool/sec12-device.py 跑。输出以 "SEC12 " 开头的行是证据，也是给脚本的指令：
//   SEC12 STEP <名字>   脚本做完这一步在 App 私有目录放 sec12-<名字>-done；crash 这一步不放，直接弄崩
// 这个文件自己打到 logcat 的任何一行都不能带标记，否则脚本会把测试自己打的当成泄露：只报是否、个数。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/port_forward_controller.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/ai_cli_launch.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';

const _raw = String.fromEnvironment('SEC12');
final Map<String, dynamic> config =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

void report(String key, Object? value) => debugPrint('SEC12 $key=$value');

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
  WidgetController.hitTestWarningShouldBeFatal = true;
  final skip = config.isEmpty ? '没给 SEC12，用 tool/sec12-device.py 跑' : false;

  testWidgets('SEC12 三种登录、两种失败、打字和远端输出、远端效果、最近任务，最后等崩溃', (tester) async {
    final private = (await getApplicationSupportDirectory()).path;
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester, 1500);

    Future<void> step(String name,
        {Duration timeout = const Duration(seconds: 90)}) async {
      final done = File('$private/sec12-$name-done');
      if (done.existsSync()) done.deleteSync();
      debugPrint('SEC12 STEP $name');
      await waitFor(tester, done.existsSync,
          timeout: timeout, what: '驱动脚本做完 $name');
      await settle(tester, 500);
    }

    final vault = container.read(vaultControllerProvider.notifier);
    final controller = container.read(sessionControllerProvider.notifier);
    final data = await vault.ready();
    await vault.replace(data.copyWith(keys: [
      ...data.keys,
      SshKeyProfile({
        'id': 'sec12-key',
        'label': 'SEC12 key',
        'privateKey': config['privateKey'],
        'passphrase': '',
      }),
    ]));

    final fingerprints = {
      '127.0.0.1': config['edgeFingerprint'],
      config['targetName']: config['targetFingerprint'],
    };
    Future<bool> verify(HostProfile host, String _, String fingerprint) async =>
        fingerprint == fingerprints[host.hostname];

    HostProfile host(String id, Map<String, Object?> data) => HostProfile({
          'id': id,
          'label': id,
          'username': config['user'],
          'password': config['password'],
          'authMethod': 'password',
          'protocol': 'ssh',
          ...data,
        });
    Map<String, Object?> socks(String password) => {
          'hostname': config['targetName'],
          'port': config['targetPort'],
          'proxyConfig': {
            'type': 'socks5',
            'host': '127.0.0.1',
            'port': config['socksPort'],
            'username': config['socksUser'],
            'password': password,
          },
        };
    final edge = {'hostname': '127.0.0.1', 'port': config['edgePort']};
    final password = host('sec12-password', edge);
    final viaSocks = host('sec12-socks', socks('${config['socksPassword']}'));
    final withKey = host('sec12-key', {
      ...edge,
      'authMethod': 'key',
      'password': null,
      'identityFileId': 'sec12-key',
    });
    final wrongPassword = host(
        'sec12-wrong-password', {...edge, 'password': config['wrongPassword']});
    final wrongProxy =
        host('sec12-wrong-proxy', socks('${config['wrongProxyPassword']}'));
    for (final h in [password, viaSocks, withKey, wrongPassword, wrongProxy]) {
      await vault.upsertHost(h);
    }
    await settle(tester, 800);

    for (final h in [password, viaSocks, withKey]) {
      expect(await controller.connect(h, verify), isTrue, reason: h.id);
    }
    for (final h in [wrongPassword, wrongProxy]) {
      Object? error;
      try {
        if (!await controller.connect(h, verify)) error = 'returned false';
      } on Object catch (e) {
        error = e;
      }
      report('fail.${h.id}', error == null ? 'connected' : error.runtimeType);
      expect(error, isNotNull, reason: h.id);
    }
    report('sessions', controller.state.sessions.length);

    // 在私钥登录的那个标签上做这些事，终端页显示它。
    final index =
        controller.state.sessions.indexWhere((s) => s.host.id == withKey.id);
    controller.activate(index);
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester, 1500);
    final session = controller.state.sessions[index];
    final terminal = session.terminal;
    var runs = 0;
    Future<void> run(String command) async {
      final n = 7000 + ++runs;
      // 用算术展开当完成标记：回显里只有算式，输出里才有结果。
      controller.typeInto(session.id, '$command; echo SEC12D\$(($n))\r');
      await waitFor(tester, () => terminal.allText().contains('SEC12D$n'),
          what: '远端第 $runs 条命令');
      await settle(tester, 300);
    }

    // 按键：和软键盘、快捷键栏同一个出口。远端输出：拼出来的字，只在输出里、不在打的字里。
    await run(': ${config['typed']}');
    await run("printf '%s%s\\n' ${config['outputA']} ${config['outputB']}");
    report(
        'terminal.hasOutput',
        terminal
            .allText()
            .contains('${config['outputA']}${config['outputB']}'));
    // 远端想改窗口标题、发通知（OSC 9、OSC 777）、写剪贴板（OSC 52）。
    final clip = base64.encode(utf8.encode('${config['osc52']}'));
    await run(
        "printf '\\033]0;%s\\007\\033]9;%s\\007\\033]777;notify;%s;%s\\007\\033]52;c;%s\\007' "
        "${config['title']} ${config['osc9']} ${config['osc777']} x $clip");
    await settle(tester, 1500);
    final clipboard = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    report('clipboard.isRemote', clipboard == '${config['osc52']}');

    // R28：端口转发和 AI 工具是 SEC12 之后才加的入口，各走一遍。
    // 本地转发借这个标签的连接转到边缘自己的 sshd，经它送一串标记过去。
    final forwards = container.read(portForwardControllerProvider.notifier);
    await forwards.startLocal(
        session: session, localPort: 0, remoteHost: '127.0.0.1', remotePort: 22);
    final forward = container.read(portForwardControllerProvider).last;
    final socket = await Socket.connect('127.0.0.1', forward.localPort);
    final banner = <int>[];
    final reading = socket.listen(banner.addAll, onError: (Object _) {});
    await waitFor(tester, () => utf8.decode(banner, allowMalformed: true).contains('\n'),
        what: '转发过来的 SSH 版本行');
    socket.add(utf8.encode('${config['forwarded']}\r\n'));
    await socket.flush();
    await settle(tester, 500);
    await reading.cancel();
    socket.destroy();
    report('forward.banner', utf8.decode(banner, allowMalformed: true).startsWith('SSH-'));
    await forwards.stop(forward.id);

    // AI 工具：远端放一个只会打一行字的「工具」，按用户点启动的那条路新开专用终端（私钥登录）。
    // 输出拆成两半写进脚本，只有真跑起来才会拼在一起。
    await run("printf '#!/bin/sh\\nprintf %%s%%s\\\\n ${config['aiOutputA']} ${config['aiOutputB']}\\nexec sleep 60\\n' > ~/sec12-ai && chmod +x ~/sec12-ai");
    final now = await vault.ready();
    final aiPlan = resolveRoutePlan(withKey,
        hosts: now.hosts, proxyProfiles: now.proxyProfiles, keys: now.keys);
    expect(
        await controller.openAiCliTerminal(
          requestId: '00000000-0000-4000-8000-0000000012a1',
          host: withKey,
          routePlan: aiPlan,
          label: 'SEC12 AI',
          launch: AiCliLaunchSpec(
              executable: '/home/${config['user']}/sec12-ai',
              projectDirectory: '/home/${config['user']}'),
          verifyHostKey: verify,
        ),
        isTrue);
    final ai = controller.state.sessions.firstWhere((s) => s.aiLaunch != null);
    await waitFor(
        tester,
        () => ai.terminal
            .allText()
            .contains('${config['aiOutputA']}${config['aiOutputB']}'),
        what: 'AI 工具的输出');
    report('ai.hasOutput', true);
    // 后面的按键注入还是打到私钥登录的那个普通标签。
    controller.activate(
        controller.state.sessions.indexWhere((s) => s.id == session.id));
    await settle(tester, 1000);

    // 系统按键注入：脚本用 adb shell input text 打一串字再回车。到没到终端只报告，不算失败：
    // 这一步是为了让按键走一遍 Android 的输入链路，再看日志里有没有它。
    await step('type');
    await settle(tester, 2000);
    report('terminal.hasInjectedKeys',
        terminal.allText().contains('${config['injected']}'));

    // 最近任务：脚本切过去截屏、导出任务记录，再切回来。
    await step('recents');
    // 通知、Activity、网络、崩溃前的日志。
    await step('dump');
    report('sessions.beforeCrash', controller.state.sessions.length);

    // 等脚本把 App 弄崩。正常情况下进程就死在这里，下面的 fail 只在脚本没弄崩时才走到。
    debugPrint('SEC12 STEP crash');
    await settle(tester, 120000);
    fail('驱动脚本没有把 App 弄崩');
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 8)));
}
