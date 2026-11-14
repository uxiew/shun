import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../application/vault_controller.dart';
import '../../domain/connection_route.dart';
import '../../domain/credential_identity.dart';
import '../../domain/models/vault.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../localization/localized_widgets.dart';
import 'connection_route_draft.dart';
import 'credential_field.dart';
import 'connection_route_editor.dart';
import 'form_gap.dart';
import 'hint.dart';
import 'proxy_profiles_page.dart';
import '../../domain/vault_secrets.dart';

/// 把选中的目录设备按这一页的设置批量导入为主机（设备页 ⋮ 里的「用自定义设置导入」）。
/// 返回实际新建的台数，取消返回 null。平常点设备走 Tailscale 设置里的默认值，不经过这页（R26）。
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
  final _routeDraft = ConnectionRouteDraft.forCatalogImport();
  CatalogAddressKind _address = CatalogAddressKind.ipv4;
  LoginChoice _login = LoginChoice.simple;
  String? _credentialId;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _username,
      _port,
      _group,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _usesCredential => _login == LoginChoice.credential;

  CatalogImportOptions _options() => CatalogImportOptions(
        username: _username.text,
        port: int.tryParse(_port.text.trim()) ?? 0,
        address: _address,
        proxyProfileId: _routeDraft.selectedProxyProfileId,
        proxyConfig: _routeDraft.selectedProxyConfig,
        jumpHostIds: _routeDraft.selectedJumpHostIds,
        jumpRouteConfirmation: _routeDraft.confirmation,
        identityId: _usesCredential ? _credentialId : null,
        group: _group.text,
      );

  ({CatalogImportResult? result, String? error}) _preview(
    VaultData vault,
    String Function() newId,
  ) {
    if (_usesCredential) {
      if (!vaultIdentities(vault).any((item) => item.id == _credentialId)) {
        return (result: null, error: '选一个凭据，或者改成用户名 / 密码。');
      }
    } else if (_username.text.trim().isEmpty) {
      // 这一页是「统一设置一批」，还是要填用户名；不填用户名的导入走来源设置里的默认值（R26）。
      return (
        result: null,
        error: '要填登录用户名：目录不知道服务器上的 Unix 用户，不会默认用 root。',
      );
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
    final vaultState = ref.watch(vaultControllerProvider);
    final vault = vaultState.data;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    var previewIds = 0;
    final preview = vault == null
        ? (result: null, error: null)
        : _preview(vault, () => 'preview-${previewIds++}');
    final result = preview.result;
    final count = result?.hosts.length ?? 0;
    final routePlan = result != null && result.hosts.isNotEmpty && vault != null
        ? resolveRoutePlan(result.hosts.first,
            hosts: [...vault.hosts, ...result.hosts],
            proxyProfiles: vault.proxyProfiles,
            keys: vault.keys,
            identities: vaultIdentityMaps(vault))
        : null;
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
          const LText('选中的设备建成新主机，只存不连，第一次连接时照常核对指纹。'),
          const FormGap(),
          LoginChoiceField(
            key: const ValueKey('catalog-import-login'),
            value: _login,
            onChanged: (value) => setState(() => _login = value),
          ),
          const FormGap(),
          if (_usesCredential)
            CredentialField(
              key: const ValueKey('catalog-import-credential'),
              value: _credentialId,
              onChanged: (id) => setState(() => _credentialId = id),
            )
          else ...[
            TextField(
              key: const ValueKey('catalog-import-username'),
              controller: _username,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: localized('登录用户名'),
                helperText:
                    localized('必填，不会默认用 root'),
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 4),
            LText('密码不在这里批量填：导入后到各主机的编辑器里填。', style: small),
          ],
          // 用户名的提示有两行，贴着下一个输入框会压住它的浮动标签。
          const FormGap(),
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
            '以后刷新时地址跟着目录变，手动改过的不再跟。',
            style: small,
          ),
          const SizedBox(height: 16),
          // 和主机编辑页同一句 ⓘ：两页共用路线编辑器，说明也只写一份译文。
          const HintTitle(
            '连接路径',
            hint: '手机 →（代理）→（跳板机）→ 目标。代理只用于手机连第一跳，之后由上一台跳板转发。跳板机要先存成普通 SSH 主机。',
          ),
          ConnectionRouteEditor(
            canConfirmRoutes: !vaultState.loading &&
                vaultState.error == null &&
                !vaultState.unreadableSecrets.any((key) =>
                    key.startsWith('proxy.') || key.endsWith('.proxyPassword')),
            draft: _routeDraft,
            hosts: vault?.hosts ?? const [],
            profiles: vault?.proxyProfiles ?? const [],
            plan: routePlan,
            error: preview.error,
            targetLabel: localized('所选设备'),
            onSelectProxy: (inline) => selectRouteProxy(context, inline),
            onManageProxies: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ProxyProfilesPage())),
            onChanged: () => setState(() {}),
          ),
          const FormGap(),
          TextField(
            controller: _group,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: localized('分组（可选）')),
          ),
          const SizedBox(height: 16),
          _previewCard(preview.error, result, small),
        ],
      ),
    );
  }

  Widget _previewCard(
    String? error,
    CatalogImportResult? result,
    TextStyle? small,
  ) {
    final theme = Theme.of(context);
    final newHosts = localized('将新建主机：');
    final skipped = localized('跳过：');
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
