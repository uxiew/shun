import '../infrastructure/storage/remote_entry_store.dart';
import 'external_remote.dart';
import 'uuremote_models.dart';

class UuRemoteStore {
  UuRemoteStore(this._backend);
  final ProviderSecretBackend _backend;
  late final local = RemoteEntryStore(
    _backend,
    prefix: 'uuremote',
    recordsKey: 'uuremote.bindings.v1',
    pendingKey: 'uuremote.pending.v1',
    validRecord: (raw) => UuBinding.fromJson(raw) != null,
    validPending: (raw) => UuPendingRequest.fromJson(raw) != null,
  );

  Future<List<UuBinding>> bindings() async => [
        for (final row in local.records) UuBinding.fromJson(row)!,
      ];
  Future<void> saveBindings(List<UuBinding> bindings) =>
      local.saveRecords([for (final binding in bindings) binding.toJson()]);
  Future<UuPendingRequest?> pending() async =>
      UuPendingRequest.fromJson(local.pending);
  Future<void> savePending(UuPendingRequest? request) =>
      local.savePending(request?.toJson());
  Future<String?> approvedSigner() =>
      _backend.read('uuremote.approvedSigner.v1');
  Future<void> saveApprovedSigner(String? sha256) => sha256 == null
      ? _backend.delete('uuremote.approvedSigner.v1')
      : _backend.write('uuremote.approvedSigner.v1', sha256);
}
