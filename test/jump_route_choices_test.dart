import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/presentation/widgets/connection_route_draft.dart';

HostProfile host(String id,
        {List<String>? jumps,
        Object? proxy,
        String? profile,
        Map<String, dynamic> extra = const {}}) =>
    HostProfile({
      ...HostProfile.create(
              id: id, label: id, hostname: '$id.example', username: 'ops')
          .data,
      if (jumps != null) 'hostChain': {'hostIds': jumps},
      if (proxy != null) 'proxyConfig': proxy,
      if (profile != null) 'proxyProfileId': profile,
      ...extra,
    });
const proxy = {
  'type': 'socks5',
  'host': 'proxy.example',
  'port': 1080,
  'username': 'proxy-user',
  'password': 'never-in-confirmation'
};
void main() {
  RoutePlan resolve(HostProfile target, List<HostProfile> hosts,
          [List<ProxyProfile> profiles = const []]) =>
      resolveRoutePlan(target, hosts: hosts, proxyProfiles: profiles);
  JumpRouteProposal propose(HostProfile target, List<HostProfile> hosts,
          [List<ProxyProfile> profiles = const []]) =>
      proposeJumpRouteChoice(target, hosts: hosts, proxyProfiles: profiles);

  test('forgetting credentials clears inline proxy secrets on every hop', () {
    final edge = host('edge', proxy: proxy, extra: {'password': 'ssh-secret'});
    final target = propose(host('target', jumps: ['edge']), [edge])
        .select(useFirstProxy: true);
    final plan = resolve(target, [edge]);
    final forgotten = plan.withoutSecrets();
    expect(forgotten.shape, plan.shape);
    expect((forgotten.entry as ProxyEntry).password, isNull);
    final data = jsonEncode(forgotten.hops.map((h) => h.host.data).toList());
    expect(data, isNot(contains('never-in-confirmation')));
    expect(data, isNot(contains('ssh-secret')));
    expect((plan.entry as ProxyEntry).password, 'never-in-confirmation');
  });

  test(
      'first proxy requires explicit choice; both choices survive serialization',
      () {
    final edge = host('edge', proxy: proxy);
    final target = host('target', jumps: ['edge']);
    final original = jsonEncode(edge.data);
    expect(() => resolve(target, [edge]), throwsA(isA<RouteConfigException>()));
    final proposal = propose(target, [edge]);
    for (final useProxy in [true, false]) {
      final chosen = proposal.select(useFirstProxy: useProxy);
      final roundtrip = HostProfile(jsonDecode(jsonEncode(chosen.data)));
      final plan = resolve(roundtrip, [edge]);
      expect(plan.entry is ProxyEntry, useProxy);
      expect(plan.jumps.single.host.id, 'edge');
      final confirmation = chosen.data['hostChain'][jumpRouteConfirmationKey];
      expect(
          jsonEncode(confirmation), isNot(contains('never-in-confirmation')));
    }
    expect(jsonEncode(edge.data), original);
    expect(target.proxyConfig, isNull);
  });

  test(
      'saved profile remains a shared reference; deletion blocks even direct consent',
      () {
    final edge = host('edge', profile: 'p');
    final target = host('target', jumps: ['edge']);
    ProxyProfile profile(int port) => ProxyProfile({
          'id': 'p',
          'label': 'p',
          'config': {...proxy, 'port': port}
        });
    final proposal = propose(target, [edge], [profile(1080)]);
    final chosen = proposal.select(useFirstProxy: true);
    expect(chosen.proxyProfileId, 'p');
    expect(
        (resolve(chosen, [edge], [profile(1081)]).entry as ProxyEntry)
            .endpoint
            .port,
        1081);
    for (final useProxy in [true, false]) {
      expect(() => resolve(proposal.select(useFirstProxy: useProxy), [edge]),
          throwsA(isA<RouteConfigException>()));
    }
  });

  test('recursive ancestors expand once and preserve their original records',
      () {
    final a = host('a', proxy: proxy);
    final b = host('b', jumps: ['a']);
    final c = host('c', jumps: ['b']);
    final hosts = [a, b, c];
    final before = jsonEncode(hosts.map((h) => h.data).toList());
    final target = host('target', jumps: ['c']);
    final proposal = propose(target, hosts);
    expect(proposal.labels, ['a', 'b', 'c']);
    final selected = proposal.select(useFirstProxy: true);
    expect(selected.hostChainIds, ['a', 'b', 'c']);
    expect(
        resolve(selected, hosts).jumps.map((h) => h.host.id), ['a', 'b', 'c']);
    expect(propose(selected, hosts).select(useFirstProxy: true).hostChainIds,
        ['a', 'b', 'c']);
    expect(jsonEncode(hosts.map((h) => h.data).toList()), before);
  });

  test('an already listed common ancestor is not silently duplicated', () {
    final hosts = [
      host('a'),
      host('b', jumps: ['a'])
    ];
    final proposal = propose(host('target', jumps: ['a', 'b']), hosts);
    expect(proposal.select(useFirstProxy: false).hostChainIds, ['a', 'b']);
  });

  for (final scenario in [
    'missing',
    'cycle',
    'target-cycle',
    'too-long',
    'duplicate',
    'duplicate-endpoint',
    'not-ssh',
    'malformed',
    'later-proxy',
    'conflicting-proxy',
    'unknown-proxy'
  ]) {
    test('expansion refuses $scenario without altering draft or source', () {
      final target = host('target', jumps: ['c']);
      final hosts = switch (scenario) {
        'missing' => [
            host('c', jumps: ['missing'])
          ],
        'cycle' => [
            host('c', jumps: ['a']),
            host('a', jumps: ['c'])
          ],
        'target-cycle' => [
            host('c', jumps: ['target']),
            target
          ],
        'too-long' => [
            host('c', jumps: ['a', 'b', 'd']),
            host('a'),
            host('b'),
            host('d')
          ],
        'duplicate' => [
            host('c', jumps: ['a', 'a']),
            host('a')
          ],
        'duplicate-endpoint' => [
            host('c', jumps: ['a'], extra: {'hostname': 'a.example'}),
            host('a')
          ],
        'not-ssh' => [
            host('c', jumps: ['a']),
            host('a', extra: {'protocol': 'telnet'})
          ],
        'malformed' => [
            host('c', extra: {
              'hostChain': {'hostIds': 'bad'}
            })
          ],
        'later-proxy' => [
            host('c', jumps: ['a'], proxy: proxy),
            host('a')
          ],
        'conflicting-proxy' => [host('c', proxy: proxy, profile: 'missing')],
        _ => [
            host('c', proxy: {...proxy, 'type': 'unknown'})
          ],
      };
      final before = jsonEncode([target.data, ...hosts.map((h) => h.data)]);
      expect(
          () => propose(target, hosts), throwsA(isA<RouteConfigException>()));
      expect(jsonEncode([target.data, ...hosts.map((h) => h.data)]), before);
    });
  }

  test(
      'order, entry, source address or nested path changes invalidate confirmation',
      () {
    final a = host('a', proxy: proxy);
    final b = host('b', jumps: ['a']);
    final hosts = [a, b];
    final target = propose(host('target', jumps: ['b']), hosts)
        .select(useFirstProxy: true);
    for (final change in [
      HostProfile({
        ...target.data,
        'proxyConfig': {...proxy, 'port': 1081}
      }),
      HostProfile({
        ...target.data,
        'hostChain': {
          ...target.data['hostChain'] as Map,
          'hostIds': ['b', 'a']
        }
      }),
      HostProfile({
        ...target.data,
        'hostChain': {
          ...target.data['hostChain'] as Map,
          jumpRouteConfirmationKey: 'bad'
        }
      }),
    ]) {
      expect(
          () => resolve(change, hosts), throwsA(isA<RouteConfigException>()));
    }
    for (final changedHosts in [
      [
        host('a', proxy: {...proxy, 'port': 1081}),
        b
      ],
      [
        host('a', proxy: proxy, extra: {'hostname': 'changed.example'}),
        b
      ],
      [a, host('b')],
    ]) {
      expect(() => resolve(target, changedHosts),
          throwsA(isA<RouteConfigException>()));
    }
  });

  test('dialog revision detects secret changes without storing them in consent',
      () {
    final target = host('target', jumps: ['a']);
    final original = propose(target, [host('a', proxy: proxy)]);
    final changed = propose(target, [
      host('a', proxy: {...proxy, 'password': 'changed'})
    ]);
    expect(original.sameRevision(changed), isFalse);
  });

  test('draft retains confirmation on reopen, strips it on Telnet and clear',
      () {
    final hosts = [host('a', proxy: proxy)];
    final selected = propose(host('target', jumps: ['a']), hosts)
        .select(useFirstProxy: true);
    final draft = ConnectionRouteDraft.forHost(selected);
    final data = {...selected.data};
    draft.writeTo(data);
    expect(resolve(HostProfile(data), hosts).entry, isA<ProxyEntry>());
    draft.writeTo(data, enabled: false);
    expect(data.containsKey('hostChain'), isFalse);
    draft.clear();
    draft.writeTo(data);
    expect(draft.confirmation, isNull);
    expect(data.containsKey('proxyConfig'), isFalse);
  });
}
