import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

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

/// 把 Android 桥报告的安装包、用户的批准和停用记录接到 PluginRegistry 上（X02、X04）。
///
/// 规则都在 registry / plugin_api 里，这里只搬运事实：
/// - 发现：系统报告的包、实际服务类、当前签名证书、哪些是调试证书、设置页；
/// - 跟踪：系统报告某个包装上、更新、卸载时整体重新发现，更新后的证书和描述符重新过一遍准入，
///   不沿用更新前的判定，也不自动重新批准（PLG11）；
/// - 批准：只能批准「待批准」的条目，绑定当下系统读出的那张证书；确认期间包变了就拒绝；
/// - 连接测试、打开设置页：只有 Ready 的才去碰插件，其余在宿主这边就停下。
class PluginDiscovery {
  PluginDiscovery(this._bridge, this._store, this._registry);

  final AndroidPluginBridge _bridge;
  final PluginApprovalStore _store;
  final PluginRegistry _registry;
  var _recordsLoaded = false;
  StreamSubscription<PackageChange>? _watch;
  Future<void>? _running;
  var _again = false;
  final _notices = StreamController<String>.broadcast();

  bool get supported => _bridge.supported;
  Stream<PluginBridgeEvent> get events => _bridge.events;

  /// 检测到插件包安装、更新、卸载后给用户看的一句话。
  Stream<String> get notices => _notices.stream;

  /// 载入批准和停用记录、发现一次、开始跟踪包变化。可以重复调用，只会订阅一次。
  Future<void> start() async {
    _watch ??= _bridge.packageChanges.listen(_onPackageChange);
    await refresh();
  }

  /// 重新发现。并发调用合并成一次串行的重跑：两次发现交叠时，先结束的那次会用旧列表把后装的包标成卸载。
  Future<void> refresh() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _refreshLoop().whenComplete(() => _running = null);
  }

  Future<void> _refreshLoop() async {
    do {
      _again = false;
      await _discoverOnce();
    } while (_again);
  }

  Future<void> _discoverOnce() async {
    if (!_recordsLoaded) {
      for (final binding in _store.load()) {
        _registry.approve(binding);
      }
      for (final id in _store.loadDisabled()) {
        try {
          _registry.disable(id);
        } on ArgumentError {
          // 偏好被改过、里面有内置 provider 的 ID：内置的不能停用，忽略这一条而不是让发现整个失败。
        }
      }
      _recordsLoaded = true;
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
        settingsActivity: pkg.settingsActivity,
        versionName: pkg.versionName,
        versionCode: pkg.versionCode,
      );
    }
    // 这次没出现的包按「已卸载」处理：条目和引用留着，不删批准记录（重装同一证书的包直接恢复）。
    for (final gone in _registry.installedPackages.difference(seen)) {
      _registry.markUninstalled(gone);
    }
  }

  PluginEntry? _entryOf(String packageName) =>
      _registry.entries.where((e) => e.packageName == packageName).firstOrNull;

  Future<void> _onPackageChange(PackageChange change) async {
    // 更新时系统先发「移除（replacing）」再发「安装」：中间那一刻不当卸载处理，免得会话被白关一次。
    if (change.action == 'removed' && change.replacing) return;
    final package = change.packageName;
    final before = _entryOf(package);
    await refresh();
    final after = _entryOf(package);
    if (before == null && after == null) return; // 不是插件
    // 包一变，之前「连接测试」开的连接就不再沿用：旧进程已被系统杀掉，新包要重新核对后才能再连。
    if (before != null && change.action != 'changed') {
      await _bridge.disconnect(package);
    }
    _notices.add(switch (change.action) {
      'removed' => '检测到插件包卸载：$package。它的会话已关闭，批准记录保留，重装同一证书的包会直接恢复。',
      'added' when before == null || before.status == PluginStatus.missing =>
        '检测到插件包安装：$package。已核对证书和描述符。',
      'changed' => '检测到插件包组件变化：$package。已重新核对。',
      _ => '检测到插件包更新：$package。已重新核对证书和描述符，之前的连接已断开。',
    });
  }

  Future<void> dispose() async {
    await _watch?.cancel();
    await _notices.close();
  }

  Future<String> inspect(String packageName) =>
      _bridge.inspect(packageName.trim());

  /// 本 App 的签名证书，插件作者要把它写进插件（X12）。
  Future<List<({String sha256, bool androidDebug})>> hostSigners() =>
      _bridge.hostSigners();

  /// 用户在确认框里点了批准。绑定的是此刻系统读出的证书，不是插件自报的任何东西。
  ///
  /// [shown] 是确认框里给用户看的那份。批准前先重新发现一次：确认框开着的时候包可能被更新、换签或卸载，
  /// 这时用户核对过的证书和能力已经不是现在的了，拒绝批准，让用户重新核对（PLG11「不自动重新授权」）。
  Future<void> approve(PluginEntry shown) async {
    final package = shown.packageName;
    if (package == null) {
      throw const PluginApprovalRefused('只有待批准的插件可以批准');
    }
    await refresh();
    final entry = _entryOf(package);
    final descriptor = entry?.descriptor;
    if (entry == null ||
        descriptor == null ||
        !setEquals(entry.signerDigests, shown.signerDigests) ||
        descriptor.pluginId != shown.descriptor?.pluginId ||
        descriptor.version != shown.descriptor?.version ||
        !setEquals(descriptor.capabilities, shown.descriptor?.capabilities) ||
        entry.installedVersionCode != shown.installedVersionCode) {
      throw const PluginApprovalRefused('确认期间插件有变化（更新、换签或卸载），没有批准。请重新核对后再批准。');
    }
    if (entry.status != PluginStatus.needsApproval) {
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

  /// 停用：阻止新操作并关掉它的会话，批准记录保留；重启 App 后仍是停用（docs/15 §7）。
  Future<void> disable(PluginEntry entry) async {
    final id = entry.pluginId;
    if (id == null || entry.isBuiltin) return;
    await _store.setDisabled(id, true);
    _registry.disable(id);
    final package = entry.packageName;
    if (package != null) await _bridge.disconnect(package);
  }

  Future<void> enable(PluginEntry entry) async {
    final id = entry.pluginId;
    if (id == null) return;
    await _store.setDisabled(id, false);
    _registry.enable(id);
  }

  /// 打开插件自己的设置页（SDK04）。只有可用（已批准、已启用、证书未变）的插件才打开：
  /// 批准之前不启动插件任何代码，停用了就是用户不想让它再运行。
  Future<void> openSettings(PluginEntry entry) async {
    final package = entry.packageName;
    final activity = entry.settingsActivity;
    final current = package == null ? null : _entryOf(package);
    if (package == null ||
        activity == null ||
        current?.status != PluginStatus.ready ||
        current?.settingsActivity != activity) {
      throw const PluginApprovalRefused('这个插件现在不可用，不能打开它的设置页');
    }
    await _bridge.openSettings(package, activity);
  }

  /// [check] 新连上时的原话。
  static const checkPassed = '握手成功（插件核对了宿主证书），ping 往返正常';

  /// [check] 沿用已有连接时的原话。
  static const checkReused = '已经连着（之前握过手），沿用这条连接：ping 往返正常。没有重新握手，正在跑的会话不受影响';

  /// 连接测试：没连着就绑定 → 握手（插件核对宿主证书）→ ping；已经连着就只 ping，沿用那条连接。
  ///
  /// 为什么不每次重新握手：Kotlin 桥对一个插件只留一条连接，connect 会先断开旧的，连带关掉它正在跑的会话——
  /// 原来在详情页点一下「连接测试」，开着的 Mosh 标签就被断成「被停用、撤销」（X09 记下的坑）。
  /// 结果里的 reused 告诉调用方这条连接是不是它开的：不是它开的，离开页面时就不该断开。
  /// 不是 Ready 的在这里就返回原因，不绑定。
  Future<({bool ok, bool reused, String message})> check(
      PluginEntry entry) async {
    final id = entry.pluginId;
    final package = entry.packageName;
    final binding = entry.binding;
    if (entry.status != PluginStatus.ready ||
        id == null ||
        package == null ||
        binding == null ||
        entry.serviceClass == null) {
      return (
        ok: false,
        reused: false,
        message: '没有绑定插件：它现在不可用（${entry.reason ?? entry.status.name}）',
      );
    }
    final nonce = Random.secure().nextInt(1 << 31);
    try {
      final echoed = await _bridge.ping(package, nonce);
      // 连着的这条可能正有别的会话在用：答得不对也只报告，不替用户断开。
      return echoed == nonce
          ? (ok: true, reused: true, message: checkReused)
          : (ok: false, reused: true, message: 'ping 返回的值不对（沿用的连接，没有断开）');
    } on PluginBridgeException catch (e) {
      if (!const {'NOT_CONNECTED', 'DEAD', 'CLOSED'}.contains(e.code)) {
        return (ok: false, reused: true, message: '连接失败：${e.message}');
      }
    }
    try {
      await _bridge.connect(
        packageName: package,
        serviceClass: entry.serviceClass!,
        pluginId: id,
        sha256: binding.signingDigest,
      );
      final echoed = await _bridge.ping(package, nonce);
      if (echoed != nonce) {
        await _bridge.disconnect(package);
        return (ok: false, reused: false, message: 'ping 返回的值不对，已断开');
      }
      return (ok: true, reused: false, message: checkPassed);
    } on PluginBridgeException catch (e) {
      return (ok: false, reused: false, message: '连接失败：${e.message}');
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
