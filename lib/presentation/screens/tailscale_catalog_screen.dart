import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/catalog_overview.dart';
import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_provider.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../domain/models/server_stats.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../../infrastructure/tailscale/catalog_cache_repository.dart';
import '../localization/localized_widgets.dart';
import '../widgets/catalog_text.dart';
import '../widgets/connect_host.dart';
import '../widgets/hint.dart';
import '../widgets/host_system_icon.dart';
import 'tailscale_settings_screen.dart';

// 原来这几段常驻在页面上，现在收进 ⓘ（docs/dev/ui-text.md）；完整说明在使用手册第 13 节。
const _catalogAbout =
    '从 Tailscale 读设备列表，点一台就导入并连接。只读列表：不连设备、不开 VPN。手机要能到达设备（开着官方 Tailscale App，或经代理、跳板机）才连得上。';

const _importHint = '点一台就按 Tailscale 设置里的默认值连接，用户名、密码没填的连接时问。不想看到的点 ⋮ 隐藏。';

const _sharedDevicesNote =
    '用 OAuth client 读取时，别人共享给你的设备可能不在列表里（Tailscale 的已知问题 tailscale#16911），这不代表设备被删了。';

/// 几段说明逐句本地化再拼：拼好的整段在英文表里查不到。
String _paragraphs(List<String> sources) => sources.map(localized).join('\n\n');

/// 打开 Tailscale 设置：没有来源是新建，一个来源就打开它（填过的都在），多个才先进列表选。
Future<void> openTailscale(BuildContext context, WidgetRef ref) async {
  final sources = await ref.read(catalogCacheRepositoryProvider).loadAll();
  if (!context.mounted) return;
  if (sources.length > 1) {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const TailscaleCatalogScreen(),
    ));
  } else {
    await openTailscaleSettings(
      context,
      catalogId: sources.firstOrNull?.catalogId,
    );
  }
  // 设置页里可能建了来源、读过列表、删了 key、移除了来源。
  await ref.read(catalogOverviewProvider.notifier).reload();
}

/// Tailscale 设备目录（R13）：来源列表。
class TailscaleCatalogScreen extends ConsumerStatefulWidget {
  const TailscaleCatalogScreen({super.key});

  @override
  ConsumerState<TailscaleCatalogScreen> createState() =>
      _TailscaleCatalogScreenState();
}

class _TailscaleCatalogScreenState
    extends ConsumerState<TailscaleCatalogScreen> {
  final _scaffold = GlobalKey<ScaffoldState>();

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
      sources.sort((a, b) => catalogSourceName(a)
          .toLowerCase()
          .compareTo(catalogSourceName(b).toLowerCase()));
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
          // 预先填一个名字：不填就只能显示「未命名来源」，几个来源分不清，而来源建好后改不了名。
          _Field(label: localized('名称（可选）'), initial: _suggestedName()),
          _Field(
            label: 'tailnet',
            initial: '-',
            helper: localized('- 表示凭据所属的 tailnet'),
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

  /// 「Tailscale」，被占了就「Tailscale 2」「Tailscale 3」……
  String _suggestedName() {
    final taken = {
      for (final source in _sources ?? const <CatalogCache>[])
        catalogSourceName(source),
    };
    if (!taken.contains('Tailscale')) return 'Tailscale';
    var n = 2;
    while (taken.contains('Tailscale $n')) {
      n++;
    }
    return 'Tailscale $n';
  }

  /// 新建来源走 Tailscale 设置页（R26）：填 key、默认用户名，保存后读一次，再进它的设备页。
  Future<void> _add() async {
    final result = await showTailscaleSettingsOn(_scaffold.currentState!);
    if (result == null || result.removed || !mounted) {
      await _load();
      return;
    }
    await _load();
    if (mounted) await _open(result.catalogId);
  }

  /// 按主机里记着的来源 ID 在本机重建来源（DEV02 的修复路径）。只建空来源，不发请求、不改主机。
  Future<void> _restore(String catalogId) async {
    final source = await _askSource(
      title: '在本机恢复来源',
      confirm: '恢复来源',
      explain: '只在本机建一个空来源，不发请求、不改任何主机。再用同一个 tailnet 的凭据读一次，这些主机就重新对上目录。',
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
      key: _scaffold,
      appBar: AppBar(
        title: const LText('Tailscale 设备目录'),
        actions: const [
          HintButton(title: 'Tailscale 设备目录', message: _catalogAbout),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('catalog-add-source'),
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const LText('添加来源'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (_error != null) LText('读取来源失败：$_error'),
          if (sources == null && _error == null)
            const LinearProgressIndicator()
          else if (sources != null && sources.isEmpty)
            const LText('还没有目录来源'),
          for (final source in sources ?? const <CatalogCache>[])
            Card(
              child: ListTile(
                leading: const Icon(Icons.lan_outlined),
                title: Text(catalogSourceName(source)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (catalogSourceUnnamed(source))
                      catalogLine('ID：', source.catalogId),
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
            const HintTitle(
              '主机里引用了、本机没有的来源',
              hint: '来源被移除过，或主机是从别的手机同步、导入来的。这些主机照常能连，只是看不到目录状态、地址也不跟随目录。',
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

/// 一个目录来源的设备页：刷新、Tailscale 设置、设备列表（R26 按所有者反馈改过）。
///
/// - 点一台没导入的设备：按 Tailscale 设置里的默认值导入并连接；导入过的直接连那台主机。
/// - 「全部导入」把还没导入的都建成主机，不连接。
/// - ⋮ 里是「只导入，不连接」和「关联到已有主机」。
class CatalogSourceScreen extends ConsumerStatefulWidget {
  const CatalogSourceScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  ConsumerState<CatalogSourceScreen> createState() =>
      _CatalogSourceScreenState();
}

class _CatalogSourceScreenState extends ConsumerState<CatalogSourceScreen> {
  final _scaffold = GlobalKey<ScaffoldState>();

  CatalogCache? _cache;
  bool _hasSaved = false;
  bool _busy = false;
  String? _loadError;

  TailscaleCatalogProvider get _catalog => ref.read(tailscaleCatalogProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load().then((_) => _refreshIfDue()));
  }

  /// 打开这页时状态要新（R67）：够久没读就读一次，不打扰人，读完重画。这里的刷新键不受影响。
  Future<void> _refreshIfDue() async {
    final outcome = await ref
        .read(catalogOverviewProvider.notifier)
        .refreshIfDue(widget.catalogId);
    if (outcome != null && mounted) await _load();
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
      });
    } on Object catch (error) {
      if (mounted) setState(() => _loadError = '$error');
    }
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final outcome = await _catalog.refreshSaved(widget.catalogId);
      _plainMessage(catalogRefreshReport(outcome));
    } on Object catch (error) {
      _message('$error');
    } finally {
      await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _settings() async {
    final result = await showTailscaleSettingsOn(
      _scaffold.currentState!,
      catalogId: widget.catalogId,
    );
    if (!mounted) return;
    if (result?.removed == true) {
      Navigator.of(context).pop();
      return;
    }
    await _load();
  }

  Future<void> _setHidden(CatalogDeviceRecord record, bool hidden) async {
    try {
      await _catalog.setDeviceHidden(widget.catalogId, record.id,
          hidden: hidden);
      await _load();
    } on Object catch (error) {
      _message('$error');
    }
  }

  Future<void> _open(
      CatalogDeviceRecord record, List<HostProfile> linked) async {
    if (linked.isNotEmpty) {
      await connectHostFromList(context, linked.first, leavePushedPages: true);
    } else {
      await importAndConnect(context, widget.catalogId, record.id,
          leavePushedPages: true);
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: LText(value)));
  }

  /// 已经翻译好、拼上了数据的提示。
  void _plainMessage(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
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
    final now = DateTime.now();
    return Scaffold(
      key: _scaffold,
      appBar: AppBar(
        // 还没读到缓存时先空着，别闪一下内部 ID。
        title: Text(cache == null ? '' : catalogSourceName(cache)),
        actions: [
          if (_hasSaved)
            IconButton(
              key: const ValueKey('catalog-refresh-saved'),
              tooltip: localized('刷新'),
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            key: const ValueKey('catalog-settings'),
            tooltip: localized('Tailscale 设置'),
            onPressed: _busy ? null : _settings,
            icon: const Icon(Icons.tune),
          ),
        ],
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
                    if (!_hasSaved) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const ValueKey('catalog-open-settings'),
                        onPressed: _busy ? null : _settings,
                        icon: const Icon(Icons.key_outlined),
                        label: const LText('填 API key 读设备列表'),
                      ),
                    ],
                    if (_busy) ...[
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ],
                    const SizedBox(height: 16),
                    // 还没读过时上面的状态卡已经写了，这里不再说一遍。
                    if (devices.isEmpty && cache.lastSuccess != null)
                      const LText('列表里没有设备')
                    else if (devices.isNotEmpty) ...[
                      HintTitle(
                        '设备',
                        hint: _paragraphs([_importHint, _sharedDevicesNote]),
                      ),
                      for (final record in devices)
                        _deviceTile(record, linked[record.id], small, now),
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
            if (success == null)
              const LText('还没读过设备列表')
            else
              catalogLine('缓存时间：', catalogTime(success.at)),
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
            ],
            if (_hasSaved) const LText('已保存 key'),
          ],
        ),
      ),
    );
  }

  Widget _deviceTile(
    CatalogDeviceRecord record,
    List<HostProfile>? linkedHosts,
    TextStyle? small,
    DateTime now,
  ) {
    final device = record.device;
    final linked = linkedHosts ?? const <HostProfile>[];
    final canImport = linked.isEmpty && !record.missing;
    final hidden = _cache?.hiddenDevices.contains(record.id) ?? false;
    return ListTile(
      key: ValueKey('catalog-device-${record.id}'),
      contentPadding: EdgeInsets.zero,
      enabled: !_busy && (linked.isNotEmpty || canImport),
      onTap: () => _open(record, linked),
      leading: SystemIcon(
        distro: normalizeDistroId(device.os ?? ''),
        size: 40,
        label: device.os,
      ),
      title: Text(catalogDeviceName(record)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hidden) LText('已隐藏', style: small),
          PresenceLine(
            presence: deviceOnline(record),
            child: Text(
              device.addresses.isEmpty ? '—' : device.addresses.join('  '),
              style: small,
            ),
          ),
          Text(deviceOnlineText(record, now, statusAt: _cache?.lastSuccess?.at),
              style: small),
          if (record.missingSince != null)
            catalogLine('最近完整列表里没有它，标记于：', catalogTime(record.missingSince!),
                style: small),
          // 导入的主机地址由目录写入（appliedAddress 有值）；手动关联的从没由目录写过。
          for (final host in linked)
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                catalogLine(
                  CatalogBinding.of(host)?.appliedAddress == null
                      ? '已关联主机：'
                      : '已导入为主机：',
                  host.label,
                  style: small,
                ),
                if (host.lastConnectedAt > 0) LoggedInMark(style: small),
              ],
            ),
        ],
      ),
      trailing: linked.isEmpty
          ? PopupMenuButton<bool>(
              key: ValueKey('catalog-device-menu-${record.id}'),
              enabled: !_busy,
              onSelected: (next) => _setHidden(record, next),
              itemBuilder: (context) => [
                PopupMenuItem(
                  key: ValueKey('catalog-device-hide-${record.id}'),
                  value: !hidden,
                  child: LText(hidden ? '取消隐藏' : '隐藏'),
                ),
              ],
            )
          : null,
    );
  }
}

class _Field {
  const _Field({
    required this.label,
    this.initial = '',
    this.helper,
  });

  final String label;
  final String initial;
  final String? helper;
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
  Widget build(BuildContext context) {
    return AlertDialog(
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
              controller: _controllers[index],
              autocorrect: false,
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
}
