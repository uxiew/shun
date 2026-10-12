import '../../domain/models/host.dart';
import '../../domain/connection_route.dart';

/// Mutable presentation draft. It neither resolves routes nor writes storage.
/// Existing malformed/unknown values remain visible to the route resolver until
/// the user explicitly replaces or removes that part of the route.
class ConnectionRouteDraft {
  ConnectionRouteDraft.forHost(HostProfile? host) {
    proxyProfileId = host?.proxyProfileId;
    inlineProxy = host?.data['proxyConfig'];
    final chain = host?.data['hostChain'];
    if (chain is Map) {
      _chainExtras.addAll(Map<String, dynamic>.from(chain)..remove('hostIds'));
    }
    if (chain != null &&
        (chain is! Map ||
            (chain['hostIds'] != null &&
                (chain['hostIds'] is! List ||
                    (chain['hostIds'] as List)
                        .any((id) => id is! String || id.isEmpty))))) {
      _unparsedChain = chain;
    } else {
      jumpHostIds.addAll(host?.hostChainIds ?? const []);
    }
  }

  ConnectionRouteDraft.forCatalogImport();

  final jumpHostIds = <String>[];
  final _chainExtras = <String, dynamic>{};
  Object? get confirmation => _chainExtras[jumpRouteConfirmationKey];
  void invalidateChoices() => _chainExtras.remove(jumpRouteConfirmationKey);
  HostProfile choiceTarget(String? id) {
    final data = <String, dynamic>{
      'id': id ?? '__route_edit__',
      'label': 'route',
      'hostname': 'route-edit.invalid',
      'username': 'route',
      'protocol': 'ssh',
      'port': 22,
    };
    writeTo(data);
    return HostProfile(data);
  }

  void applyChoice(HostProfile host) {
    final next = ConnectionRouteDraft.forHost(host);
    proxyProfileId = next.proxyProfileId;
    inlineProxy = next.inlineProxy;
    _unparsedChain = next._unparsedChain;
    jumpHostIds
      ..clear()
      ..addAll(next.jumpHostIds);
    _chainExtras
      ..clear()
      ..addAll(next._chainExtras);
  }

  Object? _unparsedChain;
  String? proxyProfileId;
  Object? inlineProxy;

  bool get usesProxy =>
      proxyProfileId?.isNotEmpty == true || inlineProxy != null;
  List<String> get selectedJumpHostIds => [...jumpHostIds];
  String? get selectedProxyProfileId => proxyProfileId;
  ProxyConfig? get selectedProxyConfig => inlineProxy is Map
      ? ProxyConfig.fromJson(Map<String, dynamic>.from(inlineProxy as Map))
      : null;

  void selectProxy(String id) {
    proxyProfileId = id;
    inlineProxy = null;
  }

  void removeProxy() {
    proxyProfileId = null;
    inlineProxy = null;
  }

  void addJump(String id) {
    _unparsedChain = null;
    jumpHostIds.add(id);
  }

  void clear() {
    removeProxy();
    _unparsedChain = null;
    _chainExtras.clear();
    jumpHostIds.clear();
  }

  /// Same desktop-compatible keys; Telnet explicitly strips route settings.
  void writeTo(Map<String, dynamic> data, {bool enabled = true}) {
    data.remove('hostChain');
    data.remove('proxyProfileId');
    data.remove('proxyConfig');
    if (!enabled) return;
    if (_unparsedChain != null) {
      data['hostChain'] = _unparsedChain;
    } else if (jumpHostIds.isNotEmpty) {
      data['hostChain'] = {
        ..._chainExtras,
        'hostIds': [...jumpHostIds]
      };
    }
    if (proxyProfileId != null) data['proxyProfileId'] = proxyProfileId;
    if (inlineProxy != null) data['proxyConfig'] = inlineProxy;
  }
}
