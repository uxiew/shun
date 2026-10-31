import 'host_identity.dart';
import 'models/host.dart';
import 'models/vault.dart';
import 'vault_secrets.dart';

/// 「凭据」里的一个身份（R26 F25）：用户名 + 登录方式，可以被多台主机引用。
///
/// 格式跟桌面端 Netcatty 的 `Identity` 一样（`domain/models/connection.ts`），存在保险库的
/// `identities` 里：`{id, label, username, authMethod: password|key|certificate, password?, keyId?, created}`。
/// 桌面端建的身份导入、同步过来就能用，这边建的桌面端也认。不认识的字段原样留着。
///
/// 密码和主机密码一样只存安全存储（`identity.<id>.password`，见 [vaultWithoutSecrets]）。
class IdentityProfile {
  IdentityProfile(this.data);

  final Map<String, dynamic> data;

  String get id => data['id']?.toString() ?? '';
  String get label {
    final label = data['label']?.toString().trim() ?? '';
    return label.isNotEmpty ? label : username;
  }

  String get username => data['username']?.toString().trim() ?? '';
  String? get password => _nonEmpty(data['password']);
  String? get keyId => _nonEmpty(data['keyId']);

  /// 桌面端只有 password / key / certificate 三种；「密钥 + 密码」在桌面端是带了密码的 key。
  IdentityAuth get auth {
    if (data['authMethod'] == 'password') return IdentityAuth.password;
    return password == null ? IdentityAuth.key : IdentityAuth.keyAndPassword;
  }

  @override
  String toString() => 'IdentityProfile(id: $id)';
}

enum IdentityAuth {
  /// 用户名 + 密码。
  password,

  /// 用户名 + SSH 密钥（密钥自己的口令存在密钥上）。
  key,

  /// 先公钥、再密码：服务器配了 `AuthenticationMethods publickey,password` 这类两步登录。
  keyAndPassword,
}

List<IdentityProfile> vaultIdentities(VaultData vault) =>
    [for (final data in vaultIdentityMaps(vault)) IdentityProfile(data)];

/// 主机引用的身份；没引用或者引用的已经删了是 null。
IdentityProfile? hostIdentity(
  HostProfile host,
  List<Map<String, dynamic>> identities,
) {
  final id = host.data['identityId']?.toString() ?? '';
  if (id.isEmpty) return null;
  for (final data in identities) {
    if (data['id']?.toString() == id) return IdentityProfile(data);
  }
  return null;
}

/// 把主机引用的身份展开到这份主机配置上（原地改 [data]，调用方传的是路线快照的副本）。
///
/// 规则照桌面端 `resolveHostAuth`（`domain/sshAuth.ts`）：用户名、登录方式、密钥、密码都是身份里的优先，
/// 身份没填的用主机自己的。同一台机器在桌面端和手机上就是同一个身份登录。
/// 引用的身份已经删了：也和桌面端一样退回主机自己的配置。
///
/// 「密钥 + 密码」映射成「自动」：SSH 库按 公钥 → 密码 → 键盘交互 的顺序试，服务器说公钥过了、
/// 还要密码（partial success）时接着发密码。设成「只用密钥」的话不会发密码，第二步就过不去。
void applyHostIdentity(
  Map<String, dynamic> data,
  List<Map<String, dynamic>> identities,
) {
  final identity = hostIdentity(HostProfile(data), identities);
  if (identity == null) return;
  if (identity.username.isNotEmpty) data['username'] = identity.username;
  final password = identity.password;
  switch (identity.auth) {
    case IdentityAuth.password:
      data['authMethod'] = HostAuthMethod.password.name;
      data.remove('identityFileId');
      if (password != null) data['password'] = password;
    case IdentityAuth.key:
      data['authMethod'] = HostAuthMethod.key.name;
      if (identity.keyId != null) data['identityFileId'] = identity.keyId;
    case IdentityAuth.keyAndPassword:
      data['authMethod'] = HostAuthMethod.auto.name;
      if (identity.keyId != null) data['identityFileId'] = identity.keyId;
      data['password'] = password;
  }
}

/// sudo 键（R66）要发的密码：[tabHost] 这个标签对应的那台主机现在存的密码，身份展开后。
///
/// 按 id 回保险库查，不用标签上那份：那份可能是临时拷贝（tmux、AI 工具），后台满 10 分钟凭据还会被清掉。
/// 只查这一台。经跳板的标签 [tabHost] 是最后那台目标主机，跳板的密码不会被拿来发。
/// 没存、主机删了、是没进保险库的临时连接，都返回 null。
String? storedHostPassword(
  HostProfile tabHost, {
  required List<HostProfile> hosts,
  required List<Map<String, dynamic>> identities,
}) {
  final id = sourceHostIdOf(tabHost);
  for (final host in hosts) {
    if (host.id != id) continue;
    final data = Map<String, dynamic>.of(host.data);
    applyHostIdentity(data, identities);
    final password = data['password']?.toString() ?? '';
    return password.isEmpty ? null : password;
  }
  return null;
}

/// 登录方式一句话：凭据列表、主机编辑器的选择框里用。不带密码内容。
String identityAuthText(
  IdentityProfile identity,
  Map<String, String> keyLabels,
) {
  final key =
      identity.keyId == null ? null : keyLabels[identity.keyId] ?? '（已删除的密钥）';
  return switch (identity.auth) {
    IdentityAuth.password => identity.password == null ? '密码（连接时问）' : '密码',
    IdentityAuth.key => 'SSH 密钥“${key ?? ''}”',
    IdentityAuth.keyAndPassword => 'SSH 密钥“${key ?? ''}” + 密码',
  };
}

String? _nonEmpty(Object? value) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? null : text;
}
