import 'package:plugin_api/plugin_api.dart';
import 'device_references.dart';

/// Local-only connection metadata. Provider secrets stay in their own store.
/// Legacy owner IDs are retained within each provider namespace, so pending
/// callbacks and device references do not need a lossy re-keying step.
class RemoteEntry {
  const RemoteEntry({
    required this.id,
    required this.label,
    this.sourceHostId,
    this.sourceCatalogId,
    this.sourceDeviceId,
    this.routeWarning = RequestedRoute.systemDefault,
  });

  final String id;
  final String label;
  final String? sourceHostId;
  final String? sourceCatalogId;
  final String? sourceDeviceId;
  final RequestedRoute routeWarning;

  RemoteEntry renamed(String name) => RemoteEntry(
        id: id,
        label: name,
        sourceHostId: sourceHostId,
        sourceCatalogId: sourceCatalogId,
        sourceDeviceId: sourceDeviceId,
        routeWarning: routeWarning,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        if (sourceHostId != null) 'sourceHostId': sourceHostId,
        if (sourceCatalogId != null) 'sourceCatalogId': sourceCatalogId,
        if (sourceDeviceId != null) 'sourceDeviceId': sourceDeviceId,
        'routeWarning': routeWarning.name,
      };

  static RemoteEntry fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final label = json['label'];
    final route = RequestedRoute.values
        .where((r) => r.name == json['routeWarning'])
        .firstOrNull;
    if (id is! String ||
        id.isEmpty ||
        label is! String ||
        label.trim().isEmpty ||
        route == null ||
        [
          json['sourceHostId'],
          json['sourceCatalogId'],
          json['sourceDeviceId'],
        ].any((v) => v != null && (v is! String || v.isEmpty)) ||
        (json['sourceCatalogId'] == null) != (json['sourceDeviceId'] == null) ||
        (json['sourceCatalogId'] != null &&
            !isValidCatalogId(json['sourceCatalogId'] as String))) {
      throw const FormatException('Invalid remote entry');
    }
    return RemoteEntry(
      id: id,
      label: label,
      sourceHostId: json['sourceHostId'] as String?,
      sourceCatalogId: json['sourceCatalogId'] as String?,
      sourceDeviceId: json['sourceDeviceId'] as String?,
      routeWarning: route,
    );
  }
}
