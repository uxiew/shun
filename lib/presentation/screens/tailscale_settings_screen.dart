import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_provider.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../application/tailscale_key_input.dart';
import '../../application/vault_controller.dart';
import '../../domain/connection_route.dart';
import '../../domain/credential_identity.dart';
import '../../domain/models/host.dart';
import '../../domain/models/vault.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../../infrastructure/tailscale/catalog_cache_repository.dart';
import '../localization/localized_widgets.dart';
import '../widgets/catalog_text.dart';
import '../widgets/connection_route_draft.dart';
import '../widgets/connection_route_editor.dart';
import '../widgets/credential_field.dart';
import '../widgets/form_gap.dart';
import '../widgets/hint.dart';
import '../widgets/proxy_profiles_page.dart';
import '../widgets/secret_content.dart';
import '../../domain/vault_secrets.dart';

/// 设置页的结果：保存了哪个来源（新建时是新的 ID），或者来源被移除了。取消是 null。
typedef TailscaleSettingsResult = ({String catalogId, bool removed});

Future<TailscaleSettingsResult?> openTailscaleSettings(
  BuildContext context, {
  String? catalogId,
}) =>
    Navigator.of(context).push<TailscaleSettingsResult>(MaterialPageRoute(
      fullscreenDialog: catalogId == null,
      builder: (_) => TailscaleSettingsScreen(catalogId: catalogId),
    ));

/// Tailscale 设置（R26，照 TermRover 的设置页，多了路线、地址类型、私钥和分组）。
///
/// 一页填完：API key、默认 SSH 用户名；「高级」里是端口、地址、路线、私钥、分组、tailnet 和名称。
/// 保存 = 存下这些导入默认值，填了 key（或本机存着 OAuth client）就马上读一次设备列表。
/// 只存设置，不导入、不连接：导入在设备列表里点一下，或「全部导入」。
class TailscaleSettingsScreen extends ConsumerStatefulWidget {
  const TailscaleSettingsScreen({super.key, this.catalogId});

  /// null：新建一个来源。
  final String? catalogId;

  @override
  ConsumerState<TailscaleSettingsScreen> createState() =>
      _TailscaleSettingsScreenState();
}

class _TailscaleSettingsScreenState
    extends ConsumerState<TailscaleSettingsScreen> {
  final _key = TextEditingController();
  final _username = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _group = TextEditingController();
  final _tailnet = TextEditingController(text: '-');
  final _name = TextEditingController();
  var _route = ConnectionRouteDraft.forCatalogImport();
  var _address = CatalogAddressKind.ipv4;
  String? _identity;

  /// 以后导入的主机默认怎么登录：只带用户名（密码每台第一次连接时问），或者共用一个凭据（F31）。
  var _login = LoginChoice.simple;
  String? _credentialId;

  /// 新建时第一次保存就有了；读取失败留在本页重试时不再建第二个来源。
  String? _catalogId;
  CatalogCache? _cache;
  bool _hasSaved = false;
  bool _loaded = false;
  bool _busy = false;
  String? _loadError;

  TailscaleCatalogProvider get _catalog => ref.read(tailscaleCatalogProvider);

  @override
  void initState() {
    super.initState();
    _catalogId = widget.catalogId;
    unawaited(_load());
  }

  @override
  void dispose() {
    // 先清空再释放：别让 key 留在输入框的缓冲里。
    _key.clear();
    for (final controller in [
      _key,
      _username,
      _port,
      _group,
      _tailnet,
      _name,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repository = ref.read(catalogCacheRepositoryProvider);
      final id = _catalogId;
      if (id == null) {
        final sources = await repository.loadAll();
        _name.text = _suggestedName(sources);
      } else {
        final cache = await repository.load(id);
        if (cache == null) throw StateError(localized('本机没有这个目录来源'));
        final saved = await _catalog.hasSavedCredentials(id);
        final defaults = CatalogImportDefaults.of(cache);
        _cache = cache;
        _hasSaved = saved;
        _username.text = defaults.username;
        _port.text = '${defaults.port}';
        _group.text = defaults.group;
        _address = defaults.address;
        _identity = defaults.identityFileId;
        _credentialId = defaults.identityId;
        if (_credentialId != null) _login = LoginChoice.credential;
        _route = ConnectionRouteDraft.forHost(HostProfile({
          if (defaults.proxyProfileId != null)
            'proxyProfileId': defaults.proxyProfileId,
          if (defaults.jumpHostIds.isNotEmpty)
            'hostChain': {
              'hostIds': defaults.jumpHostIds,
              if (defaults.jumpRouteConfirmation != null)
                jumpRouteConfirmationKey: defaults.jumpRouteConfirmation,
            },
        }));
        _tailnet.text = cache.tailnet;
        _name.text = cache.label ?? '';
      }
      if (mounted) setState(() => _loaded = true);
    } on Object catch (error) {
      if (mounted) setState(() => _loadError = '$error');
    }
  }

  /// 「Tailscale」，被占了就「Tailscale 2」「Tailscale 3」……来源建好后名字改不了，先给一个分得清的。
  String _suggestedName(List<CatalogCache> sources) {
    final taken = {for (final source in sources) catalogSourceName(source)};
    if (!taken.contains('Tailscale')) return 'Tailscale';
    var n = 2;
    while (taken.contains('Tailscale $n')) {
      n++;
    }
    return 'Tailscale $n';
  }

  CatalogImportDefaults _defaults() => CatalogImportDefaults(
        username: _usesCredential ? '' : _username.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 0,
        address: _address,
        proxyProfileId: _route.selectedProxyProfileId,
        jumpHostIds: _route.selectedJumpHostIds,
        jumpRouteConfirmation: _route.confirmation,
        identityFileId: _usesCredential ? null : _identity,
        identityId: _usesCredential ? _credentialId : null,
        group: _group.text.trim(),
      );

  bool get _usesCredential => _login == LoginChoice.credential;

  /// 用和连接时同一个函数检查路线：跳板不在了、代理配置删了，在这里就说。
  ({RoutePlan? plan, String? error}) _routePreview(VaultData? vault) {
    if (vault == null) return (plan: null, error: null);
    try {
      return (
        plan: resolveRoutePlan(
          _route.choiceTarget(null),
          hosts: vault.hosts,
          proxyProfiles: vault.proxyProfiles,
          keys: vault.keys,
          identities: vaultIdentityMaps(vault),
        ),
        error: null,
      );
    } on RouteConfigException catch (error) {
      return (plan: null, error: error.message);
    }
  }

  /// 设置哪里不成立。都对返回 null。
  String? _invalid(VaultData? vault) {
    final key = _key.text.trim();
    if (key.isNotEmpty) {
      if (parseTailscaleKey(key) case TailscaleKeyRejected(:final reason)) {
        return reason;
      }
    }
    if (_usesCredential) {
      final chosen = vault == null
          ? null
          : vaultIdentities(vault)
              .where((item) => item.id == _credentialId)
              .firstOrNull;
      if (chosen == null) return '选一个凭据，或者改成用户名 / 密码。';
    } else if (RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(_username.text.trim())) {
      return '用户名里不能有空格或控制字符。';
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) return '端口要在 1–65535 之间。';
    if (_catalogId == null) {
      final net = _tailnet.text.trim();
      if (net.isEmpty || RegExp(r'[\s/\x00-\x1f\x7f]').hasMatch(net)) {
        return 'tailnet 不能为空，也不能有空格或斜杠';
      }
    }
    return _routePreview(vault).error;
  }

  Future<void> _save() async {
    final vault = ref.read(vaultControllerProvider).data;
    final invalid = _invalid(vault);
    if (invalid != null) {
      _message(invalid);
      return;
    }
    final key = _key.text.trim();
    final input = key.isEmpty ? null : parseTailscaleKey(key);
    setState(() => _busy = true);
    try {
      var id = _catalogId;
      if (id == null) {
        final name = _name.text.trim();
        final created = await _catalog.addSource(
          catalogId: _newCatalogId(),
          tailnet: _tailnet.text.trim(),
          label: name.isEmpty ? null : name,
        );
        id = created.catalogId;
        _catalogId = id;
        _cache = created;
      }
      await _catalog.saveImportDefaults(id, _defaults().toJson());
      final outcome = switch (input) {
        TailscaleOAuthClientKey(:final credential) =>
          await _catalog.refreshWithOAuthClient(id, credential, persist: true),
        TailscaleAccessTokenKey(:final token) =>
          await _catalog.refreshWithToken(id, token, persist: true),
        _ when _hasSaved => await _catalog.refreshSaved(id),
        _ => null,
      };
      if (!mounted) return;
      if (outcome != null) {
        final report = catalogRefreshReport(outcome);
        // 读失败了（key 不对、网络不通）留在本页，key 还在框里，改了再保存。
        if (outcome.error != null) {
          _plainMessage(report);
          return;
        }
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(report)));
      }
      Navigator.of(context).pop((catalogId: id, removed: false));
    } on Object catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetKey() async {
    final id = _catalogId;
    if (id == null) return;
    await _catalog.forgetCredentials(id);
    if (!mounted) return;
    setState(() => _hasSaved = false);
    _message('已删除本机保存的 key。它在 Tailscale 那边仍然有效，要彻底作废请到 Tailscale 后台撤销。');
  }

  Future<void> _remove() async {
    final id = _catalogId;
    if (id == null) return;
    final bound = [
      for (final host in ref.read(vaultControllerProvider).data?.hosts ??
          const <HostProfile>[])
        if (CatalogBinding.of(host)?.catalogId == id) host,
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('移除这个来源？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LText('会删除本机的设备缓存和保存的 key。'),
            const SizedBox(height: 8),
            catalogLine('关联它的主机：', '${bound.length}'),
            if (bound.isNotEmpty) const LText('这些主机都保留，照常能连。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('取消'),
          ),
          FilledButton(
            key: const ValueKey('ts-settings-remove-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const LText('移除来源'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _catalog.removeSource(id);
    if (mounted) Navigator.of(context).pop((catalogId: id, removed: true));
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
    final vaultState = ref.watch(vaultControllerProvider);
    final vault = vaultState.data;
    final small = Theme.of(context).textTheme.bodySmall;
    final existing = _catalogId != null && _cache != null;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    final route = _routePreview(vault);
    // API key 框在页面上：整页防截屏（R44）。
    return SecretContent(
      child: Scaffold(
        appBar: AppBar(
          title: const LText('Tailscale 设置'),
          actions: const [
            HintButton(
              title: 'Tailscale 设置',
              message:
                  '自动列出 tailnet 里的设备，点一下就导入并连接。只读设备列表：不开 VPN，手机要能到达设备（比如开着 Tailscale App）。',
            ),
          ],
        ),
        bottomNavigationBar: !_loaded
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Row(
                    children: [
                      if (existing)
                        TextButton(
                          key: const ValueKey('ts-settings-remove'),
                          onPressed: _busy ? null : _remove,
                          style: TextButton.styleFrom(
                            foregroundColor:
                                Theme.of(context).colorScheme.error,
                          ),
                          child: const LText('移除来源'),
                        ),
                      const Spacer(),
                      TextButton(
                        key: const ValueKey('ts-settings-cancel'),
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        child: const LText('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('ts-settings-save'),
                        onPressed: _busy ? null : _save,
                        child: const LText('保存'),
                      ),
                    ],
                  ),
                ),
              ),
        body: _loadError != null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: LText(_loadError!),
              )
            : !_loaded
                ? const LinearProgressIndicator()
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_busy) ...[
                        const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                      ],
                      TextField(
                        key: const ValueKey('ts-settings-key'),
                        controller: _key,
                        // 一直遮着、不给「显示」：遮挡的框不能复制剪切，key 不会经剪贴板流出去（TSC09）。
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        onChanged: (_) => setState(() {}),
                        decoration: LInputDecoration(
                          labelText: 'API key',
                          hintText: 'tskey-…',
                          helperText: _hasSaved ? '已加密保存，不填就用它' : null,
                          suffixIcon: const HintButton(
                            title: 'API key',
                            message:
                                '推荐 OAuth client（tskey-client-…）：在 Tailscale 后台 Settings → OAuth clients 创建，只勾 devices:core:read。访问令牌（tskey-api-…）也能用，但它带着你账号的全部权限。\n\n读成功就加密存在这台手机上：只有 shun 能解开，不进备份和同步。',
                          ),
                        ),
                      ),
                      if (_hasSaved)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey('ts-settings-forget-key'),
                            onPressed: _busy ? null : _forgetKey,
                            icon: const Icon(Icons.key_off_outlined),
                            label: const LText('删除保存的 key'),
                          ),
                        ),
                      const FormGap(),
                      LoginChoiceField(
                        key: const ValueKey('ts-settings-login'),
                        value: _login,
                        onChanged: (value) => setState(() => _login = value),
                      ),
                      const FormGap(),
                      if (_usesCredential)
                        CredentialField(
                          key: const ValueKey('ts-settings-credential'),
                          value: _credentialId,
                          onChanged: (id) => setState(() => _credentialId = id),
                        )
                      else ...[
                        TextField(
                          key: const ValueKey('ts-settings-username'),
                          controller: _username,
                          autocorrect: false,
                          enableSuggestions: false,
                          onChanged: (_) => setState(() {}),
                          decoration:
                              LInputDecoration(labelText: 'SSH 用户名（可选）'),
                        ),
                        // 有凭据之前选的默认私钥：照常生效，现在只能清掉，要用私钥就建成凭据。
                        if (keys.where((key) => key.id == _identity).firstOrNull
                            case final key?)
                          OwnKeyRow(
                            sshKey: key,
                            onDrop: () => setState(() => _identity = null),
                          ),
                      ],
                      const SizedBox(height: 8),
                      ExpansionTile(
                        key: const ValueKey('ts-settings-advanced'),
                        tilePadding: EdgeInsets.zero,
                        childrenPadding:
                            const EdgeInsets.only(top: 8, bottom: 8),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        title: const HintTitle(
                          '高级',
                          hint: '这些只用于以后导入的主机，已经导入的不动。密码不在这里填：每台第一次连接时问。',
                        ),
                        children: [
                          TextField(
                            key: const ValueKey('ts-settings-port'),
                            controller: _port,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
                            decoration: LInputDecoration(labelText: 'SSH 端口'),
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
                          const SizedBox(height: 16),
                          // 和主机编辑页同一句 ⓘ：两页共用路线编辑器，说明也只写一份译文。
                          const HintTitle(
                            '连接路径',
                            hint:
                                '手机 →（代理）→（跳板机）→ 目标。代理只用于手机连第一跳，之后由上一台跳板转发。跳板机要先存成普通 SSH 主机。',
                          ),
                          ConnectionRouteEditor(
                            canConfirmRoutes: !vaultState.loading &&
                                vaultState.error == null &&
                                !vaultState.unreadableSecrets.any((key) =>
                                    key.startsWith('proxy.') ||
                                    key.endsWith('.proxyPassword')),
                            draft: _route,
                            hosts: vault?.hosts ?? const [],
                            profiles: vault?.proxyProfiles ?? const [],
                            // 这条路线是拿占位目标算的，只用来查错：拿来画的话，目标会显示 route@route-edit.invalid。
                            plan: null,
                            error: route.error,
                            targetLabel: localized('Tailscale 设备'),
                            targetDetail: '',
                            // 只能选已保存的代理：自定义代理带口令，不写进目录设置。
                            onSelectProxy: (_) =>
                                selectRouteProxy(context, null),
                            onManageProxies: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const ProxyProfilesPage())),
                            onChanged: () => setState(() {}),
                          ),
                          const FormGap(),
                          TextField(
                            key: const ValueKey('ts-settings-group'),
                            controller: _group,
                            decoration: LInputDecoration(labelText: '分组（可选）'),
                          ),
                          const FormGap(),
                          if (existing)
                            catalogLine('tailnet：', _tailnet.text, style: small)
                          else ...[
                            TextField(
                              key: const ValueKey('ts-settings-tailnet'),
                              controller: _tailnet,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: LInputDecoration(
                                labelText: 'tailnet',
                                helperText: '- 表示凭据所属的 tailnet',
                              ),
                            ),
                            const FormGap(),
                            TextField(
                              key: const ValueKey('ts-settings-name'),
                              controller: _name,
                              decoration: LInputDecoration(labelText: '名称（可选）'),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
      ),
    );
  }
}

/// 本机给来源起的 ID：只用于文件名和凭据键，和 tailnet 名无关（两个来源都写 `-` 也各是各的，TSC10）。
String _newCatalogId() {
  final random = Random.secure();
  return 'ts-${List.generate(10, (_) => random.nextInt(36).toRadixString(36)).join()}';
}
