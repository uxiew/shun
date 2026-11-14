import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../application/home_navigation.dart';
import '../../application/settings_controller.dart';
import '../../application/tailscale_catalog_access.dart';
import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_provider.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../application/tailscale_key_input.dart';
import '../../application/vault_controller.dart';
import '../../domain/connection_route.dart';
import '../../domain/credential_identity.dart';
import '../../domain/models/host.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../../infrastructure/tailscale/catalog_cache_repository.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import '../ui/non_modal_panel.dart';
import '../widgets/catalog_text.dart';
import '../widgets/choice_segments.dart';
import '../widgets/connection_route_draft.dart';
import '../widgets/connection_route_editor.dart';
import '../widgets/credential_field.dart';
import '../widgets/form_gap.dart';
import '../widgets/hint.dart';
import '../widgets/proxy_profiles_page.dart';
import '../widgets/secret_content.dart';
import '../../domain/vault_secrets.dart';
import 'tailscale_catalog_screen.dart';

/// 设置页的结果：保存了哪个来源（新建时是新的 ID），或者来源被移除了。取消是 null。
typedef TailscaleSettingsResult = ({String catalogId, bool removed});

Future<TailscaleSettingsResult?> openTailscaleSettings(
  BuildContext context, {
  String? catalogId,
}) =>
    showTailscaleSettingsOn(Scaffold.of(context), catalogId: catalogId);

/// 非模态（所有者 11-02）：不盖遮罩，背后的列表照常能看能点；下滑、返回键、切底栏都关。
/// 代价是没保存的 key 跟着没了，剪贴板里一般还有，重新粘就行。面板本身见 ui/non_modal_panel.dart。
Future<TailscaleSettingsResult?> showTailscaleSettingsOn(
  ScaffoldState scaffold, {
  String? catalogId,
}) =>
    showNonModalPanel<TailscaleSettingsResult>(
      scaffold,
      builder: (_, close) => TailscaleSettingsScreen(
        catalogId: catalogId,
        onDone: close,
      ),
    );

/// Tailscale 设置（R26、R75，学 TermRover：浮在列表上的面板，常用的就两项；多了路线、地址类型和分组，都收进高级）。
///
/// 默认只有 API key 和默认登录（用户名或凭据）；「高级」里是端口、地址、路线、分组、tailnet，接第二个 tailnet 时还有名称。
/// 保存 = 存下这些导入默认值，填了 key（或本机存着 OAuth client）就马上读一次设备列表。
/// 只存设置，不导入、不连接：导入在设备列表里点一下，或「全部导入」。
class TailscaleSettingsScreen extends ConsumerStatefulWidget {
  const TailscaleSettingsScreen({
    super.key,
    this.catalogId,
    required this.onDone,
  });

  /// null：新建一个来源。
  final String? catalogId;

  /// 关掉面板。取消是 null。
  final ValueChanged<TailscaleSettingsResult?> onDone;

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

  /// 点了「修改」：掩码换成输入框。新填的 key 保存成功才替换旧的。
  bool _replacingKey = false;
  bool _loaded = false;
  bool _busy = false;
  String? _loadError;

  /// 这是本机唯一的来源（或正在建第一个）：不用起名，也不必让人知道有「来源」这回事。
  bool _onlySource = true;

  /// 面板底下那句话。不用 SnackBar：它弹在面板下面的页上，正好被面板挡住，保存失败了看着像没反应。
  ({String text, bool error})? _notice;

  /// 「高级」开没开。null：表单还没画出来过，第一次画时按路线坏没坏定（见 build）。
  bool? _advancedOpen;

  late var _sync = ref.read(settingsControllerProvider).tailscaleSyncSeconds;

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
      final sources = await repository.loadAll();
      _onlySource = sources.where((value) => value.catalogId != id).isEmpty;
      if (id == null) {
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

  static String _syncLabel(int seconds) => switch (seconds) {
        0 => '只在打开连接页时',
        < 60 => '$seconds 秒',
        _ => '${seconds ~/ 60} 分钟',
      };

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

  /// 收着的「高级」下面那一行：设过什么就写什么，不用点开就知道走不走代理。没设过就写里面有什么。
  String get _advancedSummary {
    final port = _port.text.trim();
    final set = [
      if (port != '22') '${localized('端口')} $port',
      if (_address == CatalogAddressKind.ipv6) 'IPv6',
      if (_address == CatalogAddressKind.fqdn) localized('MagicDNS 名称'),
      if (_route.selectedProxyProfileId != null) localized('代理'),
      if (_route.selectedJumpHostIds.isNotEmpty) localized('跳板机'),
      if (_group.text.trim().isNotEmpty) localized('分组'),
    ];
    return set.isEmpty ? localized('端口、连接路径、分组') : set.join(' · ');
  }

  /// 默认就看得见的两项哪里不成立。都对返回 null。
  String? _invalidBasics(VaultData? vault) {
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
    return null;
  }

  /// 「高级」里哪里不成立。都对返回 null。
  String? _invalidAdvanced(VaultData? vault) {
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
    final advanced = _invalidAdvanced(vault);
    final invalid = _invalidBasics(vault) ?? advanced;
    if (invalid != null) {
      // 错在收着的高级里就打开：不然底下说端口不对，面板上却找不到端口。
      if (advanced != null) _advancedOpen = true;
      _message(invalid);
      return;
    }
    final key = _key.text.trim();
    final input = key.isEmpty ? null : parseTailscaleKey(key);
    setState(() {
      _busy = true;
      _notice = null;
    });
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
      final settings = ref.read(settingsControllerProvider);
      if (settings.tailscaleSyncSeconds != _sync) {
        await ref
            .read(settingsControllerProvider.notifier)
            .update(settings.copyWith(tailscaleSyncSeconds: _sync));
      }
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
        // key 不对：留在本页，key 还在框里，改了再保存。
        // 只是这次没读到：key 已经存了（keepKeyAfter），框里换成「已保存」，说一声。
        if (outcome.error != null) {
          if (input != null && keepKeyAfter(outcome.error)) {
            _key.clear();
            _hasSaved = true;
            _replacingKey = false;
            _plainMessage('$report ${localized('key 已保存，之后自动再读。')}');
          } else {
            _plainMessage(report);
          }
          return;
        }
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(report)));
      }
      widget.onDone((catalogId: id, removed: false));
    } on Object catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetKey() async {
    final id = _catalogId;
    if (id == null) return;
    // key 看不回来，OAuth client 的 secret 在 Tailscale 后台也只显示一次：误点就得重新建，所以要问。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('删除保存的 key？'),
        content: const LText('删了找不回来，要用得重新填。'),
        actions: [
          ShunButton(
            key: const ValueKey('ts-settings-forget-key-cancel'),
            kind: ShunButtonKind.text,
            onPressed: () => Navigator.pop(context, false),
            label: '取消',
          ),
          ShunButton(
            key: const ValueKey('ts-settings-forget-key-confirm'),
            onPressed: () => Navigator.pop(context, true),
            label: '删除',
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _catalog.forgetCredentials(id);
    if (!mounted) return;
    setState(() {
      _hasSaved = false;
      _notice = (
        text: localized(
            '已删除本机保存的 key。它在 Tailscale 那边仍然有效，要彻底作废请到 Tailscale 后台撤销。'),
        error: false,
      );
    });
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
        title: LText(_onlySource ? '移除 Tailscale？' : '移除这个来源？'),
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
          ShunButton(
            key: const ValueKey('ts-settings-remove-cancel'),
            kind: ShunButtonKind.text,
            onPressed: () => Navigator.pop(context, false),
            label: '取消',
          ),
          ShunButton(
            key: const ValueKey('ts-settings-remove-confirm'),
            onPressed: () => Navigator.pop(context, true),
            label: _onlySource ? '移除 Tailscale' : '移除来源',
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _catalog.removeSource(id);
    if (mounted) widget.onDone((catalogId: id, removed: true));
  }

  void _cancelReplacingKey() => setState(() {
        _key.clear();
        _replacingKey = false;
        _notice = null;
      });

  /// 存着的 key 看不了，只能换或删（所有者 11-02）。这里根本没解密：圆点是写死的，长度也不漏。
  /// 留着 Material 的框（R89）：和下面的用户名框一个样子；也不能换成带 controller 的输入框，那就得有东西可填。
  Widget _savedKey(ThemeData theme) => InputDecorator(
        key: const ValueKey('ts-settings-saved-key'),
        decoration: LInputDecoration(
          labelText: 'API key',
          floatingLabelBehavior: FloatingLabelBehavior.always,
          helperText: '已加密保存，不能查看',
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('ts-settings-change-key'),
                tooltip: localized('修改'),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _replacingKey = true;
                          _notice = null;
                        }),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                key: const ValueKey('ts-settings-forget-key'),
                tooltip: localized('删除'),
                onPressed: _busy ? null : _forgetKey,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
        child: Text('••••••••••••', style: theme.textTheme.bodyLarge),
      );

  /// 接第二个 tailnet、看目录的细节都在这页。面板里不再开一层。
  void _openSources() {
    final navigator = Navigator.of(context);
    widget.onDone(null);
    unawaited(navigator.push(MaterialPageRoute<void>(
      builder: (_) => const TailscaleCatalogScreen(),
    )));
  }

  void _message(String value) => _plainMessage(localized(value));

  /// 已经翻译好、拼上了数据的提示。
  void _plainMessage(String value) {
    if (!mounted) return;
    setState(() => _notice = (text: value, error: true));
  }

  @override
  Widget build(BuildContext context) {
    final vaultState = ref.watch(vaultControllerProvider);
    final vault = vaultState.data;
    final theme = Theme.of(context);
    final colors = prism.Theme.of(context).colorScheme;
    final small = prism.AppTextStyle.subheadline
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    final blockTitle = prism.AppTextStyle.headline
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    final existing = _catalogId != null && _cache != null;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    final route = _routePreview(vault);
    final notice = _notice;
    // 表单第一次画出来时定一次：打开就是坏的（跳板删了、代理没了）就摆出来，别等点保存才知道。
    // 之后只跟用户的点按和保存时的报错走；没加载完不定，那时路线还是空的。
    final advancedOpen =
        _loaded ? (_advancedOpen ??= route.error != null) : false;
    ref.listen(homeTabProvider, (_, __) => widget.onDone(null));
    // API key 框在面板上：防截屏（R44）。面板按内容的高度来，展开高级放不下时中间滚，底下的按钮一直在。
    // 不用自己让键盘：面板是 Scaffold 的一格，Scaffold 已经把它顶到键盘上面了。
    return SecretContent(
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: LText(
                      'Tailscale 设置',
                      style: prism.AppTextStyle.headline
                          .of(context)
                          .copyWith(color: colors.onSurface),
                    ),
                  ),
                  const HintButton(
                    title: 'Tailscale 设置',
                    message:
                        '自动列出 tailnet 里的设备，点一下就导入并连接。只读设备列表：不开 VPN，手机要能到达设备（比如开着 Tailscale App）。',
                  ),
                ],
              ),
            ),
            if (_loadError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: LText(_loadError!),
              )
            else if (!_loaded)
              const LinearProgressIndicator()
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  children: [
                    if (_busy) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                    ],
                    if (_hasSaved && !_replacingKey)
                      _savedKey(theme)
                    else
                      // 留着 Material 的框，不用 ShunSecretField（R89）：那个带「显示」眼睛，这里不许回显。
                      TextField(
                        key: const ValueKey('ts-settings-key'),
                        controller: _key,
                        // 点「修改」才出现，光标直接进来。第一次填不抢焦点：一开面板就弹键盘会挡住别的项。
                        autofocus: _replacingKey,
                        // 一直遮着、不给「显示」：遮挡的框不能复制剪切，key 不会经剪贴板流出去（TSC09）。
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        onChanged: (_) => setState(() {}),
                        decoration: LInputDecoration(
                          labelText: 'API key',
                          hintText: 'tskey-…',
                          helperText: _replacingKey ? '填了替换旧的，不填不变' : null,
                          suffixIcon: const HintButton(
                            title: 'API key',
                            message:
                                '推荐 OAuth client（tskey-client-…）：在 Tailscale 后台 Settings → OAuth clients 创建，只勾 devices:core:read。访问令牌（tskey-api-…）也能用，但它带着你账号的全部权限。\n\n读成功就加密存在这台手机上：只有 shun 能解开，不进备份和同步。',
                          ),
                        ),
                      ),
                    if (_replacingKey)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ShunButton(
                          key: const ValueKey('ts-settings-cancel-change-key'),
                          kind: ShunButtonKind.text,
                          onPressed: _busy ? null : _cancelReplacingKey,
                          label: '取消修改',
                        ),
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
                        decoration: LInputDecoration(labelText: 'SSH 用户名（可选）'),
                      ),
                      // 有凭据之前选的默认私钥：照常生效，现在只能清掉，要用私钥就建成凭据。
                      if (keys.where((key) => key.id == _identity).firstOrNull
                          case final key?)
                        OwnKeyRow(
                          sshKey: key,
                          onDrop: () => setState(() => _identity = null),
                        ),
                    ],
                    // 不摆下拉框：多数人填用户名，多一个选择就是多一项要看的东西。凭据一点就换。
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ShunButton(
                        key: const ValueKey('ts-settings-login'),
                        kind: ShunButtonKind.text,
                        onPressed: () => setState(() {
                          _login = _usesCredential
                              ? LoginChoice.simple
                              : LoginChoice.credential;
                        }),
                        label: _usesCredential ? '改用用户名' : '改用凭据',
                      ),
                    ),
                    const FormGap(),
                    DropdownButtonFormField<int>(
                      key: const ValueKey('ts-settings-sync'),
                      initialValue: _sync,
                      decoration: LInputDecoration(labelText: '状态同步间隔'),
                      items: [
                        for (final seconds in tailscaleSyncChoices)
                          DropdownMenuItem(
                            value: seconds,
                            child: LText(_syncLabel(seconds)),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _sync = value ?? _sync),
                    ),
                    const SizedBox(height: 12),
                    // 一行 Prism 分组卡片（R89，写法同主机表单的「高级」）：读屏是带「已展开 / 已收起」的按钮，
                    // ⓘ 自成节点。收着时下面的字段不建出来，默认就只有两个输入框。
                    prism.ItemPositionProvider(
                      position: prism.ItemPosition.startAndEnd,
                      child: ShunListRow(
                        key: const ValueKey('ts-settings-advanced'),
                        title: '高级',
                        details: Text(
                          _advancedSummary,
                          key: const ValueKey('ts-settings-advanced-summary'),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const HintButton(
                              title: '高级',
                              message:
                                  '这些只用于以后导入的主机，已经导入的不动。密码不在这里填：每台第一次连接时问。',
                            ),
                            ExcludeSemantics(
                              child: Icon(
                                advancedOpen
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                              ),
                            ),
                          ],
                        ),
                        expanded: advancedOpen,
                        onTap: () =>
                            setState(() => _advancedOpen = !advancedOpen),
                      ),
                    ),
                    if (advancedOpen) ...[
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('ts-settings-port'),
                        controller: _port,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        decoration: LInputDecoration(labelText: 'SSH 端口'),
                      ),
                      const SizedBox(height: 16),
                      LText('用设备的哪个地址', style: blockTitle),
                      const SizedBox(height: 6),
                      // 不用 SegmentedButton（R89）：它每段在读屏里是两个节点，长的那段还会折行。
                      ChoiceSegments<CatalogAddressKind>(
                        key: const ValueKey('ts-settings-address'),
                        selected: _address,
                        onTap: (value) => setState(() => _address = value),
                        segments: const [
                          ChoiceSegment(
                            CatalogAddressKind.ipv4,
                            'IPv4',
                            key: ValueKey('ts-settings-address-ipv4'),
                          ),
                          ChoiceSegment(
                            CatalogAddressKind.ipv6,
                            'IPv6',
                            key: ValueKey('ts-settings-address-ipv6'),
                          ),
                          ChoiceSegment(
                            CatalogAddressKind.fqdn,
                            'MagicDNS 名称',
                            key: ValueKey('ts-settings-address-fqdn'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // 和主机编辑页同一句 ⓘ：两页共用路线编辑器，说明也只写一份译文。
                      HintTitle(
                        '连接路径',
                        style: blockTitle,
                        hint:
                            '手机 →（代理）→（跳板机）→ 目标。代理只用于手机连第一跳，之后由上一台跳板转发。跳板机要先存成普通 SSH 主机。',
                      ),
                      // 路线编辑器里几句散着的字（路线草稿、明文口令提醒、报错）各自成节点。
                      // 去掉这层：路线坏了时这三句并成一个节点，还排到「代理管理」前面去念（R89 清点实测）。
                      Semantics(
                        explicitChildNodes: true,
                        child: ConnectionRouteEditor(
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
                          onSelectProxy: (_) => selectRouteProxy(context, null),
                          onManageProxies: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const ProxyProfilesPage())),
                          onChanged: () => setState(() {}),
                        ),
                      ),
                      const FormGap(),
                      TextField(
                        key: const ValueKey('ts-settings-group'),
                        controller: _group,
                        onChanged: (_) => setState(() {}),
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
                        if (!_onlySource) ...[
                          const FormGap(),
                          TextField(
                            key: const ValueKey('ts-settings-name'),
                            controller: _name,
                            decoration: LInputDecoration(labelText: '名称（可选）'),
                          ),
                        ],
                      ],
                      if (existing)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ShunButton(
                            key: const ValueKey('ts-settings-sources'),
                            kind: ShunButtonKind.text,
                            onPressed: _busy ? null : _openSources,
                            label: '管理 tailnet',
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            if (notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                // 自成节点：不然这句并进最上面的标题，读成「Tailscale 设置 端口要在…」（迁移前就这样）。
                // liveRegion：话一出来读屏就念，不然点了保存像没反应。
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  child: Text(
                    notice.text,
                    key: const ValueKey('ts-settings-notice'),
                    style: prism.AppTextStyle.subheadline.of(context).copyWith(
                          color: notice.error ? colors.error : colors.onSurface,
                        ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  if (existing)
                    // 留着 Material 的红字按钮：ShunButton 没有危险样式（R96 统一看）。
                    TextButton(
                      key: const ValueKey('ts-settings-remove'),
                      onPressed: _busy ? null : _remove,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: LText(_onlySource ? '移除 Tailscale' : '移除来源'),
                    ),
                  const Spacer(),
                  ShunButton(
                    key: const ValueKey('ts-settings-cancel'),
                    kind: ShunButtonKind.text,
                    onPressed: _busy ? null : () => widget.onDone(null),
                    label: '取消',
                  ),
                  const SizedBox(width: 8),
                  // 忙的时候按钮自己转圈、不响应，读屏念「处理中」。
                  ShunButton(
                    key: const ValueKey('ts-settings-save'),
                    busy: _busy,
                    onPressed: !_loaded ? null : _save,
                    label: '保存',
                  ),
                ],
              ),
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
