import 'dart:convert';

import 'package:plugin_api/plugin_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户批准过的插件绑定（pluginId + 包名 + 证书 + 能力）。
///
/// 放普通偏好而不是安全存储：里面没有秘密，只有公开的证书摘要；
/// 被人改了也只会让插件变成「待批准」或「换签被拒」，不会让未批准的插件变可用——
/// 准入仍要系统读出的证书与这里完全一致。
class PluginApprovalStore {
  PluginApprovalStore(this._preferences);

  final SharedPreferences _preferences;
  static const _key = 'xwshun.plugins.approvals.v1';

  List<ApprovedBinding> load() {
    final raw = _preferences.getString(_key);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List<Object?>;
      return [
        for (final item in list)
          if (_decode(item) case final binding?) binding,
      ];
    } on Object {
      // 读不懂就当没有批准过：宁可让用户重新批准，也不猜。
      return const [];
    }
  }

  Future<void> save(ApprovedBinding binding) async {
    final all = [
      for (final b in load())
        if (b.pluginId.toLowerCase() != binding.pluginId.toLowerCase()) b,
      binding,
    ];
    await _write(all);
  }

  Future<void> remove(String pluginId) async {
    await _write([
      for (final b in load())
        if (b.pluginId.toLowerCase() != pluginId.toLowerCase()) b,
    ]);
  }

  Future<void> _write(List<ApprovedBinding> bindings) => _preferences.setString(
        _key,
        jsonEncode([
          for (final b in bindings)
            {
              'pluginId': b.pluginId,
              'packageName': b.packageName,
              'signingDigest': b.signingDigest,
              'capabilities': [for (final c in b.capabilities) c.wire],
            },
        ]),
      );

  static ApprovedBinding? _decode(Object? item) {
    if (item is! Map) return null;
    final id = item['pluginId'];
    final package = item['packageName'];
    final digest = item['signingDigest'];
    final caps = item['capabilities'];
    if (id is! String ||
        package is! String ||
        digest is! String ||
        caps is! List) {
      return null;
    }
    final capabilities = <Capability>{};
    for (final name in caps) {
      final known = Capability.values.where((c) => c.wire == name).firstOrNull;
      // 不认识的能力名不静默丢掉再当作批准过：整条作废，让用户重新批准。
      if (known == null) return null;
      capabilities.add(known);
    }
    return ApprovedBinding(
      pluginId: id,
      packageName: package,
      signingDigest: digest,
      capabilities: capabilities,
    );
  }
}
