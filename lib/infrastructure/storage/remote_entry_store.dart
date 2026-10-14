import 'dart:convert';

import '../../application/external_remote.dart';
import '../../domain/remote_entry.dart';
import 'package:plugin_api/plugin_api.dart';

class RemoteEntryStorageException implements Exception {
  const RemoteEntryStorageException();
  @override
  String toString() => '远控存储未就绪或迁移失败；原记录保留，请重试。';
}

/// One encrypted document is the commit point for entries, bindings and UU
/// pending requests. The old keys remain a recovery copy, never a fallback once
/// v2 exists. A failed read-back blocks this instance until explicitly reloaded.
class RemoteEntryStore {
  RemoteEntryStore(
    this.backend, {
    required this.prefix,
    required this.recordsKey,
    required this.validRecord,
    this.pendingKey,
    this.validPending,
  });
  final ProviderSecretBackend backend;
  final String prefix;
  final String recordsKey;
  final bool Function(Object?) validRecord;
  final String? pendingKey;
  final bool Function(Object?)? validPending;
  Map<String, dynamic>? _data;
  String get key => '$prefix.entries.v2';

  List<RemoteEntry> get entries => [
        for (final e in _current['entries'] as List)
          RemoteEntry.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
  List<Map<String, dynamic>> get records => [
        for (final e in _current['records'] as List)
          Map<String, dynamic>.from(e as Map),
      ];
  Map<String, dynamic>? get pending => _current['pending'] == null
      ? null
      : Map<String, dynamic>.from(_current['pending'] as Map);
  Map<String, dynamic> get _current =>
      _data ?? (throw const RemoteEntryStorageException());

  Future<void> initialize(
    Future<List<RemoteControlHost>> Function() hosts,
  ) async {
    _data = null;
    try {
      final current = await backend.read(key);
      if (current != null) {
        _data = _validate(jsonDecode(current));
        return;
      }
      final raw = await backend.read(recordsKey);
      final rows = raw == null ? <dynamic>[] : jsonDecode(raw) as List;
      final pendingRaw =
          pendingKey == null ? null : await backend.read(pendingKey!);
      final request = pendingRaw == null ? null : jsonDecode(pendingRaw);
      // Validate all legacy rows before writing anything. Never silently drop a
      // malformed or ambiguous binding, or fabricate an owner for a callback.
      final owners = <String>{};
      final ids = <String>{};
      for (final row in rows) {
        if (!validRecord(row) ||
            row is! Map ||
            !_nonEmpty(row['hostId']) ||
            !_nonEmpty(row['id']) ||
            !owners.add(row['hostId'] as String) ||
            !ids.add(row['id'] as String)) {
          throw const RemoteEntryStorageException();
        }
      }
      if (request != null) {
        if (validPending?.call(request) != true ||
            request is! Map ||
            !_nonEmpty(request['hostId'])) {
          throw const RemoteEntryStorageException();
        }
        if (_controlOwnerConflict(request, rows)) {
          throw const RemoteEntryStorageException();
        }
        owners.add(request['hostId'] as String);
      }
      final sources = owners.isEmpty ? <RemoteControlHost>[] : await hosts();
      for (final owner in owners) {
        if (sources.where((h) => h.id == owner).length > 1) {
          throw const RemoteEntryStorageException();
        }
      }
      final entries = [for (final owner in owners) _migrate(owner, sources)];
      await _commit({
        'version': 2,
        'entries': [for (final e in entries) e.toJson()],
        'records': rows,
        'pending': request,
      });
    } on Object {
      _data = null;
      throw const RemoteEntryStorageException();
    }
  }

  RemoteEntry _migrate(String owner, List<RemoteControlHost> hosts) {
    final host = hosts.where((h) => h.id == owner).firstOrNull;
    return RemoteEntry(
      id: owner,
      label: host?.label ?? '$prefix · $owner',
      sourceHostId: owner,
      sourceCatalogId: host?.catalogId,
      sourceDeviceId: host?.deviceId,
      routeWarning: host?.sshRoute ?? RequestedRoute.systemDefault,
    );
  }

  Future<void> saveEntry(RemoteEntry entry) => _commit({
        ..._current,
        'entries': [
          for (final e in entries)
            if (e.id != entry.id) e.toJson(),
          entry.toJson(),
        ],
      });
  Future<void> deleteEntry(String id) => _commit({
        ..._current,
        'entries': [
          for (final e in entries)
            if (e.id != id) e.toJson(),
        ],
        'records': [
          for (final r in records)
            if (r['hostId'] != id) r,
        ],
        // Deleting the owner revokes only its pending request.
        'pending': pending?['hostId'] == id ? null : pending,
      });
  Future<void> saveRecords(List<Map<String, Object?>> rows) => _commit({
        ..._current,
        'records': rows,
        'pending': pending?['kind'] == 'control' &&
                records.any((r) => r['id'] == pending?['bindingId']) &&
                !rows.any((r) => r['id'] == pending?['bindingId'])
            ? null
            : pending,
      });
  Future<void> savePending(Map<String, Object?>? request) =>
      _commit({..._current, 'pending': request});

  Future<void> _commit(Map<String, dynamic> next) async {
    try {
      _validate(next);
      final encoded = jsonEncode(next);
      await backend.write(key, encoded);
      final readBack = await backend.read(key);
      if (readBack != encoded) throw const RemoteEntryStorageException();
      _data = _validate(jsonDecode(readBack!));
    } on Object {
      _data = null;
      throw const RemoteEntryStorageException();
    }
  }

  Map<String, dynamic> _validate(Object? value) {
    if (value is! Map ||
        value['version'] != 2 ||
        !value.containsKey('pending') ||
        value['entries'] is! List ||
        value['records'] is! List) {
      throw const RemoteEntryStorageException();
    }
    final entries = <String>{};
    for (final raw in value['entries'] as List) {
      final entry = RemoteEntry.fromJson(Map<String, dynamic>.from(raw as Map));
      if (!entries.add(entry.id)) throw const RemoteEntryStorageException();
    }
    final owners = <String>{};
    final ids = <String>{};
    final rows = value['records'] as List;
    for (final row in rows) {
      if (!validRecord(row) ||
          row is! Map ||
          !_nonEmpty(row['id']) ||
          !entries.contains(row['hostId']) ||
          !ids.add(row['id'] as String) ||
          !owners.add(row['hostId'] as String)) {
        throw const RemoteEntryStorageException();
      }
    }
    final pending = value['pending'];
    if (pending != null &&
        (validPending?.call(pending) != true ||
            pending is! Map ||
            !entries.contains(pending['hostId']) ||
            _controlOwnerConflict(pending, rows))) {
      throw const RemoteEntryStorageException();
    }
    return Map<String, dynamic>.from(value);
  }

  // 旧版删除绑定不会取消 pending。可保留这次等待，但绝不重建绑定；
  // 同一个绑定 ID 已属于另一条连接才是归属冲突，必须拒绝。
  static bool _controlOwnerConflict(Map request, List rows) =>
      request['kind'] == 'control' &&
      rows.any((row) =>
          row['id'] == request['bindingId'] &&
          row['hostId'] != request['hostId']);

  static bool _nonEmpty(Object? v) => v is String && v.isNotEmpty;
}
