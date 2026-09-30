import 'dart:convert';

import '../domain/models/host.dart';
import '../domain/models/vault.dart';
import '../domain/vault_secrets.dart';
import 'host_trust.dart';

/// 导入保险库文件：先算清楚会发生什么，让用户确认，再按用户选的方式写入。
///
/// 以前导入直接用文件整个替换本机保险库、不问一句：文件里没有的主机、私钥、代理配置
/// 连同它们在安全存储里的密码和私钥一起被删，而导出文件本来就不带凭据，删了就找不回来。
/// 现在默认「合并」：文件里有的按 ID 新增或更新，本机独有的留着；「替换」要用户在确认框里明确选。

enum VaultImportMode {
  /// 文件里有的新增或更新，本机独有的保留。
  merge,

  /// 保险库变成文件的内容，本机独有的条目连同凭据删除。
  replace,
}

/// 按 ID 对应的条目集合。顶层的四类之外，桌面端的这几类在移动端存在 extras 里，也要合并，
/// 否则合并导入会把文件里的笔记、端口转发规则等整个丢掉，或把本机的冲掉。
const _entityCollections = <String>[
  'hosts',
  'keys',
  'proxyProfiles',
  'snippets',
  'identities',
  'notes',
  'portForwardingRules',
  'groupConfigs',
];

const _stringCollections = <String>[
  'customGroups',
  'snippetPackages',
  'noteGroups',
];

class VaultImportPlan {
  VaultImportPlan._({
    required this.incoming,
    required this.local,
    required this.addedHosts,
    required this.updatedHosts,
    required this.localOnlyHosts,
    required this.localOnlyKeys,
    required this.localOnlyProxies,
    required this.localOnlySnippets,
    required this.credentialsNotCarried,
    required this.keysWithoutMaterial,
  });

  final VaultData incoming;
  final VaultData local;

  /// 文件里有、本机没有的主机。
  final List<HostProfile> addedHosts;

  /// 文件和本机都有（按 ID）的主机，导入后配置以文件为准。
  final List<HostProfile> updatedHosts;

  /// 本机有、文件里没有的条目。合并时保留，替换时连同凭据删除。
  final List<HostProfile> localOnlyHosts;
  final List<SshKeyProfile> localOnlyKeys;
  final List<ProxyProfile> localOnlyProxies;
  final List<CommandSnippet> localOnlySnippets;

  /// 两边都有、但文件里改了地址 / 端口 / 用户名（或代理的这几项）的：本机存的密码不会沿用。
  /// 否则一个改了地址的文件就能让你的密码被发到另一台机器（见 [keepLocalSecrets]）。
  /// 显示名，主机和代理配置混在一起，只用于告诉用户「这些要重新填」。
  final List<String> credentialsNotCarried;

  /// 导入后只有名字、没有私钥内容的私钥（本 App 导出的文件不带私钥；换手机导入时全是这种）。
  final List<SshKeyProfile> keysWithoutMaterial;

  /// 本机没有任何独有条目时，合并和替换结果一样，确认框只给一个「导入」。
  bool get hasLocalOnly =>
      localOnlyHosts.isNotEmpty ||
      localOnlyKeys.isNotEmpty ||
      localOnlyProxies.isNotEmpty ||
      localOnlySnippets.isNotEmpty;

  /// 用来发现「确认框开着的时候本机保险库变了」：变了就不能按用户看到的那份结论去写。
  String get signature => jsonEncode([
        for (final value in localOnlyHosts) value.id,
        '|',
        for (final value in localOnlyKeys) value.id,
        '|',
        for (final value in localOnlyProxies) value.id,
        '|',
        for (final value in localOnlySnippets) value.id,
        '|',
        ...credentialsNotCarried,
      ]);

  /// 按 [mode] 算出要保存的保险库，本机凭据按 [keepLocalSecrets] 的规则沿用。
  VaultData result(VaultImportMode mode) => keepLocalSecrets(
        mode == VaultImportMode.merge ? _merge(incoming, local) : incoming,
        local,
      );
}

VaultImportPlan planVaultImport(VaultData incoming, VaultData local) {
  final localHostIds = {for (final value in local.hosts) value.id};
  final incomingHostIds = {for (final value in incoming.hosts) value.id};
  final incomingKeyIds = {for (final value in incoming.keys) value.id};
  final incomingProxyIds = {
    for (final value in incoming.proxyProfiles) value.id
  };
  final incomingSnippetIds = {for (final value in incoming.snippets) value.id};

  // 只看文件里有的那部分：合并时本机独有的条目原样保留，谈不上「沿用不了」。
  final carried = keepLocalSecrets(incoming, local);
  final carriedHosts = {for (final value in carried.hosts) value.id: value};
  final carriedProxies = {
    for (final value in carried.proxyProfiles) value.id: value,
  };
  final notCarried = <String>[];
  for (final mine in local.hosts) {
    final after = carriedHosts[mine.id];
    if (after == null) continue;
    final lostPassword =
        _has(mine.data['password']) && !_has(after.data['password']);
    final lostTelnet = _has(mine.data['telnetPassword']) &&
        !_has(after.data['telnetPassword']);
    final lostProxy = _has(_proxyPassword(mine.data['proxyConfig'])) &&
        !_has(_proxyPassword(after.data['proxyConfig']));
    if (lostPassword || lostTelnet || lostProxy) notCarried.add(mine.label);
  }
  for (final mine in local.proxyProfiles) {
    final after = carriedProxies[mine.id];
    if (after == null) continue;
    if (_has(_proxyPassword(mine.data['config'])) &&
        !_has(_proxyPassword(after.data['config']))) {
      notCarried.add(mine.label);
    }
  }

  return VaultImportPlan._(
    incoming: incoming,
    local: local,
    addedHosts: [
      for (final value in incoming.hosts)
        if (!localHostIds.contains(value.id)) value,
    ],
    updatedHosts: [
      for (final value in incoming.hosts)
        if (localHostIds.contains(value.id)) value,
    ],
    localOnlyHosts: [
      for (final value in local.hosts)
        if (!incomingHostIds.contains(value.id)) value,
    ],
    localOnlyKeys: [
      for (final value in local.keys)
        if (!incomingKeyIds.contains(value.id)) value,
    ],
    localOnlyProxies: [
      for (final value in local.proxyProfiles)
        if (!incomingProxyIds.contains(value.id)) value,
    ],
    localOnlySnippets: [
      for (final value in local.snippets)
        if (!incomingSnippetIds.contains(value.id)) value,
    ],
    credentialsNotCarried: notCarried,
    keysWithoutMaterial: [
      for (final value in carried.keys)
        if (value.privateKey.isEmpty) value,
    ],
  );
}

/// 文件优先：两边都有的条目用文件的；本机独有的接在后面。
///
/// extras 里其他不认识的字段同理：文件有的用文件的，文件没有的保留本机的。
/// 受信指纹例外：同一台主机两边记录不一样时**保留本机的**——本机那条是在这台手机上核对过的，
/// 不能被一个文件悄悄改掉（指纹变了必须阻断，见 host_trust.dart）。
VaultData _merge(VaultData incoming, VaultData local) {
  final result = _copy(incoming.toJson());
  final mine = _copy(local.toJson());
  for (final key in mine.keys) {
    if (_entityCollections.contains(key) ||
        _stringCollections.contains(key) ||
        key == 'knownHosts') {
      continue;
    }
    result.putIfAbsent(key, () => mine[key]);
  }
  for (final key in _entityCollections) {
    if (!result.containsKey(key) && !mine.containsKey(key)) continue;
    result[key] = _mergeEntities(_maps(result[key]), _maps(mine[key]));
  }
  for (final key in _stringCollections) {
    if (!result.containsKey(key) && !mine.containsKey(key)) continue;
    result[key] = <String>{
      ..._strings(result[key]),
      ..._strings(mine[key]),
    }.toList();
  }
  if (result.containsKey('knownHosts') || mine.containsKey('knownHosts')) {
    result['knownHosts'] = _mergeKnownHosts(
        _maps(result['knownHosts']), _maps(mine['knownHosts']));
  }
  return VaultData.fromJson(result);
}

List<Map<String, dynamic>> _mergeEntities(
  List<Map<String, dynamic>> theirs,
  List<Map<String, dynamic>> ours,
) {
  final ids = {
    for (final value in theirs)
      if (_id(value).isNotEmpty) _id(value),
  };
  // 没有 ID 的条目对不上号：本机的只在文件里没有一模一样的一份时才保留，免得重复。
  final plain = {for (final value in theirs) jsonEncode(value)};
  return [
    ...theirs,
    for (final value in ours)
      if (_id(value).isEmpty
          ? !plain.contains(jsonEncode(value))
          : !ids.contains(_id(value)))
        value,
  ];
}

List<Map<String, dynamic>> _mergeKnownHosts(
  List<Map<String, dynamic>> theirs,
  List<Map<String, dynamic>> ours,
) {
  String key(Map<String, dynamic> entry) =>
      '${trustHostName('${entry['hostname'] ?? ''}')}:${(entry['port'] as num?)?.toInt() ?? 22}';
  final known = {for (final value in ours) key(value)};
  return [
    ...ours,
    for (final value in theirs)
      if (!known.contains(key(value))) value,
  ];
}

String _id(Map<String, dynamic> value) => value['id']?.toString() ?? '';

bool _has(Object? value) => (value?.toString() ?? '').isNotEmpty;

Object? _proxyPassword(Object? config) =>
    config is Map ? config['password'] : null;

List<Map<String, dynamic>> _maps(Object? value) => [
      for (final item in value is List ? value : const [])
        if (item is Map) Map<String, dynamic>.from(item),
    ];

List<String> _strings(Object? value) => [
      for (final item in value is List ? value : const []) item.toString(),
    ];

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
