import '../../domain/models/host.dart';

/// Mutable presentation draft. It neither resolves routes nor writes storage.
/// Existing malformed/unknown values remain visible to the route resolver until
/// the user explicitly replaces or removes that part of the route.
class ConnectionRouteDraft {
  ConnectionRouteDraft.forHost(HostProfile? host) {
    proxyProfileId = host?.proxyProfileId;
    inlineProxy = host?.data['proxyConfig'];
    final chain = host?.data['hostChain'];
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
        'hostIds': [...jumpHostIds]
      };
    }
    if (proxyProfileId != null) data['proxyProfileId'] = proxyProfileId;
    if (inlineProxy != null) data['proxyConfig'] = inlineProxy;
  }
}
