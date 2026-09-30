import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/tailscale_catalog_access.dart';
import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_provider.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../../infrastructure/tailscale/catalog_cache_repository.dart';
import '../../infrastructure/tailscale/tailscale_api.dart';
import '../localization/localized_widgets.dart';
import '../widgets/catalog_import_sheet.dart';
import '../widgets/catalog_text.dart';

const _catalogLimits = '目录只知道设备在不在 Tailscale 的列表里、有没有连上 Tailscale 控制面。'
    '它不知道手机能不能连到设备，也不知道设备开没开 SSH——这些要实际连接才知道。';

/// Tailscale 设备目录（R13）：来源列表。
class TailscaleCatalogScreen extends ConsumerStatefulWidget {
  const TailscaleCatalogScreen({super.key});

  @override
  ConsumerState<TailscaleCatalogScreen> createState() =>
      _TailscaleCatalogScreenState();
}

class _TailscaleCatalogScreenState
    extends ConsumerState<TailscaleCatalogScreen> {
  List<CatalogCache>? _sources;
  List<MissingCatalogSource> _missing = const [];
  String? _error;

  TailscaleCatalogProvider get _catalog => ref.read(tailscaleCatalogProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      // 复制一份再排序：还没有任何来源时仓库返回的是 const 空列表，原地排序会抛 Unsupported operation。
      final sources = [
        ...await ref.read(catalogCacheRepositoryProvider).loadAll()
      ];
      sources.sort((a, b) => (a.label ?? a.catalogId)
          .toLowerCase()
          .compareTo((b.label ?? b.catalogId).toLowerCase()));
      final missing = await _catalog.missingSources();
      if (mounted) {
        setState(() {
          _sources = sources;
          _missing = missing;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  /// 来源的名称和 tailnet。取消或 tailnet 不合规返回 null（不合规时已提示）。
  Future<(String?, String)?> _askSource({
    required String title,
    required String confirm,
    String? explain,
  }) async {
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => _FieldsDialog(
        title: title,
        confirm: confirm,
        explain: explain,
        fields: [
          _Field(label: localized('名称（可选）')),
          _Field(
            label: 'tailnet',
            initial: '-',
            helper: localized('填 - 表示「凭据所属的 tailnet」，一般不用改'),
          ),
        ],
      ),
    );
    if (values == null || !mounted) return null;
    final name = values[0];
    final net = values[1];
    if (net.isEmpty || RegExp(r'[\s/\x00-\x1f\x7f]').hasMatch(net)) {
      _message('tailnet 不能为空，也不能有空格或斜杠');
      return null;
    }
    return (name.isEmpty ? null : name, net);
  }

  Future<void> _add() async {
    final source = await _askSource(title: '添加目录来源', confirm: '添加');
    if (source == null) return;
    try {
      final cache = await _catalog.addSource(
        catalogId: _newCatalogId(),
        tailnet: source.$2,
        label: source.$1,
      );
      await _load();
      if (mounted) await _open(cache.catalogId);
    } on Object catch (error) {
      _message('$error');
    }
  }

  /// 按主机里记着的来源 ID 在本机重建来源（DEV02 的修复路径）。只建空来源，不发请求、不改主机。
  Future<void> _restore(String catalogId) async {
    final source = await _askSource(
      title: '在本机恢复来源',
      confirm: '恢复来源',
      explain: '按主机里记着的来源 ID 在本机重建一个空来源，不发请求、不改任何主机。'
          '之后用同一个 tailnet 的凭据读一次设备列表，这些主机就重新对上目录里的设备；'
          '读的是别的 tailnet，设备对不上，主机什么都不会被改。',
    );
    if (source == null) return;
    try {
      await _catalog.restoreSource(
        catalogId,
        tailnet: source.$2,
        label: source.$1,
      );
      await _load();
      if (mounted) await _open(catalogId);
    } on Object catch (error) {
      _message('$error');
    }
  }

  Future<void> _open(String catalogId) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CatalogSourceScreen(catalogId: catalogId),
    ));
    await _load();
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: LText(value)));
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    final small = Theme.of(context).textTheme.bodySmall;
    return Scaffold(
      appBar: AppBar(title: const LText('Tailscale 设备目录')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('catalog-add-source'),
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const LText('添加来源'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          const LText(
            '从 Tailscale 读取设备列表，选中的设备可以批量导入为主机。'
            '导入不会连接这些设备，也不会启动 VPN；要连上，手机得先能到达它们'
            '（比如开着官方 Tailscale App，或者经代理、跳板机）。',
          ),
          const SizedBox(height: 8),
          LText(_catalogLimits, style: small),
          const SizedBox(height: 12),
          if (_error != null) LText('读取来源失败：$_error'),
          if (sources == null && _error == null)
            const LinearProgressIndicator()
          else if (sources != null && sources.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LText(
                  '还没有目录来源。点「添加来源」，再用 Tailscale 的 token 或你自己的 OAuth client 读一次设备列表。'),
            ),
          for (final source in sources ?? const <CatalogCache>[])
            Card(
              child: ListTile(
                leading: const Icon(Icons.lan_outlined),
                title: Text(source.label ?? source.catalogId),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    catalogLine('tailnet：', source.tailnet),
                    catalogLine('设备数：', '${source.devices.length}'),
                    catalogLine(
                      '缓存时间：',
                      source.lastSuccess == null
                          ? '—'
                          : catalogTime(source.lastSuccess!.at),
                    ),
                  ],
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(source.catalogId),
              ),
            ),
          if (_missing.isNotEmpty) ...[
            const SizedBox(height: 16),
            const LText('主机里引用了、本机没有的来源'),
            LText(
              '来源被移除过，或主机是从别的手机同步、导入来的。这些主机照常能连，只是看不到目录状态、地址也不跟随目录。',
              style: small,
            ),
            for (final missing in _missing)
              Card(
                key: ValueKey('catalog-missing-${missing.catalogId}'),
                child: ListTile(
                  leading: const Icon(Icons.link_off),
                  title: Text(missing.catalogId),
                  subtitle: catalogLine(
                    '引用它的主机：',
                    missing.hosts.map((h) => h.label).join(', '),
                    style: small,
                  ),
                  trailing: TextButton(
                    key: ValueKey('catalog-restore-${missing.catalogId}'),
                    onPressed: () => _restore(missing.catalogId),
                    child: const LText('在本机恢复'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 本机给来源起的 ID：只用于文件名和凭据键，和 tailnet 名无关（两个来源都写 `-` 也各是各的，TSC10）。
String _newCatalogId() {
  final random = Random.secure();
  return 'ts-${List.generate(10, (_) => random.nextInt(36).toRadixString(36)).join()}';
}

/// 一个目录来源：刷新状态、读取入口、设备列表与批量导入。
class CatalogSourceScreen extends ConsumerStatefulWidget {
  const CatalogSourceScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  ConsumerState<CatalogSourceScreen> createState() =>
      _CatalogSourceScreenState();
}

class _CatalogSourceScreenState extends ConsumerState<CatalogSourceScreen> {
  CatalogCache? _cache;
  bool _hasSaved = false;
  bool _busy = false;
  String? _loadError;
  final _selected = <String>{};

  TailscaleCatalogProvider get _catalog => ref.read(tailscaleCatalogProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final cache =
          await ref.read(catalogCacheRepositoryProvider).load(widget.catalogId);
      final saved = await _catalog.hasSavedCredentials(widget.catalogId);
      if (!mounted) return;
      setState(() {
        _cache = cache;
        _hasSaved = saved;
        _loadError = cache == null ? '本机没有这个目录来源' : null;
        _selected
            .removeWhere((id) => !(cache?.devices.containsKey(id) ?? false));
      });
    } on Object catch (error) {
      if (mounted) setState(() => _loadError = '$error');
    }
  }

  Future<void> _run(Future<CatalogRefreshOutcome> Function() read) async {
    setState(() => _busy = true);
    try {
      final outcome = await read();
      _report(outcome);
    } on Object catch (error) {
      _message('$error');
    } finally {
      await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _report(CatalogRefreshOutcome outcome) {
    final error = outcome.error;
    if (error != null) {
      final head = localized('读取失败，缓存里的设备和主机都没动：');
      _message('$head${error.message}');
      return;
    }
    final read = localized('读取成功，设备数：');
    final moved = localized('跟着目录改了地址的主机：');
    final lines = <String>[
      '$read${outcome.cache.lastSuccess?.deviceCount ?? 0}',
      if (outcome.hostsReaddressed > 0) '$moved${outcome.hostsReaddressed}',
      if (outcome.scope == TokenScopeStatus.unverified)
        localized('服务器没有回报 token 的权限范围，无法确认它只能读设备。'),
      if (outcome.persistRefusal case final refusal?)
        localized(switch (refusal) {
          PersistRefusal.notRequested => '没有保存 OAuth client。',
          PersistRefusal.scopeUnverified =>
            '没有保存 OAuth client：服务器没有回报权限范围，无法确认它只能读设备。',
          PersistRefusal.scopeBroaderThanDevices =>
            '没有保存 OAuth client：它能读的不止设备。请在 Tailscale 后台新建一个只有 devices:core:read 的 client。',
        }),
    ];
    _message(lines.join('\n'));
  }

  Future<void> _readWithToken() async {
    final token = await _askSecret(
      title: '粘贴 token 读一次',
      explain: 'token 只用这一次，读完就丢，不保存。建议在 Tailscale 后台生成一个短期 token，用完删掉。',
      label: 'Access token',
    );
    if (token == null || token.isEmpty) return;
    await _run(() => _catalog.refreshWithToken(widget.catalogId, token));
  }

  Future<void> _readWithOAuth() async {
    final result = await showDialog<(String, String, bool)>(
      context: context,
      builder: (context) => const _OAuthClientDialog(),
    );
    if (result == null) return;
    final (id, secret, persist) = result;
    await _run(() => _catalog.refreshWithOAuthClient(
          widget.catalogId,
          OAuthClientCredential(clientId: id, clientSecret: secret),
          persist: persist,
        ));
  }

  Future<String?> _askSecret({
    required String title,
    required String explain,
    required String label,
  }) async {
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => _FieldsDialog(
        title: title,
        explain: explain,
        confirm: '读取',
        fields: [
          _Field(
            label: label,
            secret: true,
            key: const ValueKey('catalog-secret-field'),
          ),
        ],
      ),
    );
    return values?.single;
  }

  Future<void> _forgetCredentials() async {
    await _catalog.forgetCredentials(widget.catalogId);
    _message(
        '已删除本机保存的 OAuth client。它在 Tailscale 那边仍然有效，要彻底作废请到 Tailscale 后台撤销。');
    await _load();
  }

  Future<void> _removeSource() async {
    final vault = ref.read(vaultControllerProvider).data;
    final bound = [
      for (final host in vault?.hosts ?? const <HostProfile>[])
        if (CatalogBinding.of(host)?.catalogId == widget.catalogId) host,
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('移除这个来源？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LText('会删除本机的设备缓存和保存的 OAuth client。'),
            const SizedBox(height: 8),
            catalogLine('关联它的主机：', '${bound.length}'),
            const LText('这些主机都会保留，照常能连；编辑器里会显示「本机没有这个来源」。要删主机请到保险库逐台删。'),
            if (bound.isNotEmpty)
              const LText('以后想让它们重新对上目录，可以在目录页的「主机里引用了、本机没有的来源」里恢复这个来源。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const LText('移除来源'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _catalog.removeSource(widget.catalogId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _import() async {
    final cache = _cache;
    if (cache == null || _selected.isEmpty) return;
    final added = await showCatalogImportSheet(
      context,
      cache: cache,
      deviceIds: [
        for (final id in cache.devices.keys)
          if (_selected.contains(id)) id,
      ],
    );
    if (added == null || !mounted) return;
    setState(_selected.clear);
    final head = localized('已导入主机：');
    final tail = localized('。还没有连接过：第一次连接时照常核对服务器指纹。');
    _message('$head$added$tail');
  }

  /// 用户选一台已有主机和这台设备关联（DEV01：只有用户关联才形成关联）。只写绑定，不连接。
  Future<void> _linkExisting(CatalogDeviceRecord record) async {
    final hosts = [
      for (final host in ref.read(vaultControllerProvider).data?.hosts ??
          const <HostProfile>[])
        if (CatalogBinding.of(host) == null) host,
    ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    if (hosts.isEmpty) {
      _message('没有可以关联的主机：已经关联了目录设备的主机，要先在编辑器里断开。');
      return;
    }
    final hostId = await showDialog<String>(
      context: context,
      builder: (context) =>
          _LinkHostDialog(device: catalogDeviceName(record), hosts: hosts),
    );
    if (hostId == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _catalog.linkHost(
        hostId: hostId,
        catalogId: widget.catalogId,
        deviceId: record.id,
      );
      _message('已关联。主机的地址、用户名、端口、路线、指纹都没改，刷新也不会改它的地址。');
    } on Object catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: LText(value)));
  }

  @override
  Widget build(BuildContext context) {
    final cache = _cache;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hosts = ref.watch(vaultControllerProvider).data?.hosts ?? const [];
    // 一台设备应该只关联一台主机；从别的手机同步来的旧数据可能有两台，都列出来，不替用户挑。
    final linked = <String, List<HostProfile>>{};
    for (final host in hosts) {
      final binding = CatalogBinding.of(host);
      if (binding == null || binding.catalogId != widget.catalogId) continue;
      linked.putIfAbsent(binding.deviceId, () => []).add(host);
    }
    final devices = [...?cache?.devices.values];
    devices.sort((a, b) => catalogDeviceName(a)
        .toLowerCase()
        .compareTo(catalogDeviceName(b).toLowerCase()));
    return Scaffold(
      appBar: AppBar(
        title: Text(cache?.label ?? widget.catalogId),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) => switch (value) {
              'forget' => _forgetCredentials(),
              _ => _removeSource(),
            },
            itemBuilder: (context) => [
              if (_hasSaved)
                PopupMenuItem(
                  value: 'forget',
                  child: LText('删除本机保存的 OAuth client'),
                ),
              PopupMenuItem(
                value: 'remove',
                child: LText('移除这个来源'),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  key: const ValueKey('catalog-import-selected'),
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.download_outlined),
                  label: catalogLine('导入所选设备：', '${_selected.length}'),
                ),
              ),
            ),
      body: _loadError != null
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: LText(_loadError!),
            )
          : cache == null
              ? const LinearProgressIndicator()
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _statusCard(cache, small),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_hasSaved)
                          FilledButton.icon(
                            key: const ValueKey('catalog-refresh-saved'),
                            onPressed: _busy
                                ? null
                                : () => _run(() =>
                                    _catalog.refreshSaved(widget.catalogId)),
                            icon: const Icon(Icons.refresh),
                            label: const LText('刷新'),
                          ),
                        OutlinedButton(
                          key: const ValueKey('catalog-read-token'),
                          onPressed: _busy ? null : _readWithToken,
                          child: const LText('粘贴 token 读一次'),
                        ),
                        OutlinedButton(
                          key: const ValueKey('catalog-read-oauth'),
                          onPressed: _busy ? null : _readWithOAuth,
                          child: const LText('用 OAuth client 读取'),
                        ),
                      ],
                    ),
                    if (_busy) ...[
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ],
                    const SizedBox(height: 16),
                    if (devices.isEmpty)
                      const LText('缓存里还没有设备。读一次设备列表后会出现在这里。')
                    else ...[
                      const LText('勾选要导入的设备。已导入的不能再选，不会重复建主机。'),
                      LText(
                        '保险库里已经有这台机器的主机？点设备下面的「关联到已有主机」，不用再导入一台。',
                        style: small,
                      ),
                      for (final record in devices)
                        _deviceTile(record, linked[record.id], small),
                    ],
                  ],
                ),
    );
  }

  Widget _statusCard(CatalogCache cache, TextStyle? small) {
    final success = cache.lastSuccess;
    final attempt = cache.lastAttempt;
    // lastAttempt 每次读取都会覆盖（成功时和 lastSuccess 是同一条），所以它失败就是最近一次失败。
    // 不比时间先后：手机时钟被往回调过时，比较会把刚发生的失败藏起来。
    final failedLast = attempt != null && !attempt.ok;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            catalogLine('tailnet：', cache.tailnet),
            catalogLine(
                '缓存时间：', success == null ? '—' : catalogTime(success.at)),
            if (success == null) const LText('还没有成功读取过设备列表。'),
            // 列表不完整时只写一句：优先用缓存里记下的具体原因（几条无法识别、几个重复 ID），
            // 没有才用通用说法。两句一起显示是同一件事说两遍。
            if (success != null && (!success.complete || success.note != null))
              LText(
                success.note ?? '上次读到的列表不完整：没有据此把任何设备标成不见了。',
                key: success.complete
                    ? null
                    : const ValueKey('catalog-incomplete'),
                style: small,
              ),
            if (failedLast) ...[
              const SizedBox(height: 4),
              catalogLine('最近一次读取失败：', catalogTime(attempt.at)),
              if (attempt.note case final note?) LText(note, style: small),
              LText('缓存里的设备和主机都没动。', style: small),
            ],
            const SizedBox(height: 4),
            LText(
              _hasSaved
                  ? '本机保存了这个来源的 OAuth client，可以直接刷新。'
                  : '本机没有保存凭据：每次读取都要粘贴 token 或填 OAuth client。',
            ),
            const SizedBox(height: 4),
            LText(_catalogLimits, style: small),
            LText(
              '用 OAuth client 读取时，别人共享给你的设备可能不在列表里（Tailscale 的已知问题 tailscale#16911），这不代表设备被删了。',
              style: small,
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceTile(
    CatalogDeviceRecord record,
    List<HostProfile>? linkedHosts,
    TextStyle? small,
  ) {
    final device = record.device;
    final linked = linkedHosts ?? const <HostProfile>[];
    return CheckboxListTile(
      key: ValueKey('catalog-device-${record.id}'),
      contentPadding: EdgeInsets.zero,
      value: linked.isNotEmpty || _selected.contains(record.id),
      onChanged: linked.isNotEmpty
          ? null
          : (value) => setState(() => value == true
              ? _selected.add(record.id)
              : _selected.remove(record.id)),
      title: Text(catalogDeviceName(record)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            device.addresses.isEmpty ? '—' : device.addresses.join('  '),
            style: small,
          ),
          if (device.os != null) Text(device.os!, style: small),
          LText(controlPlaneText(device.connectedToControl), style: small),
          if (device.lastSeen != null)
            catalogLine('上次连控制面：', catalogTime(device.lastSeen!), style: small),
          if (record.missingSince != null)
            catalogLine('最近完整列表里没有它，标记于：', catalogTime(record.missingSince!),
                style: small),
          // 导入的主机地址由目录写入（appliedAddress 有值）；手动关联的从没由目录写过。
          for (final host in linked)
            catalogLine(
              CatalogBinding.of(host)?.appliedAddress == null
                  ? '已关联主机：'
                  : '已导入为主机：',
              host.label,
              style: small,
            ),
          if (linked.isEmpty && !record.missing)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: ValueKey('catalog-link-${record.id}'),
                onPressed: _busy ? null : () => _linkExisting(record),
                icon: const Icon(Icons.link),
                label: const LText('关联到已有主机'),
              ),
            ),
        ],
      ),
    );
  }
}

/// 选一台已有主机来关联。点主机即选定；上面写清楚关联会改什么、不会改什么。
class _LinkHostDialog extends StatelessWidget {
  const _LinkHostDialog({required this.device, required this.hosts});

  final String device;
  final List<HostProfile> hosts;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: catalogLine('关联设备：', device),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LText(
                '选一台已有主机。只记下它对应目录里的这台设备：主机的地址、用户名、端口、路线、指纹一概不改，'
                '刷新也不会改它的地址，也不会连接它。以后要断开，在主机编辑器里点「断开和目录的关联」。',
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final host in hosts)
                      ListTile(
                        key: ValueKey('catalog-link-host-${host.id}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(host.label),
                        subtitle: Text(host.username.isEmpty
                            ? host.hostname
                            : '${host.username}@${host.hostname}'),
                        onTap: () => Navigator.pop(context, host.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
        ],
      );
}

class _OAuthClientDialog extends StatefulWidget {
  const _OAuthClientDialog();

  @override
  State<_OAuthClientDialog> createState() => _OAuthClientDialogState();
}

class _OAuthClientDialogState extends State<_OAuthClientDialog> {
  final _id = TextEditingController();
  final _secret = TextEditingController();
  bool _persist = false;

  @override
  void dispose() {
    _id
      ..clear()
      ..dispose();
    _secret
      ..clear()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const LText('用 OAuth client 读取'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LText(
                '在 Tailscale 后台新建一个只勾 devices:core:read 的 OAuth client，把 ID 和 secret 填在这里。',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('catalog-oauth-id'),
                controller: _id,
                onChanged: (_) => setState(() {}),
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Client ID'),
              ),
              TextField(
                key: const ValueKey('catalog-oauth-secret'),
                controller: _secret,
                onChanged: (_) => setState(() {}),
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Client secret'),
              ),
              CheckboxListTile(
                key: const ValueKey('catalog-oauth-persist'),
                contentPadding: EdgeInsets.zero,
                value: _persist,
                onChanged: (value) => setState(() => _persist = value == true),
                title: const LText('保存到本机，以后直接刷新'),
                subtitle: const LText(
                  '只在服务器确认它只能读设备时才保存。存在和保险库分开的加密存储里；'
                  '在这里删除不等于在 Tailscale 那边作废。',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            // 两项都填了才能点：以前少填一项时按了没有任何反应，看着像卡住。
            onPressed: _id.text.trim().isEmpty || _secret.text.trim().isEmpty
                ? null
                : () => Navigator.pop(
                      context,
                      (_id.text.trim(), _secret.text.trim(), _persist),
                    ),
            child: const LText('读取'),
          ),
        ],
      );
}

class _Field {
  const _Field({
    required this.label,
    this.initial = '',
    this.helper,
    this.secret = false,
    this.key,
  });

  final String label;
  final String initial;
  final String? helper;

  /// 遮挡、关联想和自动更正：token、secret 用。遮挡的输入框不给复制和剪切（TSC09）。
  final bool secret;
  final Key? key;
}

/// 几个输入框的对话框，确认时按顺序返回去掉首尾空白的值。
///
/// 输入框的控制器由对话框自己持有、在它销毁时释放：在 showDialog 返回后就释放的话，
/// 关闭动画还在用它，会抛「TextEditingController was used after being disposed」。
class _FieldsDialog extends StatefulWidget {
  const _FieldsDialog({
    required this.title,
    required this.confirm,
    required this.fields,
    this.explain,
  });

  final String title;
  final String confirm;
  final String? explain;
  final List<_Field> fields;

  @override
  State<_FieldsDialog> createState() => _FieldsDialogState();
}

class _FieldsDialogState extends State<_FieldsDialog> {
  late final _controllers = [
    for (final field in widget.fields)
      TextEditingController(text: field.initial),
  ];

  @override
  void dispose() {
    // 先清空再释放：别让 token 留在输入框的缓冲里。
    for (final controller in _controllers) {
      controller
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: LText(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 说明和输入框之间要留空：输入框的浮动标签在框的上沿，贴着会压住说明的最后一行。
            if (widget.explain != null) ...[
              LText(widget.explain!),
              const SizedBox(height: 12),
            ],
            for (final (index, field) in widget.fields.indexed)
              TextField(
                key: field.key,
                controller: _controllers[index],
                obscureText: field.secret,
                autocorrect: false,
                enableSuggestions: !field.secret,
                decoration: InputDecoration(
                  labelText: field.label,
                  helperText: field.helper,
                  helperMaxLines: 2,
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, [
              for (final controller in _controllers) controller.text.trim(),
            ]),
            child: LText(widget.confirm),
          ),
        ],
      );
}
