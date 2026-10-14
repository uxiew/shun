import 'dart:convert';
import '../infrastructure/plugins/rustdesk_external.dart';
import '../infrastructure/storage/remote_entry_store.dart';
import 'external_remote.dart';
import 'rustdesk_models.dart';

class RustDeskStore {
  RustDeskStore(this._backend);
  final ProviderSecretBackend _backend;
  late final local = RemoteEntryStore(
    _backend,
    prefix: 'rustdesk',
    recordsKey: 'rustdesk.links.v1',
    validRecord: (raw) => RustDeskLink.fromJson(raw) != null,
  );

  Future<List<RustDeskLink>> links() async => [
        for (final row in local.records) RustDeskLink.fromJson(row)!,
      ];
  Future<void> saveLinks(List<RustDeskLink> links) =>
      local.saveRecords([for (final link in links) link.toJson()]);

  Future<RustDeskTrust?> trust() async {
    final raw = await _backend.read('rustdesk.trust.v1');
    if (raw == null) return null;
    try {
      return RustDeskTrust.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  Future<void> saveTrust(RustDeskTrust? trust) => trust == null
      ? _backend.delete('rustdesk.trust.v1')
      : _backend.write('rustdesk.trust.v1', jsonEncode(trust.toJson()));
}
