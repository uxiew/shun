import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/host.dart';
import '../domain/models/vault.dart';
import '../domain/proxy_profiles.dart';
import '../infrastructure/storage/vault_repository.dart';
import 'vault_import.dart';

/// 确认导入期间本机保险库变了，没有写入任何东西。
class VaultChangedDuringImport implements Exception {
  const VaultChangedDuringImport();

  @override
  String toString() => '确认期间本机保险库有变化，没有导入。请重新选择文件导入。';
}

class VaultState {
  const VaultState({
    this.data,
    this.loading = false,
    this.error,
    this.unreadableSecrets = const {},
  });
  final VaultData? data;
  final bool loading;
  final Object? error;

  /// 解不开的凭据在安全存储里的键（见 VaultRepository.unreadableSecrets）。
  final Set<String> unreadableSecrets;
}

final vaultControllerProvider =
    StateNotifierProvider<VaultController, VaultState>((ref) {
  final controller = VaultController(ref.watch(vaultRepositoryProvider));
  unawaited(controller.load());
  return controller;
});

class VaultController extends StateNotifier<VaultState> {
  VaultController(this.repository)
      : super(
          VaultState(
            data: repository.loadVaultPreview(),
            loading: true,
          ),
        );
  final VaultRepository repository;
  Future<VaultData>? _activeLoad;

  Future<void> load() async {
    state = VaultState(
        unreadableSecrets: repository.unreadableSecrets,
        data: state.data,
        loading: true);
    final operation = repository.loadVault();
    _activeLoad = operation;
    try {
      // 先等加载完再取解不开的集合：参数按书写顺序求值，写在一个构造调用里会取到加载前的空集合。
      final data = await operation;
      // 加载要等系统安全存储，期间 controller 可能已被销毁（应用退出、测试结束），这时不能再写 state。
      if (!mounted) return;
      state = VaultState(
          unreadableSecrets: repository.unreadableSecrets, data: data);
    } catch (error) {
      if (!mounted) return;
      state = VaultState(
          unreadableSecrets: repository.unreadableSecrets,
          data: state.data ?? VaultData.empty(),
          error: error);
    } finally {
      if (identical(_activeLoad, operation)) _activeLoad = null;
    }
  }

  /// Waits for platform-backed secrets to be available before an operation
  /// that connects, edits, exports, or saves the vault.
  Future<VaultData> ready() async {
    final active = _activeLoad;
    if (active != null) return active;
    final data = state.data;
    if (!state.loading && state.error == null && data != null) return data;
    final loaded = await repository.loadVault();
    if (mounted) {
      state = VaultState(
          unreadableSecrets: repository.unreadableSecrets, data: loaded);
    }
    return loaded;
  }

  Future<void> replace(VaultData vault, {bool remote = false}) async {
    await repository.saveVault(vault, remote: remote);
    state = VaultState(
        unreadableSecrets: repository.unreadableSecrets, data: vault);
  }

  Future<void> _hostWrites = Future.value();

  /// 主机相关的写入排队执行。每次写入都是「读当前保险库 → 改 → 保存」，两次交叠时，
  /// 后保存的那次会用它读到的旧列表盖掉先保存的——比如用户刚保存的编辑被连接回写冲掉。
  /// 覆盖本类里的主机写入和导入；钥匙串、同步仍直接调 [replace]，不在队列里。
  Future<T> _serialHostWrite<T>(Future<T> Function() write) {
    final result = _hostWrites.then((_) => write());
    _hostWrites = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// 按用户在确认框里看到的 [shown] 导入，返回实际用的那份结论。
  ///
  /// 排在主机写入的队列里，写之前按此刻的保险库重算。确认框开着的时候本机保险库变了
  /// （比如在别处新加了一台主机），用户看到的「会删掉哪些」就不作数了：抛 [VaultChangedDuringImport]
  /// 让用户重新导入，而不是删掉他没在确认框里看到的东西。
  Future<VaultImportPlan> importVault(
    VaultImportPlan shown,
    VaultImportMode mode,
  ) =>
      _serialHostWrite(() async {
        final plan = planVaultImport(shown.incoming, await ready());
        if (plan.signature != shown.signature) {
          throw const VaultChangedDuringImport();
        }
        await replace(plan.result(mode));
        return plan;
      });

  /// Proxy writes share the host/import queue, so references cannot be lost to
  /// an overlapping host save. Expected snapshots prevent stale form writes.
  Future<void> saveProxyProfile(ProxyProfile profile,
          {ProxyProfile? expected}) =>
      _serialHostWrite(() async {
        final vault = await ready();
        final current = vault.proxyProfiles
            .where((value) => value.id == profile.id)
            .firstOrNull;
        if (!sameProxyProfile(current, expected)) {
          throw const ProxyProfileChanged();
        }
        validateProxyProfile(profile);
        final profiles = [...vault.proxyProfiles];
        final index = profiles.indexWhere((value) => value.id == profile.id);
        if (index < 0) {
          profiles.add(profile);
        } else {
          profiles[index] = profile;
        }
        await replace(vault.copyWith(proxyProfiles: profiles));
      });

  Future<void> deleteProxyProfile(ProxyDeletion shown) =>
      _serialHostWrite(() async {
        final vault = await ready();
        if (!shown.matches(vault)) throw const ProxyProfileChanged();
        // Keep references. The resolver rejects missing profiles before dialing.
        await replace(vault.copyWith(
            proxyProfiles: vault.proxyProfiles
                .where((value) => value.id != shown.profile.id)
                .toList()));
      });

  Future<void> upsertHost(HostProfile host) =>
      _serialHostWrite(() => _upsertHost(host));

  /// 一次加入多台新主机（目录批量导入），返回实际加入的。
  ///
  /// 在写入队列里按此刻的保险库判断：[skip] 返回 true 的不加（比如同一台设备在别处刚导入过），
  /// ID 已存在的也不加——这里只新建，绝不改写已有主机。
  Future<List<HostProfile>> addHosts(
    List<HostProfile> hosts, {
    bool Function(VaultData current, HostProfile host)? skip,
  }) =>
      _serialHostWrite(() async {
        final vault = await ready();
        final ids = {for (final host in vault.hosts) host.id};
        final now = DateTime.now().millisecondsSinceEpoch;
        final added = <HostProfile>[];
        for (final host in hosts) {
          if (ids.contains(host.id) || (skip?.call(vault, host) ?? false)) {
            continue;
          }
          ids.add(host.id);
          added.add(HostProfile({...host.data, 'updatedAt': now}));
        }
        if (added.isEmpty) return added;
        final all = [...vault.hosts, ...added];
        var groups = vault.customGroups;
        for (final host in added) {
          groups =
              _updatedGroups(groups, all, currentGroup: _normalizedGroup(host));
        }
        await replace(vault.copyWith(hosts: all, customGroups: groups));
        return added;
      });

  Future<void> _upsertHost(HostProfile host) async {
    final vault = await ready();
    final stamped = HostProfile({
      ...host.data,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    final hosts = [...vault.hosts];
    final index = hosts.indexWhere((value) => value.id == stamped.id);
    final previousGroup = index == -1 ? null : _normalizedGroup(hosts[index]);
    if (index == -1) {
      hosts.add(stamped);
    } else {
      hosts[index] = stamped;
    }
    await replace(
      vault.copyWith(
        hosts: hosts,
        customGroups: _updatedGroups(
          vault.customGroups,
          hosts,
          previousGroup: previousGroup,
          currentGroup: _normalizedGroup(stamped),
        ),
      ),
    );
  }

  Future<void> deleteHost(String id) => _serialHostWrite(() => _deleteHost(id));

  Future<void> _deleteHost(String id) async {
    final vault = await ready();
    final removedHost = vault.hosts.cast<HostProfile?>().firstWhere(
          (value) => value?.id == id,
          orElse: () => null,
        );
    final hosts = vault.hosts.where((value) => value.id != id).toList();
    await replace(
      vault.copyWith(
        hosts: hosts,
        customGroups: _updatedGroups(
          vault.customGroups,
          hosts,
          previousGroup:
              removedHost == null ? null : _normalizedGroup(removedHost),
        ),
      ),
    );
  }

  String? _normalizedGroup(HostProfile host) {
    final value = host.group?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  List<String> _updatedGroups(
    List<String> current,
    List<HostProfile> hosts, {
    String? previousGroup,
    String? currentGroup,
  }) {
    final groups = current
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: true);
    if (currentGroup != null && !groups.contains(currentGroup)) {
      groups.add(currentGroup);
    }
    if (previousGroup != null &&
        previousGroup != currentGroup &&
        !hosts.any((host) => _normalizedGroup(host) == previousGroup)) {
      groups.removeWhere((group) => group == previousGroup);
    }
    return groups.toSet().toList(growable: false);
  }

  Future<void> upsertSnippet(CommandSnippet snippet) async {
    final vault =
        state.data ?? repository.loadVaultPreview() ?? VaultData.empty();
    final snippets = [...vault.snippets];
    final index = snippets.indexWhere((value) => value.id == snippet.id);
    if (index < 0) {
      snippets.add(snippet);
    } else {
      snippets[index] = snippet;
    }
    await _replaceMetadata(vault.copyWith(snippets: snippets));
  }

  Future<void> deleteSnippet(String id) async {
    final vault =
        state.data ?? repository.loadVaultPreview() ?? VaultData.empty();
    await _replaceMetadata(
      vault.copyWith(
        snippets: vault.snippets
            .where((value) => value.id != id)
            .toList(growable: false),
      ),
    );
  }

  Future<void> _replaceMetadata(VaultData vault) async {
    final previous = state;
    state = VaultState(
        unreadableSecrets: repository.unreadableSecrets,
        data: vault,
        loading: previous.loading);
    try {
      await repository.saveVaultMetadata(vault);
    } on Object catch (error) {
      state = VaultState(
        unreadableSecrets: repository.unreadableSecrets,
        data: previous.data,
        loading: previous.loading,
        error: error,
      );
      rethrow;
    }
  }

  /// 记一笔最近连接时间。
  ///
  /// 只改保险库里此刻那份主机的 lastConnectedAt；主机已被删除就不写。以前拿连接开始时的
  /// 整份快照写回，连接期间用户改的配置会被改回去（NET10）。
  Future<void> markConnected(HostProfile host) => _serialHostWrite(() async {
        final vault = await ready();
        final index = vault.hosts.indexWhere((value) => value.id == host.id);
        if (index < 0) return;
        final hosts = [...vault.hosts];
        hosts[index] = hosts[index].copyWith(
          lastConnectedAt: DateTime.now().millisecondsSinceEpoch,
        );
        final next = vault.copyWith(hosts: hosts);
        // Connection recency is device-local telemetry in desktop Netcatty. Do
        // not schedule a cloud write just because a terminal was opened.
        await repository.saveVault(next, remote: true);
        state = VaultState(
            unreadableSecrets: repository.unreadableSecrets, data: next);
      });

  /// 只改一台主机的几个字段，基于保险库里此刻的那份；主机已被删除就什么都不做。
  ///
  /// 给连接产生的回写用（比如识别出的系统类型）：它们不能用连接开始时的旧快照盖掉用户期间的修改，
  /// 也不能把用户已经删掉的主机加回来（NET10）。
  Future<void> patchHost(String id, Map<String, Object?> fields) =>
      _serialHostWrite(() async {
        final vault = await ready();
        final index = vault.hosts.indexWhere((value) => value.id == id);
        if (index < 0) return;
        final hosts = [...vault.hosts];
        hosts[index] = HostProfile({
          ...hosts[index].data,
          ...fields,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        });
        await replace(vault.copyWith(hosts: hosts));
      });

  /// 按保险库里此刻的那份主机决定改不改：[change] 返回 null 就不写。
  ///
  /// 「先看再改」必须在同一次串行写里完成。比如目录刷新只在主机地址仍是上次自动写入的值时才更新它；
  /// 分两步做的话，用户恰好在中间改了地址，就会被刷新覆盖（R12）。
  Future<void> updateHost(
    String id,
    HostProfile? Function(HostProfile current) change,
  ) =>
      updateHostChecked(id, (current, _) => change(current));

  /// 同 [updateHost]，但 [change] 还能看到同一时刻的全部主机，用来做跨主机的检查
  /// ——比如一台目录设备只能关联一台主机（X05），分两步查的话中间可能被别处写进第二台。
  Future<void> updateHostChecked(
    String id,
    HostProfile? Function(HostProfile current, List<HostProfile> all) change,
  ) =>
      _serialHostWrite(() async {
        final vault = await ready();
        final index = vault.hosts.indexWhere((value) => value.id == id);
        if (index < 0) return;
        final next = change(vault.hosts[index], vault.hosts);
        if (next == null) return;
        final hosts = [...vault.hosts];
        hosts[index] = HostProfile({
          ...next.data,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        });
        await replace(vault.copyWith(hosts: hosts));
      });
}
