import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli_launch.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/tmux/ai_cli_tmux_service.dart';

import 'fixtures/tmux_fixture.dart';

// R28 / SEC11：AI 工具在 tmux 里启动时，项目目录和工具路径是远端检测或用户填的，
// 只拒控制字符（validateAiCliPath），分号、引号、$()、反引号都能进来。
// 在真 tmux 上跑，看它们有没有被当成命令执行——执行了就会在 ~/r28 里留下 pwn 文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final f = TmuxFixture.load();
  final skip = f == null ? TmuxFixture.skipReason : false;
  const ai = AiCliTmuxService();
  final socket = TmuxSocketSpec.named('r28ai');
  // 每一种写法都对应一个带编号的 pwn 文件，哪种被执行了一眼就能看出来。
  const evil = "a;touch \$HOME/r28/pwn1;'b\"\$(touch \$HOME/r28/pwn2)\"`touch \$HOME/r28/pwn3`"
      r" #{session_name} %1 \\x";
  final b64 = base64Encode(utf8.encode(evil));
  const node = 'tmux35';

  Future<void> remote(String script) => f!.run(node, script);
  Future<String> pwned() => f!.run(node, 'ls ~/r28 | grep pwn || :');

  setUpAll(() async {
    if (f == null) return;
    await remote('rm -rf ~/r28; mkdir -p ~/r28 && '
        'd=\$(printf %s $b64 | base64 -d) && mkdir -p "\$HOME/r28/\$d" && '
        "printf '#!/bin/sh\\npwd -P > \"\$HOME/r28/ran\"\\nexec sleep 60\\n' > ~/r28/tool && "
        'chmod +x ~/r28/tool');
    // 对照：标记搜法本身有效——这个名字如果被当成命令，确实会留下 pwn 文件。
    await remote('cd ~/r28 && sh -c "echo $evil" >/dev/null 2>&1 || :');
    expect(await pwned(), contains('pwn'));
    await remote('rm -f ~/r28/pwn*');
    expect(await pwned(), isEmpty);
  });
  tearDownAll(() async {
    if (f == null) return;
    await remote('tmux -L r28ai kill-server 2>/dev/null || :; rm -rf ~/r28');
  });

  Future<void> start(String requestId, AiCliLaunchSpec launch) async {
    final host = f!.host(node);
    final plan =
        resolveRoutePlan(host, hosts: [host], proxyProfiles: const []);
    await SshService().withVerifiedClientForAiTmux(
      routePlan: plan,
      verifyHostKey: f.verify,
      attempt: ConnectionAttempt(),
      action: (client) => ai.start(
        client,
        hostKey: plan.target.endpoint.authority,
        socket: socket,
        requestId: requestId,
        launch: launch,
        onCreateAttempted: () {},
      ),
    );
  }

  for (final (i, directory) in [
    (1, '/home/fixture/r28/$evil'),
    (2, '~/r28/$evil'),
  ]) {
    test('SEC11 AI tmux 启动：目录名里的 ; \' " \$() ` #{} 只是名字（$directory）',
        () async {
      await remote('rm -f ~/r28/ran ~/r28/pwn*');
      await start('7a1b2c3d-0000-4000-8000-00000000000$i',
          AiCliLaunchSpec(
              executable: '/home/fixture/r28/tool',
              projectDirectory: directory));
      var ran = '';
      for (var n = 0; n < 50 && ran.isEmpty; n++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        ran = await f!.run(node, 'cat ~/r28/ran 2>/dev/null || :');
      }
      expect(ran, '/home/fixture/r28/$evil', reason: '工具应当在这个怪名字的目录里启动');
      expect(await pwned(), isEmpty);
    }, skip: skip);
  }

  test('SEC11 AI tmux 启动：不存在的怪目录、怪工具路径只会启动失败，不执行里面的命令', () async {
    await remote('rm -f ~/r28/ran ~/r28/pwn*');
    // 启动失败可以报错也可以不报（窗格里的 sh 自己以 125/126 退出），这里只看有没有副作用。
    await start(
        '7a1b2c3d-0000-4000-8000-000000000003',
        AiCliLaunchSpec(
            executable: '/home/fixture/r28/tool',
            projectDirectory: '/home/fixture/r28/nope;touch \$HOME/r28/pwn4'))
        .catchError((Object _) {});
    await start(
        '7a1b2c3d-0000-4000-8000-000000000004',
        AiCliLaunchSpec(
            executable: '/home/fixture/r28/to ol;touch \$HOME/r28/pwn5',
            projectDirectory: '/home/fixture/r28'))
        .catchError((Object _) {});
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(await f!.run(node, 'test -e ~/r28/ran && echo ran || :'), isEmpty);
    expect(await pwned(), isEmpty);
  }, skip: skip);
}
