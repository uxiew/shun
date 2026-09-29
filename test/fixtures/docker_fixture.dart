import 'dart:convert';
import 'dart:io';

/// 读取 tool/fixture-environment/up.sh 生成的 .run/fixture.json。
///
/// 返回 null 表示 Docker fixture 没起来。依赖它的测试必须 skip 并在证据里记 NOT_RUN，
/// 不能当作通过。
class DockerFixture {
  DockerFixture._(this.json);

  static const skipReason =
      'Docker fixture 未启动：先运行 tool/fixture-environment/up.sh（结果按 NOT_RUN 记录）';

  static DockerFixture? load() {
    final file = File('tool/fixture-environment/.run/fixture.json');
    if (!file.existsSync()) return null;
    return DockerFixture._(
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    );
  }

  final Map<String, dynamic> json;

  String get user => json['user'] as String;
  String get password => json['password'] as String;
  String get privateKeyPem =>
      File(json['privateKeyPath'] as String).readAsStringSync();

  Map<String, dynamic> get _edge => json['sshEdge'] as Map<String, dynamic>;
  Map<String, dynamic> get _target => json['target'] as Map<String, dynamic>;
  Map<String, dynamic> get _hop2 => json['hop2'] as Map<String, dynamic>;
  Map<String, dynamic> get _hop3 => json['hop3'] as Map<String, dynamic>;
  Map<String, dynamic> get _socksAuth =>
      json['socksAuth'] as Map<String, dynamic>;
  Map<String, dynamic> get _socksNoAuth =>
      json['socksNoAuth'] as Map<String, dynamic>;

  String get edgeHost => _edge['host'] as String;
  int get edgePort => _edge['port'] as int;
  String get edgeFingerprint => _edge['fingerprintSha256'] as String;

  String get targetName => _target['name'] as String;
  int get targetPort => _target['port'] as int;
  String get targetFingerprint => _target['fingerprintSha256'] as String;

  /// 多跳的第二跳，只在容器网络里可达（本机解析不了这个名字）。
  String get hop2Name => _hop2['name'] as String;
  int get hop2Port => _hop2['port'] as int;
  String get hop2Fingerprint => _hop2['fingerprintSha256'] as String;

  /// 多跳的第三跳，同样只在容器网络里可达。
  String get hop3Name => _hop3['name'] as String;
  int get hop3Port => _hop3['port'] as int;
  String get hop3Fingerprint => _hop3['fingerprintSha256'] as String;

  String get socksAuthHost => _socksAuth['host'] as String;
  int get socksAuthPort => _socksAuth['port'] as int;
  String get socksUser => _socksAuth['username'] as String;
  String get socksPassword => _socksAuth['password'] as String;
  int get socksNoAuthPort => _socksNoAuth['port'] as int;
}
