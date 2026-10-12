import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/ai_cli_work.dart';

abstract interface class AiCliRecentWorkStore {
  Future<List<AiCliWorkItem>> load(String hostScope);
  Future<void> record(String hostScope, AiCliWorkItem item);
  Future<void> clear(String hostScope);
}

/// Encrypted, device-local pointers only. This namespace is excluded from
/// Android backup and uses this-device-only Keychain accessibility on iOS.
class SecureAiCliRecentWork implements AiCliRecentWorkStore {
  const SecureAiCliRecentWork();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
        encryptedSharedPreferences: true, sharedPreferencesName: 'shun_ai_cli'),
    iOptions: IOSOptions(
        accountName: 'shun.aiCli',
        accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  String _key(String scope) => 'recent.${base64Url.encode(utf8.encode(scope))}';
  static final _writes = <String, Future<void>>{};

  Future<void> _serial(String scope, Future<void> Function() action) {
    final previous = _writes[scope] ?? Future<void>.value();
    final result = previous.then((_) => action());
    // A failed write must not poison later clearing/retry, while callers still
    // receive its failure. All instances share this queue for the same scope.
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _writes[scope] = tail;
    unawaited(tail.then((_) {
      if (identical(_writes[scope], tail)) _writes.remove(scope);
    }));
    return result;
  }

  @override
  Future<List<AiCliWorkItem>> load(String hostScope) async {
    final raw = await _storage.read(key: _key(hostScope));
    if (raw == null) return const [];
    if (raw.length > 100000) throw const FormatException('最近工作记录无效');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    if (decoded['version'] != 1) {
      throw const FormatException('最近工作记录无效');
    }
    return [
      for (final rawItem in (decoded['items'] as List).take(20))
        if (AiCliWorkItem.fromJson(rawItem) case final item?) item,
    ];
  }

  @override
  Future<void> record(String hostScope, AiCliWorkItem item) =>
      _serial(hostScope, () async {
        final old = await load(hostScope);
        final items = [
          item,
          ...old.where((value) =>
              value.id != item.id &&
              (value.executable != item.executable ||
                  value.projectDirectory != item.projectDirectory)),
        ].take(20).toList();
        String encode() => jsonEncode({
              'version': 1,
              'items': [for (final value in items) value.toJson()],
            });
        var encoded = encode();
        while (encoded.length > 100000 && items.length > 1) {
          items.removeLast();
          encoded = encode();
        }
        await _storage.write(
          key: _key(hostScope),
          value: encoded,
        );
      });

  @override
  Future<void> clear(String hostScope) =>
      _serial(hostScope, () => _storage.delete(key: _key(hostScope)));
}
