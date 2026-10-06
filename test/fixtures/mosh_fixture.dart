import 'dart:convert';
import 'dart:io';

import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/plugins/mosh_route.dart';

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
      fp == (host.port == nomoshPort ? nomoshFingerprint : fingerprint);

  /// 此刻的计数（tool/mosh-fixture/counts.sh）。看差值，不看绝对值。
  Future<Map<String, dynamic>> counts() async {
    final result = await Process.run('tool/mosh-fixture/counts.sh', const []);
    if (result.exitCode != 0) {
      throw StateError('counts.sh 失败：${result.stderr}');
    }
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  }

  /// 在装了 mosh 的那台里以 root 执行（docker exec，不经 SSH，不算一次登录）。
  Future<String> exec(String command, {String service = 'mosh'}) async {
    final result = await Process.run('docker', [
      'compose',
      '-f',
      'tool/mosh-fixture/compose.yaml',
      'exec',
      '-T',
      service,
      'sh',
      '-c',
      command,
    ]);
    return (result.stdout as String).trim();
  }
}
