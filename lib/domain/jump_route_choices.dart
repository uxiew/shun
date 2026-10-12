part of 'connection_route.dart';

/// Additive, namespaced confirmation inside the existing desktop hostChain.
/// hostIds and proxy fields remain the complete, flattened execution route.
const jumpRouteConfirmationKey = 'shunRouteConfirmation';
const _choiceChanged = '跳板路线确认已失效，请重新确认。';

/// A preview of an explicit edit, never consulted to discover routes at dial time.
/// The revision is memory-only and may contain credentials; never serialize/log it.
class JumpRouteProposal {
  JumpRouteProposal._(this._direct, this._proxy, this.labels,
      this.proxyDescription, this._revision);
  final HostProfile _direct;
  final HostProfile? _proxy;
  final List<String> labels;
  final String? proxyDescription;
  final String _revision;
  bool get hasFirstProxy => _proxy != null;
  HostProfile select({required bool useFirstProxy}) {
    final selected = useFirstProxy ? _proxy : _direct;
    if (selected == null) throw const RouteConfigException(_choiceChanged);
    return HostProfile(_deepCopy(selected.data));
  }

  bool sameRevision(JumpRouteProposal other) => _revision == other._revision;
}

/// Expand recursively only in response to an editor action. Limit work as well
/// as final hop count; missing, cyclic, duplicate or malformed paths cannot be
/// partially applied. Already listed ancestors are merged only at a shared seam.
JumpRouteProposal proposeJumpRouteChoice(HostProfile target,
    {required List<HostProfile> hosts,
    required List<ProxyProfile> proxyProfiles}) {
  final byId = {for (final host in hosts) host.id: host};
  final requested = _jumpIds(target, '路线');
  if (requested.isEmpty) throw const RouteConfigException('请先添加跳板机。');
  final ids = _expandJumpIds(requested, byId, {target.id});
  final first = byId[ids.first]!;
  final hasProxy = _hasProxySetting(first);
  final inheritedEntry =
      hasProxy ? _entry(first, '首跳', proxyProfiles) as ProxyEntry : null;
  final sources = _choiceSources(ids, byId);
  HostProfile candidate(bool useProxy) {
    final data = _deepCopy(target.data);
    if (hasProxy) {
      data.remove('proxyProfileId');
      data.remove('proxyConfig');
      if (useProxy) {
        if (first.data['proxyProfileId'] != null) {
          data['proxyProfileId'] = first.data['proxyProfileId'];
        }
        if (first.data['proxyConfig'] != null) {
          data['proxyConfig'] = _copy(first.data['proxyConfig']);
        }
      }
    }
    final oldChain = data['hostChain'];
    data['hostChain'] = {
      if (oldChain is Map) ...Map<String, dynamic>.from(oldChain),
      'hostIds': ids,
      jumpRouteConfirmationKey: {
        'version': 1,
        'hostIds': ids,
        'sources': sources,
        'entry': _proxyShape(HostProfile(data)),
        'firstProxy': hasProxy ? (useProxy ? 'proxy' : 'direct') : null,
      },
    };
    final host = HostProfile(data);
    resolveRoutePlan(host, hosts: hosts, proxyProfiles: proxyProfiles);
    return host;
  }

  final direct = candidate(false);
  return JumpRouteProposal._(
      direct,
      hasProxy ? candidate(true) : null,
      List.unmodifiable(ids.map((id) => byId[id]!.label)),
      inheritedEntry == null
          ? null
          : '${inheritedEntry.type.name.toUpperCase()} ${inheritedEntry.endpoint.authority}',
      _canonical([
        target.data,
        for (final id in ids) byId[id]!.data,
        for (final profile in proxyProfiles) profile.data,
      ]));
}

List<String> _expandJumpIds(
    List<String> ids, Map<String, HostProfile> hosts, Set<String> ancestors) {
  if (ids.length > maxJumpHosts || ancestors.length > maxJumpHosts) {
    throw const RouteConfigException('展开后跳板机超过 3 台。');
  }
  if (ids.toSet().length != ids.length) {
    throw const RouteConfigException('跳板机链路存在循环');
  }
  final result = <String>[];
  for (final id in ids) {
    final host = hosts[id];
    if (host == null) throw RouteConfigException('找不到跳板机：$id');
    if (ancestors.contains(id)) {
      throw const RouteConfigException('跳板机链路存在循环');
    }
    if (host.protocol != HostProtocol.ssh) {
      throw RouteConfigException('跳板机必须使用 SSH：${host.label}');
    }
    final nested = _jumpIds(host, '跳板机');
    final path = [
      if (nested.isNotEmpty)
        ..._expandJumpIds(nested, hosts, {...ancestors, id}),
      id,
    ];
    var overlap = 0;
    for (var n = 1; n <= result.length && n < path.length; n++) {
      if (_canonical(result.sublist(result.length - n)) ==
          _canonical(path.take(n).toList())) {
        overlap = n;
      }
    }
    result.addAll(path.skip(overlap));
    if (result.toSet().length != result.length) {
      throw const RouteConfigException('跳板机链路存在循环');
    }
    if (result.length > maxJumpHosts) {
      throw const RouteConfigException('展开后跳板机超过 3 台。');
    }
  }
  return result;
}

// These snapshots contain route decisions only, never passwords or key material.
Object? _proxyShape(HostProfile host) {
  final inline = host.data['proxyConfig'];
  return {
    'profile': host.proxyProfileId,
    'inline': inline is Map
        ? {
            for (final key in ['type', 'host', 'port', 'username'])
              key: inline[key]
          }
        : inline == null
            ? null
            : 'invalid',
  };
}

Map<String, dynamic> _choiceSources(
        List<String> ids, Map<String, HostProfile> hosts) =>
    {
      for (final id in ids)
        if (hosts[id] case final host?)
          id: {
            'hostname': host.hostname,
            'port': host.data['port'] ?? 22,
            'protocol': host.protocol.name,
            'chain': _jumpIds(host, '跳板机'),
            'proxy': _proxyShape(host),
          },
    };

/// Confirmation is bound to the entire ordered chain and entry, not a blanket
/// permission to ignore routes on arbitrary hosts. Transport still consumes
/// only the target's explicit flat hostIds, never the recursive expansion.
bool _confirmedJumpRoutes(HostProfile target, List<String> ids,
    Map<String, HostProfile> hosts, List<ProxyProfile> profiles) {
  final chain = target.data['hostChain'];
  final proof = chain is Map ? chain[jumpRouteConfirmationKey] : null;
  if (proof == null) return false;
  if (proof is! Map ||
      proof['version'] != 1 ||
      ids.isEmpty ||
      ids.any((id) => !hosts.containsKey(id)) ||
      _canonical(proof['hostIds']) != _canonical(ids) ||
      _canonical(proof['sources']) != _canonical(_choiceSources(ids, hosts)) ||
      _canonical(proof['entry']) != _canonical(_proxyShape(target)) ||
      _canonical(_expandJumpIds(ids, hosts, {target.id})) != _canonical(ids)) {
    throw const RouteConfigException(_choiceChanged);
  }
  final first = hosts[ids.first]!;
  if (_hasProxySetting(first)) {
    _entry(first, '首跳', profiles);
    if (proof['firstProxy'] == 'proxy') {
      if (_canonical(_proxyShape(first)) != _canonical(_proxyShape(target))) {
        throw const RouteConfigException(_choiceChanged);
      }
    } else if (proof['firstProxy'] != 'direct' || _hasProxySetting(target)) {
      throw const RouteConfigException(_choiceChanged);
    }
  } else if (proof['firstProxy'] != null) {
    throw const RouteConfigException(_choiceChanged);
  }
  return true;
}

String _canonical(Object? value) => jsonEncode(_ordered(value));
Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) return value.map(_ordered).toList();
  return value;
}
