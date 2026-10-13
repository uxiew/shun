import 'server_stats.dart';

/// [plugin]：由第三方终端插件承载（X12），插件自己联网；用哪个插件见 domain/plugins/plugin_host.dart。
enum HostProtocol { ssh, telnet, mosh, plugin, unknown }

enum HostAuthMethod { auto, password, key }

enum ProxyType { http, socks5 }

class ProxyConfig {
  const ProxyConfig({
    required this.type,
    required this.host,
    required this.port,
    this.username,
    this.password,
    this.rawType,
  });

  factory ProxyConfig.fromJson(Map<String, dynamic> json) {
    final rawType = json['type']?.toString();
    return ProxyConfig(
      // 不认识的类型保持 null，连接时拒绝。以前默认当成 HTTP，
      // 会把 socks4、大小写写错的 SOCKS5 之类静默改走 HTTP CONNECT（RTE02）。
      type:
          ProxyType.values.where((value) => value.name == rawType).firstOrNull,
      rawType: rawType,
      host: json['host']?.toString() ?? '',
      // 端口不是数字（比如同步来的 "1080" 字符串）时记 0，由 invalidReason 在拨号前拒绝；
      // 以前 `as num?` 直接抛 TypeError，报错看不懂。
      port: switch (json['port']) {
        num value => value.toInt(),
        _ => 0,
      },
      username: json['username']?.toString(),
      password: json['password']?.toString(),
    );
  }

  /// null 表示数据里的类型本 App 不认识，见 [rawType]。
  final ProxyType? type;

  /// 数据里的原始类型字符串，保存时原样写回，不把未知类型改写成 http。
  final String? rawType;
  final String host;
  final int port;
  final String? username;
  final String? password;

  /// 配置能否用于拨号；不能用时返回给用户看的原因。
  ///
  /// 选了代理就必须经代理，配置无效只能报错，不能当作「没配代理」去直连。
  String? get invalidReason {
    if (type == null) {
      return rawType == null ? '代理类型未填写' : '不支持的代理类型：$rawType';
    }
    if (host.trim().isEmpty) return '代理地址为空';
    if (port < 1 || port > 65535) return '代理端口无效：$port';
    return null;
  }

  Map<String, dynamic> toJson() => {
        'type': type?.name ?? rawType,
        'host': host,
        'port': port,
        if (username?.isNotEmpty == true) 'username': username,
        if (password?.isNotEmpty == true) 'password': password,
      };
}

class ProxyProfile {
  ProxyProfile(Map<String, dynamic> value)
      : data = Map<String, dynamic>.from(value);

  final Map<String, dynamic> data;
  String get id => data['id']?.toString() ?? '';
  String get label => data['label']?.toString() ?? 'Proxy';
  ProxyConfig? get config {
    final value = data['config'];
    return value is Map
        ? ProxyConfig.fromJson(Map<String, dynamic>.from(value))
        : null;
  }

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(data);
}

/// A lossless view over Netcatty's desktop Host JSON model.
///
/// Unknown desktop/plugin fields remain in [data] and survive every save/sync.
class HostProfile {
  HostProfile(Map<String, dynamic> value)
      : data = Map<String, dynamic>.from(value);

  factory HostProfile.create({
    required String id,
    required String label,
    required String hostname,
    required String username,
    int port = 22,
    HostProtocol protocol = HostProtocol.ssh,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return HostProfile({
      'id': id,
      'label': label,
      'hostname': hostname,
      'username': username,
      'port': port,
      'protocol': protocol.name,
      'tags': <String>[],
      'os': 'linux',
      'createdAt': now,
      'authMethod': 'auto',
      'savePassword': true,
    });
  }

  final Map<String, dynamic> data;

  String get id => data['id']?.toString() ?? '';
  String get label => data['label']?.toString() ?? hostname;
  String get hostname => data['hostname']?.toString() ?? '';
  String get username => data['username']?.toString() ?? '';
  int get port => (data['port'] as num?)?.toInt() ?? 22;
  String? get group => data['group']?.toString();
  String? get password => data['password']?.toString();
  String? get identityFileId => data['identityFileId']?.toString();
  HostAuthMethod get authMethod => HostAuthMethod.values.firstWhere(
        (value) => value.name == data['authMethod'],
        orElse: () => HostAuthMethod.auto,
      );
  List<String> get hostChainIds {
    final chain = data['hostChain'];
    if (chain is! Map) return const [];
    return (chain['hostIds'] as List? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  String? get proxyProfileId => data['proxyProfileId']?.toString();
  ProxyConfig? get proxyConfig {
    final value = data['proxyConfig'];
    return value is Map
        ? ProxyConfig.fromJson(Map<String, dynamic>.from(value))
        : null;
  }

  String? get startupCommand => data['startupCommand']?.toString();
  String get distro => normalizeDistroId(
        data['distro']?.toString() ??
            (data['systemInfo'] is Map
                ? (data['systemInfo'] as Map)['distro']?.toString()
                : null) ??
            data['os']?.toString() ??
            'linux',
      );
  ServerSystemInfo? get systemInfo {
    final value = data['systemInfo'];
    return value is Map
        ? ServerSystemInfo.fromJson(Map<String, dynamic>.from(value))
        : null;
  }

  bool get pinned => data['pinned'] == true;
  int get lastConnectedAt => (data['lastConnectedAt'] as num?)?.toInt() ?? 0;
  List<String> get tags => (data['tags'] as List? ?? const [])
      .map((value) => value.toString())
      .toList(growable: false);

  /// Missing legacy protocol means SSH. An explicit unrecognized value never
  /// grants SSH capabilities; the original value stays in [data] unchanged.
  HostProtocol get protocol {
    final raw = data['protocol'];
    if (raw == null) return HostProtocol.ssh;
    return HostProtocol.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => HostProtocol.unknown,
    );
  }

  HostProfile copyWith({
    String? label,
    String? hostname,
    String? username,
    int? port,
    String? group,
    String? password,
    String? identityFileId,
    HostAuthMethod? authMethod,
    List<String>? hostChainIds,
    String? proxyProfileId,
    ProxyConfig? proxyConfig,
    List<String>? tags,
    HostProtocol? protocol,
    bool? pinned,
    int? lastConnectedAt,
  }) {
    final next = Map<String, dynamic>.from(data);
    void set(String key, Object? value) {
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
    }

    if (label != null) set('label', label);
    if (hostname != null) set('hostname', hostname);
    if (username != null) set('username', username);
    if (port != null) set('port', port);
    if (group != null) set('group', group.isEmpty ? null : group);
    if (password != null) set('password', password.isEmpty ? null : password);
    if (identityFileId != null) {
      set('identityFileId', identityFileId.isEmpty ? null : identityFileId);
    }
    if (authMethod != null) set('authMethod', authMethod.name);
    if (hostChainIds != null) {
      set('hostChain', hostChainIds.isEmpty ? null : {'hostIds': hostChainIds});
    }
    if (proxyProfileId != null) {
      set('proxyProfileId', proxyProfileId.isEmpty ? null : proxyProfileId);
    }
    if (proxyConfig != null) set('proxyConfig', proxyConfig.toJson());
    if (tags != null) set('tags', tags);
    if (protocol != null) set('protocol', protocol.name);
    if (pinned != null) set('pinned', pinned);
    if (lastConnectedAt != null) set('lastConnectedAt', lastConnectedAt);
    return HostProfile(next);
  }

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(data);

  /// 只给调试看：id、名称、协议。以前是整份 JSON，主机对象一旦被拼进报错、日志、
  /// 崩溃报告，密码和代理口令就以明文跟着出去（REG03）。要完整数据用 [toJson]。
  @override
  String toString() =>
      'HostProfile(id: $id, label: ${data['label'] ?? ''}, ${protocol.name})';
}

class SshKeyProfile {
  SshKeyProfile(Map<String, dynamic> value)
      : data = Map<String, dynamic>.from(value);

  final Map<String, dynamic> data;
  String get id => data['id']?.toString() ?? '';
  String get label => data['label']?.toString() ?? 'SSH key';
  String get privateKey => data['privateKey']?.toString() ?? '';
  String? get passphrase => data['passphrase']?.toString();
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(data);
}

class CommandSnippet {
  CommandSnippet(Map<String, dynamic> value)
      : data = Map<String, dynamic>.from(value);

  final Map<String, dynamic> data;
  String get id => data['id']?.toString() ?? '';
  String get label => data['label']?.toString() ?? 'Snippet';
  String get command => data['command']?.toString() ?? '';
  bool get autoRun => data['noAutoRun'] != true;
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(data);
}
