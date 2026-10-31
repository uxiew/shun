import 'dart:convert';

import 'models/host.dart';
import 'models/vault.dart';

/// 保险库里哪些是凭据、怎么去掉、导入时怎么沿用——本地存储和导出共用这一份规则。
///
/// 凭据只进系统安全存储，不进普通文件（plan/v3/AGENTS.md：凭据不进日志、普通导出、备份）。

/// 一台主机配置里的凭据：登录密码、Telnet 密码、主机自带代理的口令、桌面端的 TOTP 种子
/// （`totp.uri`，整个 otpauth 链接就是两步验证的密钥，本 App 不用但要原样往返）。原地去掉，其余字段不动。
///
/// 存储和导出（[vaultWithoutSecrets]）、断线恢复用的路线副本、临时标签的主机拷贝都按这一份去。
/// 以前三处各写各的，临时标签那处只删了 password，过了租期代理口令还留在内存里（R28）。
/// 加新的凭据字段时只改这里。
/// 代理配置换成一份新 Map 再删：原来那份可能还被保险库里的主机引用着。
void removeHostSecrets(Map<String, dynamic> data) {
  data
    ..remove('password')
    ..remove('telnetPassword');
  final proxy = data['proxyConfig'];
  if (proxy is Map) {
    data['proxyConfig'] = Map<String, dynamic>.from(proxy)..remove('password');
  }
  final totp = data['totp'];
  if (totp is Map) {
    data['totp'] = Map<String, dynamic>.from(totp)..remove('uri');
  }
}

/// 桌面端的「身份」（用户名 + 密码或密钥，存在 `extras['identities']`）。返回的就是保险库里那几个 Map，
/// 改了就是改保险库。不是 Map 的条目跳过（原样留着）。
List<Map<String, dynamic>> vaultIdentityMaps(VaultData vault) {
  final list = vault.extras['identities'];
  if (list is! List) return const [];
  final maps = <Map<String, dynamic>>[];
  for (var i = 0; i < list.length; i++) {
    final item = list[i];
    if (item is Map<String, dynamic>) {
      maps.add(item);
    } else if (item is Map) {
      list[i] = Map<String, dynamic>.from(item);
      maps.add(list[i] as Map<String, dynamic>);
    }
  }
  return maps;
}

/// 深拷贝后去掉全部凭据：主机凭据（[removeHostSecrets]）、私钥与私钥口令、代理配置的口令、
/// 身份里的密码。其余字段（包括不认识的扩展字段）原样保留。
///
/// 身份密码和 TOTP 种子是 R26 F25 才补上的：以前只认本 App 自己的字段，导入桌面端文件后这两样会明文进
/// 普通存储和普通导出。
VaultData vaultWithoutSecrets(VaultData vault) {
  final copy = _deepCopy(vault);
  for (final host in copy.hosts) {
    removeHostSecrets(host.data);
  }
  for (final identity in vaultIdentityMaps(copy)) {
    identity.remove('password');
  }
  for (final key in copy.keys) {
    key.data['privateKey'] = '';
    key.data.remove('passphrase');
  }
  for (final profile in copy.proxyProfiles) {
    if (profile.data['config'] is Map) {
      profile.data['config'] =
          Map<String, dynamic>.from(profile.data['config'] as Map)
            ..remove('password');
    }
  }
  return copy;
}

/// 导入一个不带凭据的文件（比如本 App 导出的）时，沿用本机同一条目已有的凭据。
///
/// 只在「凭据要发往的地方」完全没变时沿用：主机按 协议 + 地址 + 端口 + 用户名，代理按 类型 + 地址 + 端口 + 用户名。
/// 否则一个改了地址的导入文件，就能让你保存的密码被发给另一台机器。文件里自带凭据的条目以文件为准。
/// 不这样做的话，导入会把本机安全存储里的密码、私钥一并删掉（保存时空值等于删除）。
VaultData keepLocalSecrets(VaultData incoming, VaultData local) {
  final result = _deepCopy(incoming);
  final localHosts = {for (final host in local.hosts) host.id: host};
  for (final host in result.hosts) {
    final mine = localHosts[host.id];
    if (mine == null) continue;
    if (_sameLoginTarget(host, mine)) {
      _fill(host.data, 'password', mine.data['password']);
      _fill(host.data, 'telnetPassword', mine.data['telnetPassword']);
      final theirTotp = host.data['totp'];
      final ourTotp = mine.data['totp'];
      if (theirTotp is Map && ourTotp is Map) {
        host.data['totp'] = Map<String, dynamic>.from(theirTotp);
        _fill(host.data['totp'] as Map<String, dynamic>, 'uri', ourTotp['uri']);
      }
    }
    final theirs = host.data['proxyConfig'];
    final ours = mine.data['proxyConfig'];
    if (theirs is Map && ours is Map && _sameProxy(theirs, ours)) {
      host.data['proxyConfig'] = Map<String, dynamic>.from(theirs);
      _fill(host.data['proxyConfig'] as Map<String, dynamic>, 'password',
          ours['password']);
    }
  }
  final localKeys = {for (final key in local.keys) key.id: key};
  for (final key in result.keys) {
    final mine = localKeys[key.id];
    if (mine == null || key.privateKey.isNotEmpty) continue;
    _fill(key.data, 'privateKey', mine.data['privateKey']);
    _fill(key.data, 'passphrase', mine.data['passphrase']);
  }
  // 身份不绑地址，密码发往哪里由引用它的主机决定；这里只要求同一个身份、用户名和登录方式都没变。
  final localIdentities = {
    for (final identity in vaultIdentityMaps(local))
      '${identity['id']}': identity
  };
  for (final identity in vaultIdentityMaps(result)) {
    final mine = localIdentities['${identity['id']}'];
    if (mine == null ||
        '${mine['username'] ?? ''}' != '${identity['username'] ?? ''}' ||
        '${mine['authMethod'] ?? ''}' != '${identity['authMethod'] ?? ''}') {
      continue;
    }
    _fill(identity, 'password', mine['password']);
  }
  final localProxies = {for (final p in local.proxyProfiles) p.id: p};
  for (final profile in result.proxyProfiles) {
    final theirs = profile.data['config'];
    final ours = localProxies[profile.id]?.data['config'];
    if (theirs is Map && ours is Map && _sameProxy(theirs, ours)) {
      profile.data['config'] = Map<String, dynamic>.from(theirs);
      _fill(profile.data['config'] as Map<String, dynamic>, 'password',
          ours['password']);
    }
  }
  return result;
}

VaultData _deepCopy(VaultData vault) => VaultData.fromJson(
      jsonDecode(jsonEncode(vault.toJson())) as Map<String, dynamic>,
    );

void _fill(Map<String, dynamic> into, String field, Object? value) {
  final current = into[field]?.toString() ?? '';
  final replacement = value?.toString() ?? '';
  if (current.isEmpty && replacement.isNotEmpty) into[field] = replacement;
}

bool _sameLoginTarget(HostProfile a, HostProfile b) =>
    a.protocol == b.protocol &&
    a.hostname.trim().toLowerCase() == b.hostname.trim().toLowerCase() &&
    a.port == b.port &&
    a.username == b.username;

bool _sameProxy(Map a, Map b) =>
    '${a['type']}' == '${b['type']}' &&
    '${a['host']}'.trim().toLowerCase() ==
        '${b['host']}'.trim().toLowerCase() &&
    '${a['port']}' == '${b['port']}' &&
    '${a['username'] ?? ''}' == '${b['username'] ?? ''}';
