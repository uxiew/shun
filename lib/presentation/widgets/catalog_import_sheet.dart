import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../application/vault_controller.dart';
import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/models/vault.dart';
import '../../domain/route_description.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../localization/localized_widgets.dart';

/// 把选中的目录设备批量导入为主机。返回实际新建的台数，取消返回 null。
///
/// 只写保险库：不连接、不开 VPN、不记任何指纹（R13）。下方实时显示每台会怎么建、为什么跳过、
/// 连接时会走哪条路线——用的是和连接时同一个路线检查。
Future<int?> showCatalogImportSheet(
  BuildContext context, {
  required CatalogCache cache,
  required List<String> deviceIds,
}) =>
    Navigator.of(context).push<int>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CatalogImportPage(cache: cache, deviceIds: deviceIds),
    ));

enum _Route { direct, proxy, jump }

class CatalogImportPage extends ConsumerStatefulWidget {
  const CatalogImportPage({
    super.key,
    required this.cache,
    required this.deviceIds,
  });

  final CatalogCache cache;
  final List<String> deviceIds;

  @override
  ConsumerState<CatalogImportPage> createState() => _CatalogImportPageState();
}

class _CatalogImportPageState extends ConsumerState<CatalogImportPage> {
  final _username = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _group = TextEditingController();
  final _proxyHost = TextEditingController();
  final _proxyPort = TextEditingController();
  final _proxyUser = TextEditingController();
  final _proxyPassword = TextEditingController();
  CatalogAddressKind _address = CatalogAddressKind.ipv4;
  _Route _route = _Route.direct;

  /// 空串未选、`profile:<id>` 已保存的配置、`custom` 自定义。
  String _proxy = '';
  ProxyType _proxyType = ProxyType.socks5;
  bool _proxyEntry = false;
  final _jumps = <String>[];
  HostAuthMethod _auth = HostAuthMethod.auto;
  String? _keyId;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _username,
      _port,
      _group,
      _proxyHost,
      _proxyPort,
      _proxyUser,
      _proxyPassword,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _usesProxy =>
      _route == _Route.proxy || (_route == _Route.jump && _proxyEntry);

  CatalogImportOptions _options() => CatalogImportOptions(
        username: _username.text,
        port: int.tryParse(_port.text.trim()) ?? 0,
        address: _address,
        proxyProfileId: _usesProxy && _proxy.startsWith('profile:')
            ? _proxy.substring('profile:'.length)
            : null,
        proxyConfig: _usesProxy && _proxy == 'custom'
            ? ProxyConfig(
                type: _proxyType,
                host: _proxyHost.text.trim(),
                port: int.tryParse(_proxyPort.text.trim()) ?? 0,
                username: _proxyUser.text.trim(),
                password: _proxyPassword.text,
              )
            : null,
        jumpHostIds: _route == _Route.jump ? [..._jumps] : const [],
        authMethod: _auth,
        identityFileId: _auth == HostAuthMethod.password ? null : _keyId,
        group: _group.text,
      );

  ({CatalogImportResult? result, String? error}) _preview(
    VaultData vault,
    String Function() newId,
  ) {
    if (_route == _Route.jump && _jumps.isEmpty) {
      return (result: null, error: '选了「经跳板机」，但还没有添加跳板机。');
    }
    if (_usesProxy && _proxy.isEmpty) {
      return (result: null, error: '选一个代理：已保存的配置，或者自定义。');
    }
    try {
      return (
        result: buildCatalogImport(
          cache: widget.cache,
          deviceIds: widget.deviceIds,
          options: _options(),
          vault: vault,
          newId: newId,
        ),
        error: null,
      );
    } on CatalogImportInvalid catch (error) {
      return (result: null, error: error.message);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final controller = ref.read(vaultControllerProvider.notifier);
      final vault = await controller.ready();
      const uuid = Uuid();
      final preview = _preview(vault, uuid.v4);
      final result = preview.result;
      if (result == null || result.hosts.isEmpty) return;
      final added =
          await controller.addHosts(result.hosts, skip: alreadyImported);
      if (mounted) Navigator.of(context).pop(added.length);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: LText('$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(vaultControllerProvider).data;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    var previewIds = 0;
    final preview = vault == null
        ? (result: null, error: null)
        : _preview(vault, () => 'preview-${previewIds++}');
    final result = preview.result;
    final count = result?.hosts.length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const LText('导入为主机'),
        actions: [
          TextButton(
            key: const ValueKey('catalog-import-confirm'),
            onPressed: _saving || count == 0 ? null : _save,
            child: const LText('导入'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const LText('选中的设备按同一套设置建成新主机。只写进保险库：不连接、不启动 VPN，第一次连接时照常核对指纹。'),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('catalog-import-username'),
            controller: _username,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: localized('登录用户名'),
              helperText: localized('服务器上的 Unix 用户，比如 ubuntu。必须填，不会默认用 root。'),
              helperMaxLines: 2,
            ),
          ),
          // 用户名的提示有两行，贴着下一个输入框会压住它的浮动标签。
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('catalog-import-port'),
            controller: _port,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: localized('SSH 端口')),
          ),
          const SizedBox(height: 16),
          const LText('用设备的哪个地址'),
          const SizedBox(height: 4),
          SegmentedButton<CatalogAddressKind>(
            segments: [
              const ButtonSegment(
                value: CatalogAddressKind.ipv4,
                label: Text('IPv4'),
              ),
              const ButtonSegment(
                value: CatalogAddressKind.ipv6,
                label: Text('IPv6'),
              ),
              ButtonSegment(
                value: CatalogAddressKind.fqdn,
                label: LText('MagicDNS 名称'),
              ),
            ],
            selected: {_address},
            onSelectionChanged: (value) =>
                setState(() => _address = value.first),
          ),
          const SizedBox(height: 4),
          LText(
            '地址跟随目录：以后刷新时设备地址变了，这些主机的地址会跟着改；你手动改过的就不再跟随。',
            style: small,
          ),
          const SizedBox(height: 16),
          const LText('连接路径'),
          const SizedBox(height: 4),
          SegmentedButton<_Route>(
            segments: [
              ButtonSegment(value: _Route.direct, label: LText('直连')),
              ButtonSegment(value: _Route.proxy, label: LText('经代理')),
              ButtonSegment(value: _Route.jump, label: LText('经跳板机')),
            ],
            selected: {_route},
            onSelectionChanged: (value) => setState(() => _route = value.first),
          ),
          const SizedBox(height: 4),
          if (_route == _Route.direct)
            LText(
              '手机直接连设备地址。连 100.x 这类 Tailscale 地址，手机上要开着官方 Tailscale App——本 App 不会替你开。',
              style: small,
            ),
          if (_route == _Route.jump) ..._jumpFields(vault, small),
          if (_usesProxy) ..._proxyFields(vault, small),
          const SizedBox(height: 16),
          const LText('身份认证'),
          const SizedBox(height: 4),
          SegmentedButton<HostAuthMethod>(
            segments: [
              ButtonSegment(
                value: HostAuthMethod.auto,
                label: LText('自动'),
              ),
              ButtonSegment(
                value: HostAuthMethod.key,
                label: LText('私钥'),
              ),
            ],
            selected: {
              _auth == HostAuthMethod.password ? HostAuthMethod.auto : _auth,
            },
            onSelectionChanged: (value) => setState(() => _auth = value.first),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            key: const ValueKey('catalog-import-key'),
            initialValue: _keyId,
            decoration: InputDecoration(labelText: localized('SSH 私钥')),
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: LText('不指定'),
              ),
              for (final key in vault?.keys ?? const <SshKeyProfile>[])
                DropdownMenuItem<String?>(
                  value: key.id,
                  child: Text(key.label),
                ),
            ],
            onChanged: (value) => setState(() => _keyId = value),
          ),
          const SizedBox(height: 4),
          LText('密码不在这里批量填：导入后到各主机的编辑器里填。', style: small),
          const SizedBox(height: 12),
          TextField(
            controller: _group,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: localized('分组（可选）')),
          ),
          const SizedBox(height: 16),
          _previewCard(vault, preview.error, result, small),
        ],
      ),
    );
  }

  List<Widget> _jumpFields(VaultData? vault, TextStyle? small) {
    final candidates = [
      for (final host in vault?.hosts ?? const <HostProfile>[])
        if (host.protocol == HostProtocol.ssh && !_jumps.contains(host.id))
          host,
    ];
    String labelOf(String id) =>
        vault?.hosts.where((h) => h.id == id).firstOrNull?.label ?? id;
    return [
      LText('按连接顺序选保险库里的主机做跳板机，最多 3 台。', style: small),
      Wrap(
        spacing: 8,
        children: [
          for (final (index, id) in _jumps.indexed)
            InputChip(
              label: Text('${index + 1}. ${labelOf(id)}'),
              onDeleted: () => setState(() => _jumps.remove(id)),
            ),
        ],
      ),
      if (_jumps.length < maxJumpHosts)
        DropdownButtonFormField<String>(
          key: ValueKey('catalog-import-jump-${_jumps.length}'),
          initialValue: null,
          decoration: InputDecoration(labelText: localized('添加跳板机')),
          items: [
            for (final host in candidates)
              DropdownMenuItem(value: host.id, child: Text(host.label)),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _jumps.add(value));
          },
        ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _proxyEntry,
        onChanged: (value) => setState(() => _proxyEntry = value),
        title: const LText('先经代理连第一台跳板机（高级）'),
        subtitle: const LText('代理只用于手机连第一台跳板机；之后每一跳由上一跳转发，不再经过代理。'),
      ),
    ];
  }

  List<Widget> _proxyFields(VaultData? vault, TextStyle? small) => [
        DropdownButtonFormField<String>(
          key: const ValueKey('catalog-import-proxy'),
          initialValue: _proxy.isEmpty ? null : _proxy,
          decoration: InputDecoration(labelText: localized('代理')),
          items: [
            for (final profile
                in vault?.proxyProfiles ?? const <ProxyProfile>[])
              DropdownMenuItem(
                value: 'profile:${profile.id}',
                child: Text(profile.label),
              ),
            DropdownMenuItem(
              value: 'custom',
              child: LText('自定义 HTTP / SOCKS5 代理'),
            ),
          ],
          onChanged: (value) => setState(() => _proxy = value ?? ''),
        ),
        if ((vault?.proxyProfiles ?? const []).isEmpty)
          LText('还没有保存的代理配置（目前只能从桌面端导入）。可以选「自定义」。', style: small),
        if (_proxy == 'custom') ...[
          SegmentedButton<ProxyType>(
            segments: const [
              ButtonSegment(value: ProxyType.socks5, label: Text('SOCKS5')),
              ButtonSegment(value: ProxyType.http, label: Text('HTTP')),
            ],
            selected: {_proxyType},
            onSelectionChanged: (value) =>
                setState(() => _proxyType = value.first),
          ),
          TextField(
            key: const ValueKey('catalog-import-proxy-host'),
            controller: _proxyHost,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: localized('代理地址')),
          ),
          TextField(
            key: const ValueKey('catalog-import-proxy-port'),
            controller: _proxyPort,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: localized('代理端口')),
          ),
          TextField(
            controller: _proxyUser,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: localized('代理用户名（可选）')),
          ),
          TextField(
            controller: _proxyPassword,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: localized('代理密码（可选）')),
          ),
          LText(
            '代理的用户名和密码是明文发给代理的：SSH 只加密之后的终端会话，保护不了这段口令。',
            style: small,
          ),
        ],
      ];

  Widget _previewCard(
    VaultData? vault,
    String? error,
    CatalogImportResult? result,
    TextStyle? small,
  ) {
    final theme = Theme.of(context);
    final newHosts = localized('将新建主机：');
    final skipped = localized('跳过：');
    String? route;
    if (vault != null && result != null && result.hosts.isNotEmpty) {
      try {
        route = routeSummary(resolveRoutePlan(
          result.hosts.first,
          hosts: [...vault.hosts, ...result.hosts],
          proxyProfiles: vault.proxyProfiles,
          keys: vault.keys,
        ));
      } on RouteConfigException {
        route = null;
      }
    }
    return Card(
      key: const ValueKey('catalog-import-preview'),
      color: error == null ? null : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (error != null) LText(error),
            if (result != null) ...[
              if (route != null) ...[
                const LText('连接时会这样走'),
                LText(route, style: small),
                const SizedBox(height: 8),
              ],
              Text(
                '$newHosts${result.hosts.length}',
                style: theme.textTheme.titleSmall,
              ),
              for (final host in result.hosts)
                Text(
                  '${host.label}  →  ${host.username}@${host.hostname}:${host.port}',
                  style: small,
                ),
              if (result.skipped.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '$skipped${result.skipped.length}',
                  style: theme.textTheme.titleSmall,
                ),
                for (final skip in result.skipped)
                  Wrap(
                    children: [
                      Text('${skip.name}：', style: small),
                      LText(skip.reason, style: small),
                    ],
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
