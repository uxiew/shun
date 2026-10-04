import 'dart:convert';
import 'dart:io';

/// 读 `../up.sh` 生成的 `.run/fixture.json`，用系统 ssh 在容器里执行固定命令。
///
/// 只做 X08 的手工 bootstrap：真正产品里的受控 bootstrap 在宿主（X09），不是这里。
/// 主机密钥按 fixture 写出的公钥严格核对，不用 StrictHostKeyChecking=no。
class MoshFixture {
  MoshFixture._(this._json, this._knownHosts);

  final Map<String, dynamic> _json;
  final File _knownHosts;

  static MoshFixture? tryLoad() {
    final file = File('../.run/fixture.json');
    if (!file.existsSync()) return null;
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final dir = Directory.systemTemp.createTempSync('mosh-probe-');
    final knownHosts = File('${dir.path}/known_hosts')
      ..writeAsStringSync(
        '[127.0.0.1]:${json['sshPort']} ${json['keyType']} ${json['publicKeyBase64']}\n',
      );
    return MoshFixture._(json, knownHosts);
  }

  String get host => _json['host'] as String;
  int get firstUdpPort => (_json['udpPorts'] as List)[0] as int;
  int get lastUdpPort => (_json['udpPorts'] as List)[1] as int;

  List<String> _sshArgs({bool tty = false}) => [
    '-F',
    '/dev/null',
    '-o',
    'IdentityAgent=none',
    '-o',
    'IdentitiesOnly=yes',
    '-o',
    'BatchMode=yes',
    '-o',
    'StrictHostKeyChecking=yes',
    '-o',
    'UserKnownHostsFile=${_knownHosts.path}',
    '-o',
    'LogLevel=ERROR',
    '-i',
    _json['privateKeyPath'] as String,
    '-p',
    '${_json['sshPort']}',
    if (tty) '-tt',
    '${_json['user']}@${_json['host']}',
  ];

  /// 不分配 PTY 执行一条命令，返回 stdout + stderr。
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final result = await Process.run(
      'ssh',
      [..._sshArgs(), command],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);
    return '${result.stdout}${result.stderr}';
  }

  /// 起一个 mosh-server，跑 [program]（固定字符串，测试自己写的），返回原始 bootstrap 输出。
  /// 尺寸要在 mosh-server 启动前就定：它在客户端连上之前就会按 80x24 起子进程。
  Future<String> startServer(
    String program, {
    String locale = 'LANG=en_US.UTF-8',
  }) {
    final quoted = "'${program.replaceAll("'", r"'\''")}'";
    return run(
      'mosh-server new -c 256 -l $locale -p $firstUdpPort:$lastUdpPort -- sh -c $quoted',
    );
  }

  /// 对照：容器里的官方 mosh-client（Alpine 打包的 1.4.0）在 tmux 里连同一种 mosh-server 跑 [program]，
  /// 返回 tmux 抓到的屏幕。这就是「官方客户端用户看到的样子」。[keys] 在连上后经 tmux 发给客户端。
  Future<String> officialClientScreen(
    String program, {
    int cols = 80,
    int rows = 24,
    List<String> keys = const [],
    int settleSeconds = 3,
  }) async {
    final b64 = base64.encode(utf8.encode(program));
    final keyCmds = keys
        .map(
          (k) =>
              "tmux send-keys -t oracle -l -- '${k.replaceAll("'", r"'\''")}'; sleep 1;",
        )
        .join(' ');
    final script = [
      'P=\$(echo $b64 | base64 -d)',
      'OUT=\$(mosh-server new -c 256 -l LANG=en_US.UTF-8 -p $firstUdpPort:$lastUdpPort -- sh -c "\$P" 2>/dev/null)',
      'PORT=\$(echo "\$OUT" | sed -n "s/^MOSH CONNECT \\([0-9]*\\) .*/\\1/p")',
      'KEY=\$(echo "\$OUT" | sed -n "s/^MOSH CONNECT [0-9]* \\(.*\\)/\\1/p")',
      'tmux new-session -d -s oracle -x $cols -y $rows "env MOSH_KEY=\$KEY LANG=en_US.UTF-8 mosh-client 127.0.0.1 \$PORT"',
      'sleep $settleSeconds',
      keyCmds,
      'tmux capture-pane -p -t oracle',
      'tmux kill-server',
    ].where((c) => c.isNotEmpty).join('; ');
    final out = await run(script, timeout: const Duration(seconds: 60));
    final lines = out.split('\n').map((l) => l.trimRight()).toList();
    while (lines.length > rows) {
      lines.removeLast();
    }
    while (lines.length < rows) {
      lines.add('');
    }
    return lines.join('\n');
  }

  /// 远端还剩几个 mosh-server 进程（看清理是否到位）。
  Future<int> serverProcessCount() async {
    final out = await run('pgrep -x mosh-server | wc -l');
    return int.parse(out.trim());
  }

  Future<void> killAllServers() => run('pkill -x mosh-server; true');
}
