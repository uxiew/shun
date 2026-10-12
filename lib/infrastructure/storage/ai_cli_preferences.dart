import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/dart.dart';

import '../../application/connection_lifecycle.dart';
import '../../domain/ai_cli.dart';
import '../../domain/models/host.dart';

abstract interface class AiCliPreferencesStore {
  Future<AiCliScanRequest> load(String scope);
  Future<void> save(String scope, AiCliScanRequest request);
}

/// Device-local discovery settings. Separate from vault export/sync, with no
/// credentials, output or conversations. Android backup rules exclude all data.
class SecureAiCliPreferences implements AiCliPreferencesStore {
  const SecureAiCliPreferences();
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
        encryptedSharedPreferences: true, sharedPreferencesName: 'shun_ai_cli'),
    iOptions: IOSOptions(
        accountName: 'shun.aiCli',
        accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  String _key(String scope) =>
      'discovery.${base64Url.encode(utf8.encode(scope))}';
  @override
  Future<AiCliScanRequest> load(String scope) async {
    final text = await storage.read(key: _key(scope));
    if (text == null) return AiCliScanRequest();
    if (text.length > 100000) throw const FormatException('工具检测设置超出上限');
    final data = jsonDecode(text) as Map<String, dynamic>;
    if (data['version'] != 1) {
      throw const FormatException('工具检测设置版本不支持');
    }
    return AiCliScanRequest(
      directories: (data['directories'] as List).cast<String>(),
      customTools: [
        for (final entry in data['customTools'] as List)
          AiCliCustomTool(
              name: entry['name'] as String, path: entry['path'] as String)
      ],
    );
  }

  @override
  Future<void> save(String scope, AiCliScanRequest request) => storage.write(
        key: _key(scope),
        value: jsonEncode({
          'version': 1,
          'directories': request.directories,
          'customTools': [
            for (final tool in request.customTools)
              {'name': tool.name, 'path': tool.path}
          ],
        }),
      );
}

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
