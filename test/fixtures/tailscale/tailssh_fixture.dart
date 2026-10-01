import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 起 tool/tailscale-ssh-fixture（照 tailssh v1.104.0 认证行为仿制的本机 SSH 服务器）。
///
/// 返回 null 表示起不来（没装 Go、第一次下载依赖失败等），依赖它的测试 skip，证据里记 NOT_RUN。
/// 二进制和依赖缓存都放在仓库外 `../.toolchain/go`，不碰用户自己的 ~/go。
class TailsshFixture {
  TailsshFixture._(this._process, this.sshPort, this.controlPort,
      this.fingerprint, this._log);

  static const skipReason =
      'Tailscale SSH fixture 起不来（需要 Go，见 tool/tailscale-ssh-fixture/README.md）：结果按 NOT_RUN 记录';

  static const _dir = 'tool/tailscale-ssh-fixture';

  final Process _process;
  final int sshPort;
  final int controlPort;

  /// 主机指纹，格式和 dartssh2 交给指纹回调的一样（SHA256:base64 无填充）。
  final String fingerprint;
  final StringBuffer _log;

  static Future<TailsshFixture?> start({Duration? holdLimit}) async {
    final binary = File('$_dir/.run/tailssh-fixture');
    final source = File('$_dir/main.go');
    if (!binary.existsSync() ||
        binary.lastModifiedSync().isBefore(source.lastModifiedSync())) {
      final toolchain = Directory('../.toolchain').absolute.path;
      try {
        final build = await Process.run(
          'go',
          ['build', '-o', '.run/tailssh-fixture', '.'],
          workingDirectory: _dir,
          environment: {
            'GOPATH': '$toolchain/go',
            'GOMODCACHE': '$toolchain/go/pkg/mod',
            'GOCACHE': '$toolchain/go/cache',
            'GOTOOLCHAIN': 'local',
            'GOFLAGS': '-modcacherw',
          },
        );
        if (build.exitCode != 0) return null;
      } on ProcessException {
        return null;
      }
    }
    final process = await Process.start(binary.path, [
      if (holdLimit != null) '-hold-limit=${holdLimit.inMilliseconds}ms',
    ]);
    final log = StringBuffer();
    process.stderr.transform(utf8.decoder).listen((chunk) => log.write(chunk));
    final first = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    final state = jsonDecode(first) as Map<String, dynamic>;
    return TailsshFixture._(
      process,
      state['sshPort'] as int,
      state['controlPort'] as int,
      state['fingerprintSha256'] as String,
      log,
    );
  }

  Future<Object?> _call(String method, String path) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.openUrl(
          method, Uri.parse('http://127.0.0.1:$controlPort/$path'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  /// 服务器记下的全部事件：每次认证请求的方法、收到的密码长度、发出的 banner、挂起和裁决。
  Future<List<Map<String, dynamic>>> events() async =>
      ((await _call('GET', 'events')) as List).cast<Map<String, dynamic>>();

  Future<List<Map<String, dynamic>>> eventsFor(String user) async {
    final all = await events();
    final conns = {
      for (final e in all)
        if (e['user'] == user) e['conn'],
    };
    return [
      for (final e in all)
        if (conns.contains(e['conn'])) e,
    ];
  }

  /// 等到有一个挂起的 check，返回它的 id。
  Future<String> pendingCheck(String user,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final stop = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(stop)) {
      // 取最新的一个：前面的用例（比如超时）可能留下还挂着的旧 check。
      final checks = ((await _call('GET', 'checks')) as List)
          .cast<Map<String, dynamic>>()
          .where((check) => check['user'] == user)
          .toList()
        ..sort((a, b) => (b['conn'] as int).compareTo(a['conn'] as int));
      if (checks.isNotEmpty) return checks.first['id'] as String;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('fixture 上没有等到 $user 的 check');
  }

  /// 模拟用户在浏览器里批准 / 拒绝了 check。
  Future<void> decide(String checkId, {required bool approve}) =>
      _call('POST', 'checks/$checkId/${approve ? 'approve' : 'deny'}');

  String get log => _log.toString();

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
