import 'dart:convert';

import 'connection_route.dart';
import 'models/host.dart';
import 'models/vault.dart';

/// Editing a profile must use the same endpoint rules as connecting through it.
/// Unknown desktop fields survive edits; no host references are rewritten.
void validateProxyProfile(ProxyProfile profile) {
  if (profile.id.isEmpty || profile.label.trim().isEmpty) {
    throw const RouteConfigException('代理名称不能为空');
  }
  final target = HostProfile.create(
      id: 'proxy-validation',
      label: 'proxy-validation',
      hostname: 'validation.invalid',
      username: 'validation');
  target.data['proxyProfileId'] = profile.id;
  resolveRoutePlan(target, hosts: const [], proxyProfiles: [profile]);
}

bool sameProxyProfile(ProxyProfile? a, ProxyProfile? b) =>
    _same(a?.data, b?.data);

class ProxyProfileChanged implements Exception {
  const ProxyProfileChanged();
  @override
  String toString() => '代理或引用主机已变化，请重新打开后再操作。';
}

/// A deletion confirmation is tied to both the profile and the references shown.
class ProxyDeletion {
  ProxyDeletion(VaultData vault, ProxyProfile source)
      : profile = ProxyProfile(Map<String, dynamic>.from(
            jsonDecode(jsonEncode(source.data)) as Map)),
        hosts = List.unmodifiable(vault.hosts
            .where((host) => host.proxyProfileId == source.id)
            .map((host) => HostProfile({
                  'id': host.id,
                  'label': host.label,
                  'hostname': host.hostname,
                  'port': host.port,
                  'username': host.username,
                })));

  final ProxyProfile profile;
  final List<HostProfile> hosts;

  bool matches(VaultData vault) {
    final current = vault.proxyProfiles
        .where((value) => value.id == profile.id)
        .firstOrNull;
    if (!sameProxyProfile(current, profile)) return false;
    Map<String, Object> references(Iterable<HostProfile> values) => {
          for (final h in values)
            h.id: [h.label, h.hostname, h.port, h.username]
        };
    return _same(
        references(hosts),
        references(
            vault.hosts.where((host) => host.proxyProfileId == profile.id)));
  }
}

// JSON-shaped desktop data; map key order is not significant.
bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _same(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _same(a[i], b[i]));
  }
  return a == b;
}
