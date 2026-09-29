import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/host.dart';
import '../domain/models/vault.dart';
import '../infrastructure/storage/vault_repository.dart';

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
      state = VaultState(
          unreadableSecrets: repository.unreadableSecrets, data: data);
    } catch (error) {
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
    state = VaultState(
        unreadableSecrets: repository.unreadableSecrets, data: loaded);
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
  /// 只覆盖本类里的主机写入；设置页导入、钥匙串、同步仍直接调 [replace]，不在队列里。
  Future<void> _serialHostWrite(Future<void> Function() write) {
    final result = _hostWrites.then((_) => write());
    _hostWrites = result.catchError((Object _) {});
    return result;
  }

  Future<void> upsertHost(HostProfile host) =>
      _serialHostWrite(() => _upsertHost(host));

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
}
