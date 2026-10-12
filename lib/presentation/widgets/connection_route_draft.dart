import 'package:flutter/material.dart';

import '../../domain/models/host.dart';

/// Existing R10 modes. The R40 chain UI is a separate, later change.
enum ConnectionRouteMode { direct, proxy, jump }

/// Editable route fields shared by the host form and catalog import.
/// The owning page controls rebuilds, validation/preview and disposal. Hidden
/// values survive mode switches, but only the selected route is serialized.
class ConnectionRouteDraft {
  ConnectionRouteDraft.forHost(HostProfile? host)
      : proxyHost = TextEditingController(text: host?.proxyConfig?.host),
        proxyPort = TextEditingController(
            text: host?.proxyConfig == null || host!.proxyConfig!.port == 0
                ? ''
                : host.proxyConfig!.port.toString()),
        proxyUsername =
            TextEditingController(text: host?.proxyConfig?.username),
        proxyPassword =
            TextEditingController(text: host?.proxyConfig?.password) {
    jumpHostIds.addAll(host?.hostChainIds ?? const []);
    proxyType = host?.proxyConfig?.type ?? ProxyType.socks5;
    final hasProfile = host?.proxyProfileId?.isNotEmpty == true;
    proxyMode = hasProfile ? 'profile:${host!.proxyProfileId}' : 'custom';
    final hasProxy = hasProfile || host?.proxyConfig != null;
    mode = jumpHostIds.isNotEmpty
        ? ConnectionRouteMode.jump
        : hasProxy
            ? ConnectionRouteMode.proxy
            : ConnectionRouteMode.direct;
    entryProxy = jumpHostIds.isNotEmpty && hasProxy;
  }

  ConnectionRouteDraft.forCatalogImport()
      : proxyHost = TextEditingController(),
        proxyPort = TextEditingController(),
        proxyUsername = TextEditingController(),
        proxyPassword = TextEditingController();

  final TextEditingController proxyHost,
      proxyPort,
      proxyUsername,
      proxyPassword;
  final jumpHostIds = <String>[];
  ConnectionRouteMode mode = ConnectionRouteMode.direct;
  ProxyType proxyType = ProxyType.socks5;

  /// Empty means unselected, `custom` is inline, `profile:<id>` is a reference.
  String proxyMode = '';
  bool entryProxy = false;
  bool obscureProxyPassword = true;

  bool get usesProxy =>
      mode == ConnectionRouteMode.proxy ||
      (mode == ConnectionRouteMode.jump && entryProxy);
  List<String> get selectedJumpHostIds =>
      mode == ConnectionRouteMode.jump ? [...jumpHostIds] : const [];
  String? get selectedProxyProfileId =>
      usesProxy && proxyMode.startsWith('profile:')
          ? proxyMode.substring('profile:'.length)
          : null;
  ProxyConfig? get selectedProxyConfig => usesProxy && proxyMode == 'custom'
      ? ProxyConfig(
          type: proxyType,
          host: proxyHost.text.trim(),
          port: int.tryParse(proxyPort.text.trim()) ?? 0,
          username: proxyUsername.text.trim(),
          password: proxyPassword.text)
      : null;

  /// Same desktop-compatible keys; Telnet explicitly strips route settings.
  void writeTo(Map<String, dynamic> data, {bool enabled = true}) {
    final jumps = enabled ? selectedJumpHostIds : const <String>[];
    if (jumps.isEmpty) {
      data.remove('hostChain');
    } else {
      data['hostChain'] = {'hostIds': jumps};
    }
    final profile = enabled ? selectedProxyProfileId : null;
    final custom = enabled ? selectedProxyConfig : null;
    data.remove('proxyProfileId');
    data.remove('proxyConfig');
    if (profile != null) data['proxyProfileId'] = profile;
    if (custom != null) data['proxyConfig'] = custom.toJson();
  }

  void dispose() {
    for (final c in [proxyHost, proxyPort, proxyUsername, proxyPassword]) {
      c.dispose();
    }
  }
}
