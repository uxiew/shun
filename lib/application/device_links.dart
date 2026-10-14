import 'package:plugin_api/plugin_api.dart';

import '../domain/device_references.dart';
import '../domain/remote_entry.dart';
import 'rustdesk.dart';
import 'tailscale_catalog_refresh.dart';
import 'uuremote.dart';

/// Only explicit source associations are carried forward; names, addresses and
/// provider secrets never participate in device identity. Independent entries
/// without a source remain independent even when their labels match.
DeviceLinks deviceLinksOf({
  required List<CatalogHost> hosts,
  List<UuBinding> uu = const [],
  List<RustDeskLink> rustdesk = const [],
  List<RemoteEntry> uuEntries = const [],
  List<RemoteEntry> rustdeskEntries = const [],
}) {
  final groups = <String, List<ProviderDeviceRef>>{};
  final hostIds = hosts.map((h) => h.id).toSet();
  final catalogs = <String, ProviderDeviceRef>{};
  for (final host in hosts) {
    groups[host.id] = [
      sshHostRef(host.id, displayName: host.label, hostname: host.hostname)
    ];
    final b = host.binding;
    if (b != null && isValidCatalogId(b.catalogId) && b.deviceId.isNotEmpty) {
      catalogs[host.id] = catalogDeviceRef(b.catalogId, b.deviceId);
    }
  }
  void attach(
      String owner, ProviderDeviceRef reference, List<RemoteEntry> entries) {
    final entry = entries.where((e) => e.id == owner).firstOrNull;
    // Legacy callers can still assemble their captured v1 evidence. Once entry
    // metadata is supplied, an absent source never implicitly becomes SSH.
    final source = entry?.sourceHostId ?? (entries.isEmpty ? owner : null);
    if (source == null) return;
    final refs = groups.putIfAbsent(source, () => []);
    if (!refs.any((r) => r.providerId == reference.providerId)) {
      refs.add(reference);
    }
    // An explicitly detached live catalog source takes precedence over the old
    // snapshot. Preserve the snapshot only when the original SSH entry is gone.
    if (!hostIds.contains(source) &&
        entry != null &&
        entry.sourceCatalogId != null &&
        isValidCatalogId(entry.sourceCatalogId!)) {
      catalogs.putIfAbsent(
          source,
          () =>
              catalogDeviceRef(entry.sourceCatalogId!, entry.sourceDeviceId!));
    }
  }

  for (final b in [...uu]..sort((a, b) => a.createdAt.compareTo(b.createdAt))) {
    attach(b.hostId, uuBindingRef(b.id), uuEntries);
  }
  for (final l in [...rustdesk]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt))) {
    attach(l.hostId, rustDeskPeerRef(l.id), rustdeskEntries);
  }
  final links = DeviceLinks();
  for (final group in groups.entries) {
    final catalog = catalogs[group.key];
    final refs = [
      ...group.value,
      if (catalog != null && links.recordOf(catalog) == null) catalog
    ];
    if (refs.length >= 2) links.linkByUser(refs);
  }
  return links;
}
