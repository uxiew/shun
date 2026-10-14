import 'dart:convert';
import 'package:plugin_api/plugin_api.dart';
import 'package:shun/application/external_remote.dart';
import 'package:shun/domain/remote_entry.dart';

void seedRemoteEntries(
    Map<String, String> values, String prefix, List<RemoteControlHost> hosts) {
  values['$prefix.entries.v2'] = jsonEncode({
    'version': 2,
    'records': [],
    'pending': null,
    'entries': [
      for (final h in hosts)
        RemoteEntry(
                id: h.id,
                label: h.label,
                sourceHostId: h.id,
                routeWarning: h.sshRoute)
            .toJson()
    ],
  });
}

void seedScreenEntries(Map<String, String> values, String prefix) =>
    seedRemoteEntries(values, prefix, const [
      RemoteControlHost(
          id: 'win', label: 'win-pc', sshRoute: RequestedRoute.systemDefault),
      RemoteControlHost(
          id: 'mac', label: 'mac', sshRoute: RequestedRoute.socks5Connect),
    ]);

Object? storedField(Map<String, String> values, String prefix, String field) =>
    (jsonDecode(values['$prefix.entries.v2']!) as Map)[field];
