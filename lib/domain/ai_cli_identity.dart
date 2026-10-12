import 'dart:convert';

import 'package:cryptography/dart.dart';

import 'host_identity.dart';
import 'models/host.dart';

/// Stable identity for both discovery preferences and recent work. Keep the
/// serialization compatible: changing it makes existing local records invisible.
String aiCliHostScope(HostProfile host) {
  // Environment can select a different CLI account/history (e.g. CODEX_HOME).
  // Hash the effective values; never put raw environment secrets in metadata.
  final environment = <String, String>{};
  for (final entry in host.data['environmentVariables'] as List? ?? const []) {
    if (entry is Map && entry['name'] != null) {
      environment[entry['name'].toString()] = entry['value']?.toString() ?? '';
    }
  }
  final names = environment.keys.toList()..sort();
  return jsonEncode([
    sourceHostIdOf(host),
    host.hostname,
    host.port,
    host.username,
    if (names.isNotEmpty)
      base64Url.encode(const DartSha256()
          .hashSync(utf8.encode(
              jsonEncode({for (final key in names) key: environment[key]})))
          .bytes),
  ]);
}
