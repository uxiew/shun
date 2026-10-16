import 'dart:convert';
import 'dart:io';

import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/plugins/mosh_route.dart';

/// 读取 tool/mosh-fixture/up.sh 生成的 .run/fixture.json（X08、X09 的 Mosh 测试环境）。
///
/// 返回 null 表示环境没起来。依赖它的测试必须 skip，证据里记 NOT_RUN，不能当作通过。
class MoshFixture {
  MoshFixture._(this.json);

  static const skipReason =
      'Mosh fixture 未启动：先运行 tool/mosh-fixture/up.sh（结果按 NOT_RUN 记录）';

  static MoshFixture? load() {
    final file = File('tool/mosh-fixture/.run/fixture.json');
    if (!file.existsSync()) return null;
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    // X08 时的 up.sh 不起 nomosh 那台、也没有记账脚本：这份环境出不了 X09 的计数证据。
    if (json['nomoshPort'] == null) return null;
    return MoshFixture._(json);
  }

  final Map<String, dynamic> json;

  String get user => json['user'] as String;
  String get password => json['password'] as String;
  int get sshPort => json['sshPort'] as int;
  String get fingerprint => json['fingerprintSha256'] as String;
  int get nomoshPort => json['nomoshPort'] as int;
  String get nomoshFingerprint => json['nomoshFingerprintSha256'] as String;

  /// Debian 那台（R41）：mosh-server 不在默认位置、没有 en_US.UTF-8。旧版 up.sh 起的环境里没有，为 null。
  int? get moshaltPort => json['moshaltPort'] as int?;
  String? get moshaltFingerprint => json['moshaltFingerprintSha256'] as String?;
  String? get moshaltServerPath => json['moshaltServerPath'] as String?;
  String? get moshaltLocale => json['moshaltLocale'] as String?;

  /// up.sh 只把这几个 UDP 端口映射出来，bootstrap 要让 mosh-server 在里面挑。
  String get udpPorts => (json['udpPorts'] as List).join(':');

  /// 一台 Mosh 主机：直连 127.0.0.1，用密码登录。[extra] 覆盖或补充字段（代理、跳板之类）。
  HostProfile host({int? port, Map<String, Object?> extra = const {}}) =>
      HostProfile({
        'id': 'x09-${port ?? sshPort}-${extra.hashCode}',
        'label': port == nomoshPort ? 'nomosh' : 'mosh',
        'hostname': '127.0.0.1',
        'port': port ?? sshPort,
        'username': user,
        'password': password,
        'authMethod': 'password',
        'protocol': 'mosh',
        moshPortsKey: udpPorts,
        ...extra,
      });

  Future<bool> verify(HostProfile host, String algorithm, String fp) async =>
      fp ==
      switch (host.port) {
        final p when p == nomoshPort => nomoshFingerprint,
        final p when p == moshaltPort => moshaltFingerprint,
        _ => fingerprint,
      };

  /// 此刻的计数（tool/mosh-fixture/counts.sh）。看差值，不看绝对值。
  Future<Map<String, dynamic>> counts() async {
    final result = await Process.run('tool/mosh-fixture/counts.sh', const []);
    if (result.exitCode != 0) {
      throw StateError('counts.sh 失败：${result.stderr}');
    }
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  }

  /// 在装了 mosh 的那台里以 root 执行（docker exec，不经 SSH，不算一次登录）。
  /// [user] 给了就换成这个用户（docker exec -u）：容器里的 su/sudo 是记账 shim，一调用就报「disabled」。
  Future<String> exec(
    String command, {
    String service = 'mosh',
    String? user,
  }) async {
    final result = await Process.run('docker', [
      'compose',
      '-f',
      'tool/mosh-fixture/compose.yaml',
      'exec',
      '-T',
      if (user != null) ...['-u', user],
      service,
      'sh',
      '-c',
      command,
    ]);
    return (result.stdout as String).trim();
  }
}
