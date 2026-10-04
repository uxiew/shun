import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:netcatty_mobile/domain/models/host.dart';

/// 读取 tool/tmux-fixture/up.sh 生成的 .run/fixture.json（R21 的 tmux 测试环境）。
///
/// 返回 null 表示环境没起来。依赖它的测试必须 skip，证据里记 NOT_RUN，不能当作通过。
class TmuxFixture {
  TmuxFixture._(this.json);

  static const skipReason =
      'tmux fixture 未启动：先运行 tool/tmux-fixture/up.sh（结果按 NOT_RUN 记录）';

  static TmuxFixture? load() {
    final file = File('tool/tmux-fixture/.run/fixture.json');
    if (!file.existsSync()) return null;
    return TmuxFixture._(
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    );
  }

  final Map<String, dynamic> json;

  String get password => json['password'] as String;

  Map<String, dynamic> _node(String name) =>
      (json['nodes'] as Map<String, dynamic>)[name] as Map<String, dynamic>;

  int port(String node) => _node(node)['port'] as int;
  String fingerprint(String node) => _node(node)['fingerprintSha256'] as String;
  String tmuxVersion(String node) => _node(node)['tmuxVersion'] as String;

  /// 四台真实 tmux：2.4、2.7、3.0a、3.5a。
  static const realNodes = ['tmux24', 'tmux27', 'tmux30', 'tmux35'];

  HostProfile host(String node, {String user = 'fixture'}) => HostProfile({
        'id': 'r21-$node-$user',
        'label': '$node-$user',
        'hostname': '127.0.0.1',
        'port': port(node),
        'username': user,
        'password': password,
        'authMethod': 'password',
        'protocol': 'ssh',
      });

  Future<bool> verify(HostProfile host, String algorithm, String fp) async {
    for (final node in (json['nodes'] as Map<String, dynamic>).keys) {
      if (port(node) == host.port) return fp == fingerprint(node);
    }
    return false;
  }

  /// 独立于被测代码的检查通道：直接用 dartssh2 登录。
  Future<SSHClient> client(String node, {String user = 'fixture'}) async =>
      SSHClient(
        await SSHSocket.connect('127.0.0.1', port(node)),
        username: user,
        onPasswordRequest: () => password,
        onVerifyHostKey: (_, fp) => utf8.decode(fp) == fingerprint(node),
      );

  Future<String> run(String node, String command,
      {String user = 'fixture'}) async {
    final ssh = await client(node, user: user);
    try {
      return utf8.decode(await ssh.run(command), allowMalformed: true).trim();
    } finally {
      ssh.close();
    }
  }

  /// 以 root 在容器里执行（模拟断网时杀 sshd 会话用）。
  Future<String> dockerExec(String node, String command) async {
    final result = await Process.run('docker', [
      'compose',
      '-f',
      'tool/tmux-fixture/compose.yaml',
      'exec',
      '-T',
      node,
      'sh',
      '-c',
      command,
    ]);
    if (result.exitCode != 0) {
      throw StateError('docker exec $node 失败：${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  /// 把某个 tmux 客户端所在的那条 SSH 连接在服务器那头直接杀掉（等于断网），只断这一条。
  Future<void> dropConnectionOf(String node, int clientPid) => dockerExec(
        node,
        'child=\$(awk "{print \\\$4}" /proc/$clientPid/stat); '
        'monitor=\$(awk "{print \\\$4}" /proc/\$child/stat); '
        'kill -9 \$child \$monitor',
      );

  /// 每个测试前清场：两个用户的 tmux server、socket 目录、测试文件都删掉。
  Future<void> reset(String node) async {
    for (final user in ['fixture', 'other']) {
      await run(
        node,
        // 先删 .faketmux：假 tmux 处在「挂住」模式时，下面的 kill-server 会一直卡着。
        'rm -f ~/.faketmux; '
        'for s in /tmp/tmux-\$(id -u)/* /tmp/r21-*; do [ -S "\$s" ] && tmux -S "\$s" kill-server 2>/dev/null; done; '
        'rm -rf /tmp/tmux-\$(id -u) /tmp/r21-* ~/.faketmux ~/.tmux.conf ~/r21-* 2>/dev/null; true',
        user: user,
      );
    }
  }
}
