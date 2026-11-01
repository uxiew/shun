import '../domain/connection_route.dart' show proxyIdentityKey;
import '../domain/models/host.dart';
import '../domain/models/vault.dart';
import '../domain/tailscale_ssh.dart';
import '../domain/credential_identity.dart';
import '../domain/vault_secrets.dart';

/// 路线要用到的凭据解不开，连接在拨号前被拒绝。[message] 说明是哪台机器的哪种凭据。
class CredentialUnavailableException implements Exception {
  const CredentialUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 连 [target] 实际要用到的凭据里，有没有解不开的（[unreadable] 是安全存储里解不开的键，
/// 见 VaultRepository.unreadableSecrets）。有就返回给人看的一句话，都能用时返回 null。
///
/// 只看这条路线真会用到的：目标和各跳板的登录密码或私钥、Telnet 密码、目标上的代理口令。
/// 解不开的凭据以前会让整个保险库加载失败；现在只拦用到它的连接，而且不拿空密码去试——
/// 那等于悄悄降级成「没有保存密码」，用户只会看到一句「登录被拒绝」（SEC06）。
String? unreadableCredentialProblem(
  HostProfile target,
  VaultData vault,
  Set<String> unreadable,
) {
  if (unreadable.isEmpty) return null;
  final byId = {for (final host in vault.hosts) host.id: host};
  final hops = [
    for (final id in target.hostChainIds)
      if (byId[id] != null) byId[id]!,
    target,
  ];
  final identities = vaultIdentityMaps(vault);
  for (final stored in hops) {
    final isTarget = identical(stored, target);
    final problems = <String>{};
    // 主机引用了「凭据」里的身份：用户名、登录方式、私钥按身份展开后再判断（R26 F25）。
    final identity = hostIdentity(stored, identities);
    final host = HostProfile(Map<String, dynamic>.from(stored.data));
    applyHostIdentity(host.data, identities);
    // Tailscale SSH 不发登录密码和私钥，它们解不开也不影响这一跳。
    final standard = sshLoginModeOf(host) == SshLoginMode.standard;
    if (standard &&
        identity != null &&
        unreadable.contains('identity.${identity.id}.password')) {
      // 存过密码的身份只会是「密码」或「密钥 + 密码」，两种都要用它；解不开时身份看着像
      // 「只用密钥」，不拦的话第二步登录过不去，只得到一句「登录被拒绝」。
      problems.add('凭据“${identity.label}”的密码');
    } else if (standard &&
        // 身份自带密码时用身份的，主机自己那份用不上；身份没存密码才退回主机的（同桌面端）。
        identity?.password == null &&
        host.authMethod != HostAuthMethod.key &&
        unreadable.contains('host.${host.id}.password')) {
      problems.add('登录密码');
    }
    if (host.protocol == HostProtocol.telnet &&
        unreadable.contains('host.${host.id}.telnetPassword')) {
      problems.add('Telnet 密码');
    }
    final keyId = host.identityFileId;
    if (standard &&
        keyId != null &&
        host.authMethod != HostAuthMethod.password &&
        (unreadable.contains('key.$keyId.private') ||
            unreadable.contains('key.$keyId.passphrase'))) {
      problems.add('私钥');
    }
    if (isTarget) {
      final proxyId = host.proxyProfileId;
      final proxyCredential = vault.proxyProfiles
          .where((profile) => profile.id == proxyId)
          .firstOrNull
          ?.data[proxyIdentityKey];
      if ((host.data['proxyConfig'] is Map &&
              unreadable.contains('host.${host.id}.proxyPassword')) ||
          (proxyId != null && unreadable.contains('proxy.$proxyId.password')) ||
          (proxyCredential != null &&
              unreadable.contains('identity.$proxyCredential.password'))) {
        problems.add('代理口令');
      }
    }
    if (problems.isNotEmpty) {
      final who = isTarget ? '目标“${stored.label}”' : '跳板机“${stored.label}”';
      final what = problems.join('、');
      return '$who：$what无法解密'
          '（设备密钥可能已失效，或数据被改动过）。请在编辑器里重新填写后再连接。';
    }
  }
  return null;
}
