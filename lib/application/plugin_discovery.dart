import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../infrastructure/plugins/android_plugin_bridge.dart';
import '../infrastructure/plugins/plugin_approval_store.dart';
import 'plugin_registry.dart';

class PluginApprovalRefused implements Exception {
  const PluginApprovalRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 把 Android 桥报告的安装包、用户的批准记录接到 PluginRegistry 上（X02）。
///
/// 规则都在 registry / plugin_api 里，这里只搬运事实：
/// - 发现：系统报告的包、实际服务类、当前签名证书、哪些是调试证书；
/// - 批准：只能批准「待批准」的条目，绑定当下系统读出的那张证书；
/// - 连接测试：只有 Ready 的才去绑定，其余在宿主这边就停下，插件代码一行都不会跑。
class PluginDiscovery {
  PluginDiscovery(this._bridge, this._store, this._registry);

  final AndroidPluginBridge _bridge;
  final PluginApprovalStore _store;
  final PluginRegistry _registry;
  var _approvalsLoaded = false;

  bool get supported => _bridge.supported;
  Stream<PluginBridgeEvent> get events => _bridge.events;

  Future<void> refresh() async {
    if (!_approvalsLoaded) {
      for (final binding in _store.load()) {
        _registry.approve(binding);
      }
      _approvalsLoaded = true;
    }
    final found = await _bridge.discover();
    final seen = <String>{};
    for (final pkg in found) {
      seen.add(pkg.packageName);
      _registry.offerInstalled(
        packageName: pkg.packageName,
        descriptorJson: pkg.descriptorJson ?? '',
        signerDigests: {for (final s in pkg.signers) s.sha256},
        serviceClass: pkg.serviceClass,
        debugSignerDigests: {
          for (final s in pkg.signers)
            if (s.androidDebug) s.sha256,
        },
        problem: pkg.problem,
      );
    }
    // 这次没出现的包按「已卸载」处理：条目和引用留着，不删批准记录（重装同一证书的包直接恢复）。
    for (final gone in _registry.installedPackages.difference(seen)) {
      _registry.markUninstalled(gone);
    }
  }

  Future<String> inspect(String packageName) =>
      _bridge.inspect(packageName.trim());

  /// 用户在确认框里点了批准。绑定的是此刻系统读出的证书，不是插件自报的任何东西。
  Future<void> approve(PluginEntry entry) async {
    final descriptor = entry.descriptor;
    final package = entry.packageName;
    if (entry.status != PluginStatus.needsApproval ||
        descriptor == null ||
        package == null) {
      throw const PluginApprovalRefused('只有待批准的插件可以批准');
    }
    if (entry.signerDigests.length != 1) {
      // 多个签名者要求全部匹配，批准记录目前只存一张证书；与其放宽，不如先不支持。
      throw const PluginApprovalRefused('这个插件由多张证书共同签名，暂不支持批准');
    }
    final binding = ApprovedBinding(
      pluginId: descriptor.pluginId,
      packageName: package,
      signingDigest: entry.signerDigests.single,
      capabilities: descriptor.capabilities,
    );
    await _store.save(binding);
    _registry.approve(binding);
  }

  Future<void> revoke(PluginEntry entry) async {
    final id = entry.pluginId;
    if (id == null) return;
    await _store.remove(id);
    _registry.revoke(id);
    final package = entry.packageName;
    if (package != null) await _bridge.disconnect(package);
  }

  /// 连接测试：绑定 → 握手（插件核对宿主证书）→ ping 往返。
  /// 不是 Ready 的在这里就返回原因，不绑定。连接保持到 [disconnect] 或页面关闭，
  /// 这样插件握手后发回的事件也能看到。
  Future<String> check(PluginEntry entry) async {
    final id = entry.pluginId;
    final package = entry.packageName;
    final binding = entry.binding;
    if (entry.status != PluginStatus.ready ||
        id == null ||
        package == null ||
        binding == null ||
        entry.serviceClass == null) {
      return '没有绑定插件：它现在不可用（${entry.reason ?? entry.status.name}）';
    }
    try {
      await _bridge.connect(
        packageName: package,
        serviceClass: entry.serviceClass!,
        pluginId: id,
        sha256: binding.signingDigest,
      );
      final nonce = Random.secure().nextInt(1 << 31);
      final echoed = await _bridge.ping(package, nonce);
      if (echoed != nonce) {
        await _bridge.disconnect(package);
        return 'ping 返回的值不对，已断开';
      }
      return '握手成功（插件核对了宿主证书），ping 往返正常';
    } on PluginBridgeException catch (e) {
      return '连接失败：${e.message}';
    }
  }

  Future<void> disconnect(String packageName) =>
      _bridge.disconnect(packageName);
}

final androidPluginBridgeProvider = Provider((ref) => AndroidPluginBridge());

final pluginDiscoveryProvider = FutureProvider<PluginDiscovery>((ref) async {
  final preferences = await SharedPreferences.getInstance();
  return PluginDiscovery(
    ref.watch(androidPluginBridgeProvider),
    PluginApprovalStore(preferences),
    ref.read(pluginRegistryProvider.notifier),
  );
});
