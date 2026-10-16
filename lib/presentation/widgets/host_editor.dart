import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/plugin_discovery.dart';
import '../../application/plugin_host_session.dart';
import '../../application/plugin_registry.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../application/vault_controller.dart';
import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/models/vault.dart';
import '../../domain/plugins/mosh_route.dart';
import '../../domain/plugins/plugin_host.dart';
import '../../domain/tailscale_ssh.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import 'catalog_source_section.dart';
import 'connection_probe_sheet.dart';
import 'keychain_sheet.dart';
import 'route_legs_view.dart';
import 'connection_route_draft.dart';
import 'connection_route_editor.dart';
import 'proxy_profiles_page.dart';
import 'unsupported_connection_page.dart';
import 'connection_endpoint_fields.dart';

class HostEditor extends ConsumerStatefulWidget {
  const HostEditor({
    super.key,
    this.host,
    this.initialProtocol = HostProtocol.ssh,
    this.initialPluginId,
    this.onDelete,
    this.verifyHostKey,
    this.keyboardInteractive,
  });

  final HostProfile? host;
  final HostProtocol initialProtocol;
  final String? initialPluginId;
  final Future<bool> Function()? onDelete;

  /// 测试连接用的指纹核对和交互式登录。和正式连接用同一套，测试不能绕过指纹确认。
  /// 不传（比如测试环境）就不显示「测试连接」。
  final HostKeyVerifier? verifyHostKey;
  final KeyboardInteractiveHandler? keyboardInteractive;

  @override
  ConsumerState<HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends ConsumerState<HostEditor> {
  late final bool _unsupported;
  final _form = GlobalKey<FormState>();
  late final TextEditingController label;
  late final TextEditingController hostname;
  late final TextEditingController username;
  late final TextEditingController port;
  late final TextEditingController password;
  late final TextEditingController group;
  late final TextEditingController tags;
  late final TextEditingController startupCommand;
  late final TextEditingController keepalive;
  late final TextEditingController connectTimeout;
  late final TextEditingController authTimeout;
  late final TextEditingController moshPorts;
  late final TextEditingController moshServerPath;
  late final TextEditingController moshLocale;
  late final ConnectionRouteDraft route;
  late HostProtocol protocol;
  late HostAuthMethod authMethod;
  late SshLoginMode loginMode;
  String? identityFileId;
  bool obscurePassword = true;
  bool pinned = false;

  /// 用户点了「断开和目录的关联」：保存时去掉关联字段，主机本身留着（R13）。
  bool unlinkCatalog = false;

  /// 协议选「插件」时用哪个插件（X12）。只存 pluginId，证书由插件页的批准记录绑定。
  String? pluginId;

  /// 打开时的草稿。和当前草稿不同就是有没保存的改动，离开要问（R41）。
  late final String _initialSnapshot;

  /// 最近一次测试连接成功时的 [_signature]；没测过或没成功为 null。
  String? _verifiedSignature;

  /// 高级里展开着的组。
  late final Set<String> _expanded;

  static const _defaultKeepalive = 10;
  static const _defaultConnectTimeout = 15;
  static const _defaultAuthTimeout = 30;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    _unsupported = host?.protocol == HostProtocol.unknown;
    if (_unsupported) return;
    route = ConnectionRouteDraft.forHost(host);
    label = TextEditingController(text: host?.label);
    hostname = TextEditingController(text: host?.hostname);
    username = TextEditingController(text: host?.username);
    port = TextEditingController(
      text: (host?.port ??
              (widget.initialProtocol == HostProtocol.telnet ? 23 : 22))
          .toString(),
    );
    password = TextEditingController(text: host?.password);
    group = TextEditingController(text: host?.group);
    tags = TextEditingController(text: host?.tags.join(', '));
    startupCommand = TextEditingController(text: host?.startupCommand);
    // 和默认值一样就留空、显示「自动」：预填的数字看着像用户自己填的（R41）。保存时空着就写默认值。
    String seconds(String key, int fallback) {
      final value = (host?.data[key] as num?)?.toInt();
      return value == null || value == fallback ? '' : '$value';
    }

    keepalive = TextEditingController(
      text: seconds('keepaliveInterval', _defaultKeepalive),
    );
    connectTimeout = TextEditingController(
      text: seconds('sshTcpConnectTimeoutSeconds', _defaultConnectTimeout),
    );
    authTimeout = TextEditingController(
      text: seconds('sshAuthReadyTimeoutSeconds', _defaultAuthTimeout),
    );
    moshPorts = TextEditingController(
      text: host?.data[moshPortsKey]?.toString() ?? '',
    );
    moshServerPath = TextEditingController(
      text: host?.data[moshServerPathKey]?.toString() ?? '',
    );
    moshLocale = TextEditingController(
      text: host?.data[moshLocaleKey]?.toString() ?? '',
    );
    protocol = host?.protocol ?? widget.initialProtocol;
    authMethod = host?.authMethod ?? HostAuthMethod.auto;
    loginMode = host == null ? SshLoginMode.standard : sshLoginModeOf(host);
    identityFileId = host?.identityFileId;
    pinned = host?.pinned ?? false;
    pluginId = host == null ? widget.initialPluginId : pluginIdOf(host);
    // App 启动时不自动发现插件（X04）：编辑器里要列出能选的插件，先让发现跑一次。
    unawaited(
        ref.read(pluginHostDiscoveryProvider.future).catchError((Object _) {}));
    // 路线摘要、验证状态和「有没保存的改动」都跟着输入实时更新。
    for (final controller in _controllers) {
      controller.addListener(_refresh);
    }
    _expanded = _filledGroups();
    _initialSnapshot = jsonEncode(_draft().data);
  }

  List<TextEditingController> get _controllers => [
        label,
        hostname,
        username,
        port,
        password,
        group,
        tags,
        startupCommand,
        keepalive,
        connectTimeout,
        authTimeout,
        moshPorts,
        moshServerPath,
        moshLocale,
      ];

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_unsupported) {
      super.dispose();
      return;
    }
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unsupported) {
      return UnsupportedConnectionPage(label: widget.host!.label);
    }
    final vaultState = ref.watch(vaultControllerProvider);
    final vault = vaultState.data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    final profiles = vault?.proxyProfiles ?? const <ProxyProfile>[];
    if (identityFileId != null &&
        !keys.any((value) => value.id == identityFileId)) {
      identityFileId = null;
    }
    final preview = _preview(vault);

    final sshLike =
        protocol == HostProtocol.ssh || protocol == HostProtocol.mosh;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          leading: IconButton(
            tooltip: localized('取消'),
            onPressed: _leave,
            icon: const Icon(Icons.close),
          ),
          title: LText(widget.host == null ? '新建连接' : '编辑连接'),
        ),
        bottomNavigationBar: _bottomBar(preview),
        body: Form(
          key: _form,
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              _section('基本信息'),
              TextFormField(
                controller: label,
                decoration: LInputDecoration(labelText: '名称'),
                validator: _required,
              ),
              // 插件主机没有地址、端口、用户名：连哪里由插件自己的设置页决定，本 App 不交给它任何主机数据。
              if (protocol != HostProtocol.plugin)
                ConnectionEndpointFields(
                  protocol: protocol,
                  hostname: hostname,
                  username: username,
                  port: port,
                ),
              const SizedBox(height: 12),
              TextFormField(
                controller: group,
                decoration: LInputDecoration(labelText: '分组（可选）'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: tags,
                decoration: LInputDecoration(labelText: '标签（逗号分隔）'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const LText('置顶显示'),
                value: pinned,
                onChanged: (value) => setState(() => pinned = value),
              ),
              if (protocol == HostProtocol.plugin) ..._pluginSection(),
              if (protocol == HostProtocol.telnet) ...[
                _section('连接路径'),
                const LText(
                  'Telnet 只支持直连，不能经代理或跳板机；保存时会去掉这台主机上的代理和跳板设置。',
                  key: ValueKey('telnet-direct-only'),
                ),
                _routePreview(preview),
              ],
              if (sshLike) ...[
                _section('认证'),
                _authSelector(),
                const SizedBox(height: 12),
                if (loginMode == SshLoginMode.tailscale)
                  _tailscaleLoginNote(preview.plan)
                else
                  ..._credentialFields(keys),
                _section('连接路径'),
                ConnectionRouteEditor(
                  canConfirmRoutes: !vaultState.loading &&
                      vaultState.error == null &&
                      !vaultState.unreadableSecrets.any((key) =>
                          key.startsWith('proxy.') ||
                          key.endsWith('.proxyPassword')),
                  draft: route,
                  hosts: vault?.hosts ?? const [],
                  profiles: profiles,
                  targetHostId: widget.host?.id,
                  plan: preview.plan,
                  error: preview.error,
                  warnings: preview.warnings,
                  targetLabel: label.text,
                  targetDetail:
                      '${username.text}@${hostname.text}:${port.text}',
                  onSelectProxy: (inline) => selectRouteProxy(context, inline),
                  onManageProxies: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ProxyProfilesPage())),
                  onChanged: _refresh,
                ),
                if (widget.host case final host?
                    when CatalogBinding.of(host) != null)
                  CatalogSourceSection(
                    host: host,
                    currentHostname: hostname.text.trim(),
                    unlinked: unlinkCatalog,
                    onUnlinkChanged: (value) =>
                        setState(() => unlinkCatalog = value),
                  ),
              ],
              ..._protocolSection(),
              if (sshLike) ...[
                _section('高级'),
                ..._advancedGroups(),
              ],
              if (widget.host != null && widget.onDelete != null) ...[
                const SizedBox(height: 28),
                OutlinedButton.icon(
                  key: const ValueKey('delete-host-from-editor'),
                  onPressed: _delete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const LText('删除此服务器'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 「认证」一行：普通 SSH 的三种认证方式和 Tailscale SSH 并成一个选择（R41）。
  /// 选 Tailscale SSH 时原来的认证方式留着，改回普通 SSH 照常用。
  Widget _authSelector() => DropdownButtonFormField<String>(
        key: const ValueKey('ssh-login-mode'),
        initialValue:
            loginMode == SshLoginMode.tailscale ? 'tailscale' : authMethod.name,
        isExpanded: true,
        decoration: LInputDecoration(labelText: '认证方式'),
        items: const [
          DropdownMenuItem(
            value: 'auto',
            child: LText('自动（私钥 / 密码 / 交互式）'),
          ),
          DropdownMenuItem(value: 'password', child: LText('密码')),
          DropdownMenuItem(value: 'key', child: LText('私钥')),
          DropdownMenuItem(value: 'tailscale', child: LText('Tailscale SSH')),
        ],
        onChanged: (value) => setState(() {
          if (value == 'tailscale') {
            loginMode = SshLoginMode.tailscale;
          } else {
            loginMode = SshLoginMode.standard;
            authMethod = HostAuthMethod.values.byName(value ?? 'auto');
          }
        }),
      );

  List<Widget> _credentialFields(List<SshKeyProfile> keys) => [
        TextFormField(
          controller: password,
          obscureText: obscurePassword,
          decoration: LInputDecoration(
            labelText: '密码（可选）',
            suffixIcon: IconButton(
              onPressed: () =>
                  setState(() => obscurePassword = !obscurePassword),
              icon: Icon(
                obscurePassword ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: identityFileId,
                decoration: LInputDecoration(labelText: 'SSH 私钥'),
                items: [
                  const DropdownMenuItem(value: '', child: LText('不指定')),
                  for (final key in keys)
                    DropdownMenuItem(value: key.id, child: LText(key.label)),
                ],
                onChanged: (value) => setState(
                  () => identityFileId = value?.isEmpty == true ? null : value,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: localized('管理私钥'),
              onPressed: _openKeychain,
              icon: const Icon(Icons.key_outlined),
            ),
          ],
        ),
        if (authMethod == HostAuthMethod.key && identityFileId == null)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: LText(
              '私钥认证需要选择或导入私钥。',
              style: TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ),
      ];

  /// 首选连接方式放在路线后面：先填好怎么连到这台机器，再选用什么协议（R41）。
  List<Widget> _protocolSection() {
    final small = Theme.of(context).textTheme.bodySmall;
    final sshLike =
        protocol == HostProtocol.ssh || protocol == HostProtocol.mosh;
    return [
      _section(sshLike ? '首选连接方式' : '连接类型'),
      if (widget.host != null || sshLike)
        SegmentedButton<HostProtocol>(
          key: const ValueKey('host-protocol'),
          segments: [
            const ButtonSegment(
              value: HostProtocol.ssh,
              label: Text('SSH'),
              icon: Icon(Icons.lock_outline),
            ),
            const ButtonSegment(
              value: HostProtocol.mosh,
              label: Text('Mosh'),
              icon: Icon(Icons.wifi_tethering),
            ),
            if (widget.host != null) ...[
              const ButtonSegment(
                  value: HostProtocol.telnet,
                  label: Text('Telnet'),
                  icon: Icon(Icons.cable)),
              const ButtonSegment(
                  value: HostProtocol.plugin,
                  label: LText('插件'),
                  icon: Icon(Icons.extension_outlined)),
            ],
          ],
          selected: {protocol},
          onSelectionChanged: (value) => setState(() {
            protocol = value.first;
            if (port.text == '22' || port.text == '23') {
              port.text = protocol == HostProtocol.telnet ? '23' : '22';
            }
          }),
        )
      else
        LText(protocol == HostProtocol.telnet ? 'Telnet' : '终端插件'),
      if (sshLike)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          // 在终端里切换连接方式是 R42 的事，还没做：不能写「连上后能切」。
          child: LText(
            '建议先用 SSH 确认能连上，再改成 Mosh。',
            key: const ValueKey('protocol-advice'),
            style: small,
          ),
        ),
      if (protocol == HostProtocol.mosh)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: LText(
            'Mosh 先用 SSH 登录这台主机、在上面启动 mosh-server，然后断开 SSH，改由 Mosh 插件经 UDP 直连。'
            '要先装好 Mosh 插件并在「设置 → 插件（实验）」批准；服务器上要装好 mosh，本 App 不会替你装。'
            '只能直连：UDP 走不了代理和跳板机。',
            key: const ValueKey('mosh-note'),
            style: small,
          ),
        ),
    ];
  }

  bool get _moshFilled => [moshServerPath, moshPorts, moshLocale]
      .any((c) => c.text.trim().isNotEmpty);
  bool get _timeoutsFilled => [keepalive, connectTimeout, authTimeout]
      .any((c) => c.text.trim().isNotEmpty);
  bool get _startupFilled => startupCommand.text.trim().isNotEmpty;

  Set<String> _filledGroups() => {
        if (_moshFilled) 'mosh',
        if (_timeoutsFilled) 'timeouts',
        if (_startupFilled) 'startup',
      };

  void _toggle(String group) => setState(() {
        if (!_expanded.remove(group)) _expanded.add(group);
      });

  /// 高级选项按组折叠（R41）。填过值的组默认展开；没填的写「自动」，输入框里也不预填默认值。
  /// 收起的组只是不显示，字段仍在表单里参与校验；校验没过时 [_checkedDraft] 把填过值的组展开。
  List<Widget> _advancedGroups() => [
        if (protocol == HostProtocol.mosh)
          _AdvancedGroup(
            id: 'mosh',
            title: 'Mosh 启动参数',
            hint: '建议留空让 App 自动处理；连接时报错、提示要改这里再填。',
            filled: _moshFilled,
            expanded: _expanded.contains('mosh'),
            onToggle: () => _toggle('mosh'),
            children: [
              TextFormField(
                key: const ValueKey('mosh-server-path'),
                controller: moshServerPath,
                decoration: LInputDecoration(
                  labelText: 'mosh-server 路径',
                  hintText: '自动',
                  // 没聚焦也让「自动」露出来：有 label 时 hint 默认只在聚焦后显示。
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  helperText:
                      '留空就先按 PATH 找，再查 /usr/bin、/usr/local/bin、/opt/homebrew/bin、~/.local/bin、nix profile。装在别处、连接时报「没有找到 mosh-server」才填，如 /opt/mosh/bin/mosh-server。',
                  helperMaxLines: 3,
                ),
                validator: _validMoshServerPath,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mosh-ports'),
                controller: moshPorts,
                decoration: LInputDecoration(
                  labelText: 'Mosh UDP 端口范围',
                  hintText: '自动（60001:60999）',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  helperText:
                      'mosh-server 只在这个范围里挑 UDP 端口。服务器或防火墙只放行了某几个端口时填它，比如 60001 或 60001:60010。',
                  helperMaxLines: 3,
                ),
                validator: _validMoshPorts,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mosh-locale'),
                controller: moshLocale,
                decoration: LInputDecoration(
                  labelText: 'Mosh locale',
                  hintText: '自动（en_US.UTF-8）',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  helperText:
                      '留空用 en_US.UTF-8。连接时报「没有可用的 UTF-8 语言环境」才填服务器上有的，比如 C.UTF-8。',
                  helperMaxLines: 3,
                ),
                validator: _validMoshLocale,
              ),
            ],
          ),
        _AdvancedGroup(
          id: 'timeouts',
          title: '超时与保活',
          hint: '一般不用改。网络很慢、经多跳代理时连接总超时，再把超时调大。',
          filled: _timeoutsFilled,
          expanded: _expanded.contains('timeouts'),
          onToggle: () => _toggle('timeouts'),
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final fields = [
                  _AdvancedNumberField(
                    controller: keepalive,
                    label: 'Keepalive 间隔',
                    helper: '每隔多少秒发送一次保活消息',
                    fallback: _defaultKeepalive,
                  ),
                  _AdvancedNumberField(
                    controller: connectTimeout,
                    label: '连接超时',
                    helper: '建立 TCP 连接的最长等待时间',
                    fallback: _defaultConnectTimeout,
                  ),
                  _AdvancedNumberField(
                    controller: authTimeout,
                    label: '认证超时',
                    helper: 'SSH 身份认证的最长等待时间',
                    fallback: _defaultAuthTimeout,
                  ),
                ];
                if (constraints.maxWidth < 720) {
                  return Column(
                    children: [
                      for (var index = 0; index < fields.length; index++) ...[
                        fields[index],
                        if (index < fields.length - 1)
                          const SizedBox(height: 12),
                      ],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var index = 0; index < fields.length; index++) ...[
                      Expanded(child: fields[index]),
                      if (index < fields.length - 1) const SizedBox(width: 12),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
        if (protocol == HostProtocol.ssh)
          _AdvancedGroup(
            id: 'startup',
            title: '启动命令',
            hint: '连上后在 shell 里执行一次；断线恢复时不会再执行。',
            filled: _startupFilled,
            expanded: _expanded.contains('startup'),
            onToggle: () => _toggle('startup'),
            children: [
              TextFormField(
                controller: startupCommand,
                minLines: 1,
                maxLines: 4,
                decoration: LInputDecoration(labelText: '连接后执行命令（可选）'),
              ),
            ],
          ),
      ];

  /// 底部固定的操作栏：验证状态 +【测试连接】【取消】【保存】（R41）。
  /// 测试连接只有普通 SSH 有：它只走 SSH、只查 PTY，测不了 Mosh 的 UDP，也不开远端会话。
  Widget _bottomBar(
    ({RoutePlan? plan, String? error, List<String> warnings}) preview,
  ) {
    final theme = Theme.of(context);
    final status = _verification(preview);
    final canTest =
        widget.verifyHostKey != null && protocol == HostProtocol.ssh;
    // 放在 bottomNavigationBar：SnackBar 会浮在它上面，不挡保存按钮。但 Scaffold 不会把这一栏抬到键盘上方，
    // 所以自己补上键盘高度的内边距，键盘弹出时仍点得到（UX07）。
    return Material(
      elevation: 3,
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(status.icon, size: 18, color: status.color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: LText(
                        status.text,
                        key: const ValueKey('host-editor-verification'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: status.color),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (canTest)
                      OutlinedButton.icon(
                        key: const ValueKey('test-connection'),
                        onPressed: _testConnection,
                        icon: const Icon(Icons.network_check, size: 18),
                        label: const LText('测试连接'),
                      ),
                    const Spacer(),
                    TextButton(
                      key: const ValueKey('host-editor-cancel'),
                      onPressed: _leave,
                      child: const LText('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('host-editor-save'),
                      onPressed: _save,
                      child: const LText('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「已验证」只在测试连接真的跑通、而且之后地址、端口、认证、路线都没变时显示。
  ({IconData icon, String text, Color? color}) _verification(
    ({RoutePlan? plan, String? error, List<String> warnings}) preview,
  ) {
    final scheme = Theme.of(context).colorScheme;
    const info = Icons.info_outline;
    const unknown = Icons.help_outline;
    if (preview.error != null) {
      return (
        icon: Icons.error_outline,
        text: '配置有问题，按上面的提示改好才能保存',
        color: scheme.error,
      );
    }
    return switch (protocol) {
      HostProtocol.plugin => (
          icon: info,
          text: '插件自己联网，这里测试不了',
          color: null,
        ),
      HostProtocol.telnet => (
          icon: info,
          text: 'Telnet 没有测试连接；保存后连接时才知道通不通',
          color: null,
        ),
      HostProtocol.mosh => (
          icon: info,
          text: 'Mosh 要真正连接时才验证：测试连接只测得了 SSH 那一段',
          color: null,
        ),
      _ when widget.verifyHostKey == null => (
          icon: unknown,
          text: '未验证',
          color: null,
        ),
      _ when _verifiedSignature == _signature(_draft()) => (
          icon: Icons.verified_outlined,
          text: '已验证：这组地址、认证和路线刚测试连接成功',
          color: scheme.primary,
        ),
      _ when _verifiedSignature != null => (
          icon: unknown,
          text: '未验证：测试通过后改了地址、端口、认证或路线',
          color: null,
        ),
      _ => (
          icon: unknown,
          text: '未验证：点「测试连接」核对指纹、登录和路线',
          color: null,
        ),
    };
  }

  /// 测试连接结果有效的前提：这些字段和测试时一样。名称、分组、超时之类不影响能不能连上。
  /// 引用的代理、跳板主机本身被改掉时这里看不到（只记引用）。
  static const _verifiedKeys = [
    'hostname',
    'port',
    'username',
    'protocol',
    'authMethod',
    'password',
    'identityFileId',
    sshLoginModeKey,
    'proxyProfileId',
    'proxyConfig',
    'hostChain',
  ];

  String _signature(HostProfile host) =>
      jsonEncode({for (final key in _verifiedKeys) key: host.data[key]});

  bool get _dirty => jsonEncode(_draft().data) != _initialSnapshot;

  /// 取消、关闭、系统返回都走这里：有没保存的改动先问。
  Future<void> _leave() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_dirty && !await _confirmDiscard()) return;
    if (mounted) Navigator.pop(context);
  }

  Future<bool> _confirmDiscard() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const LText('放弃没保存的改动？'),
          content: const LText('这次的修改还没保存，离开后就没了。'),
          actions: [
            TextButton(
              key: const ValueKey('host-editor-keep-editing'),
              onPressed: () => Navigator.pop(context, false),
              child: const LText('继续编辑'),
            ),
            FilledButton(
              key: const ValueKey('host-editor-discard'),
              onPressed: () => Navigator.pop(context, true),
              child: const LText('放弃改动'),
            ),
          ],
        ),
      ) ??
      false;

  /// Tailscale SSH 选中时，代替密码、私钥那几栏显示的说明。来源节点按当前填写的路线算（TSC07）。
  Widget _tailscaleLoginNote(RoutePlan? plan) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    return Container(
      key: const ValueKey('tailscale-login-note'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LText(
            '连接时不发密码和私钥，由目标上的 Tailscale 按 tailnet 策略决定放不放行；'
            '策略要求 check 时，会让你在浏览器里确认。',
            style: style,
          ),
          const SizedBox(height: 6),
          LText('Tailscale 会把这次登录算成：', style: theme.textTheme.labelMedium),
          LText(
            plan == null
                ? '填好地址和路线后显示。'
                : tailscaleSourceNode(plan, plan.hops.length - 1),
            key: const ValueKey('tailscale-source-node'),
            style: style,
          ),
          const SizedBox(height: 6),
          LText(tailscaleCatalogIsNotIdentity, style: style),
          LText(
            '已保存的密码、私钥留着不用，改回普通 SSH 时照常使用。'
            '桌面端 Netcatty 不认这个设置：同步过去后在桌面端仍按普通 SSH 连接。',
            style: style,
          ),
        ],
      ),
    );
  }

  /// 插件主机的设置（X12）：选哪个插件、它自己联网的说明、插件自己的设置页，残留的代理和跳板要用户明确去掉。
  List<Widget> _pluginSection() {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final entries = ref.watch(pluginRegistryProvider);
    final usable = <String, PluginEntry>{
      for (final e in entries)
        if (e.pluginId != null &&
            pluginHostAvailability(entries, e.pluginId).entry == e)
          e.pluginId!: e,
    };
    final current = pluginHostAvailability(entries, pluginId);
    final draft = _draft();
    final routeProblem = pluginHostRouteProblem(draft);
    return [
      _section('用哪个插件'),
      DropdownButtonFormField<String>(
        key: const ValueKey('plugin-picker'),
        initialValue: pluginId,
        decoration: LInputDecoration(labelText: '插件'),
        // 名字加 pluginId 在手机竖屏上放不下（模拟器上溢出 17 像素）：占满一行，放不下的用省略号。
        isExpanded: true,
        items: [
          for (final e in usable.values)
            DropdownMenuItem(
              value: e.pluginId,
              // 插件自己起的名字，不翻译。
              child: Text(
                '${e.descriptor!.displayName}（${e.pluginId}）',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (pluginId != null && !usable.containsKey(pluginId))
            DropdownMenuItem(
              value: pluginId,
              child: Text(pluginId!, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (value) => setState(() => pluginId = value),
      ),
      if (usable.isEmpty && pluginId == null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: LText(
            '还没有能用来连接的插件：装好终端插件后到「设置 → 插件（实验）」核对证书、批准。'
            'Mosh 插件不在这里，Mosh 主机请选 Mosh 协议。',
            key: const ValueKey('plugin-none-usable'),
            style: small,
          ),
        ),
      if (pluginId != null && current.problem != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: LText(
            current.problem!,
            key: const ValueKey('plugin-unavailable'),
            style: small?.copyWith(color: theme.colorScheme.error),
          ),
        ),
      const SizedBox(height: 8),
      LText(
        '这个插件自己联网，不经过本 App 的代理和跳板。连哪里、用什么账号，由插件自己的设置页决定；'
        '本 App 不把这台主机的地址、密码、私钥交给它。',
        key: const ValueKey('plugin-network-note'),
        style: small,
      ),
      if (current.entry case final entry? when entry.settingsActivity != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('plugin-open-settings-from-editor'),
            onPressed: () async {
              final discovery = await ref.read(pluginDiscoveryProvider.future);
              try {
                await discovery.openSettings(entry);
              } on Object catch (error) {
                _message('$error');
              }
            },
            icon: const Icon(Icons.open_in_new),
            label: const LText('打开插件的设置页'),
          ),
        ),
      if (routeProblem != null) ...[
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('plugin-route-problem'),
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LText(routeProblem,
                  style: small?.copyWith(
                      color: theme.colorScheme.onErrorContainer)),
              const SizedBox(height: 6),
              OutlinedButton(
                key: const ValueKey('plugin-route-clear'),
                onPressed: () => setState(() {
                  route.clear();
                }),
                child: const LText('改成直连（去掉这台主机上的代理和跳板设置）'),
              ),
            ],
          ),
        ),
      ],
    ];
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 22, 2, 10),
        child: LText(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      );

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '必填' : null;

  String? _validMoshPorts(String? value) {
    try {
      parseMoshPorts(value);
      return null;
    } on RouteConfigException catch (error) {
      return error.message;
    }
  }

  String? _validMoshServerPath(String? value) {
    try {
      parseMoshServerPath(value);
      return null;
    } on RouteConfigException catch (error) {
      return error.message;
    }
  }

  String? _validMoshLocale(String? value) {
    try {
      parseMoshLocale(value);
      return null;
    } on RouteConfigException catch (error) {
      return error.message;
    }
  }

  Future<void> _openKeychain() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const KeychainSheet(),
      );

  Future<void> _delete() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final navigator = Navigator.of(context);
    if (await widget.onDelete!() && navigator.canPop()) {
      navigator.pop();
    }
  }

  /// 按表单当前内容拼出一份主机配置（还没保存）。保存、路线预览、测试连接都用它，三处看到的是同一份。
  HostProfile _draft() {
    final base = widget.host ??
        HostProfile.create(
          id: _newId,
          label: label.text.trim(),
          hostname: hostname.text.trim(),
          username: username.text.trim(),
        );
    final data = Map<String, dynamic>.from(base.data)
      ..['label'] = label.text.trim()
      ..['hostname'] = hostname.text.trim()
      ..['username'] = username.text.trim()
      ..['port'] = int.tryParse(port.text.trim()) ?? 0
      ..['protocol'] = protocol.name
      ..['authMethod'] = authMethod.name
      ..['savePassword'] = true
      ..['pinned'] = pinned
      ..['tags'] = tags.text
          .split(RegExp(r'[,，]'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList()
      ..['keepaliveOverride'] = true
      ..['keepaliveInterval'] =
          int.tryParse(keepalive.text.trim()) ?? _defaultKeepalive
      ..['sshTcpConnectTimeoutSeconds'] =
          int.tryParse(connectTimeout.text.trim()) ?? _defaultConnectTimeout
      ..['sshAuthReadyTimeoutSeconds'] =
          int.tryParse(authTimeout.text.trim()) ?? _defaultAuthTimeout;
    _setOrRemove(data, 'password', password.text.trim());
    _setOrRemove(data, 'group', group.text.trim());
    _setOrRemove(data, 'identityFileId', identityFileId);
    _setOrRemove(data, 'startupCommand', startupCommand.text.trim());
    // SSH/Mosh 共用表单：切回 SSH 保留 Mosh 选项，执行时仍只按当前协议。
    final keepsMosh =
        protocol == HostProtocol.ssh || protocol == HostProtocol.mosh;
    for (final (key, controller) in [
      (moshPortsKey, moshPorts),
      (moshServerPathKey, moshServerPath),
      (moshLocaleKey, moshLocale),
    ]) {
      _setOrRemove(data, key, keepsMosh ? controller.text.trim() : null);
    }
    // 同理，只有插件主机才留 pluginId。
    _setOrRemove(
      data,
      pluginIdKey,
      protocol == HostProtocol.plugin ? pluginId : null,
    );
    if (unlinkCatalog) data.remove(CatalogBinding.key);
    if (protocol != HostProtocol.telnet &&
        protocol != HostProtocol.plugin &&
        loginMode == SshLoginMode.tailscale) {
      data[sshLoginModeKey] = 'tailscale';
    } else {
      data.remove(sshLoginModeKey);
    }
    route.writeTo(data, enabled: protocol != HostProtocol.telnet);
    return HostProfile(data);
  }

  late final String _newId = const Uuid().v4();

  /// 按表单当前内容算路线，和连接时用的是同一个函数。配置矛盾时给出原因。
  ({RoutePlan? plan, String? error, List<String> warnings}) _preview(
    VaultData? vault,
  ) {
    if (vault == null) return (plan: null, error: null, warnings: const []);
    if (protocol == HostProtocol.plugin) {
      // 插件主机不算路线（插件自己联网）。残留的代理、跳板设置不悄悄去掉，要用户在这里明确改成直连。
      return (
        plan: null,
        error: pluginHostRouteProblem(_draft()) ??
            (pluginId == null ? '选一个插件：协议选了「插件」，就要选用哪个插件连接。' : null),
        warnings: const [],
      );
    }
    final draft = _draft();
    try {
      final plan = resolveRoutePlan(
        draft,
        hosts: vault.hosts,
        proxyProfiles: vault.proxyProfiles,
        keys: vault.keys,
      );
      // Mosh 只能直连：存下来也连不上，保存前就拦住（docs/02：不支持的路线不让保存）。
      // 从桌面端同步来的、已经配了代理的 Mosh 主机，连接时同样在任何网络动作之前拒绝。
      if (plan.protocol == HostProtocol.mosh) {
        final unsupported = moshRouteProblem(plan);
        if (unsupported != null) {
          return (
            plan: plan,
            error: unsupported.toString(),
            warnings: const []
          );
        }
      }
      final warnings = <String>[];
      final entry = plan.entry;
      if (entry is ProxyEntry) {
        final first = plan.hops.first.endpoint;
        if (entry.endpoint.sameAs(first)) {
          warnings.add('代理的地址和端口与要连的 SSH 服务完全一样，可能把两者填混了。');
        } else if (entry.endpoint.port == 22) {
          warnings.add('代理端口填的是 22（SSH 的默认端口），确认没有把 SSH 端口填到代理这里。');
        }
      }
      return (plan: plan, error: null, warnings: warnings);
    } on RouteConfigException catch (error) {
      return (plan: null, error: error.message, warnings: const []);
    }
  }

  Widget _routePreview(
    ({RoutePlan? plan, String? error, List<String> warnings}) preview,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Container(
        key: const ValueKey('route-preview'),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: preview.error == null
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LText('连接时会这样走', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            if (preview.error != null)
              LText(
                preview.error!,
                key: const ValueKey('route-preview-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              )
            else if (preview.plan != null)
              RouteLegsView(plan: preview.plan!, dense: true)
            else
              const LText('填好地址后显示。'),
            for (final warning in preview.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: LText(
                  warning,
                  key: const ValueKey('route-preview-warning'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 保存前的共同检查：表单必填项、私钥认证要选私钥、路线要算得出来。
  /// 返回能用的草稿和路线；不能用时已经提示过原因，返回 null。
  ({HostProfile host, RoutePlan? plan})? _checkedDraft() {
    if (!(_form.currentState?.validate() ?? false)) {
      // 写错的值可能在收起的高级组里：写了东西的组都展开，红字才看得见。
      setState(() => _expanded.addAll(_filledGroups()));
      return null;
    }
    if (protocol != HostProtocol.telnet &&
        protocol != HostProtocol.plugin &&
        loginMode == SshLoginMode.standard &&
        authMethod == HostAuthMethod.key &&
        identityFileId == null) {
      _message('请选择用于认证的 SSH 私钥');
      return null;
    }
    final preview = _preview(ref.read(vaultControllerProvider).data);
    if (preview.error != null) {
      // 不支持或矛盾的路线在保存前就拒绝（docs/02），而不是存下来、连接时才报错。
      _message(preview.error!);
      return null;
    }
    return (host: _draft(), plan: preview.plan);
  }

  void _save() {
    final checked = _checkedDraft();
    if (checked == null) return;
    Navigator.pop(context, checked.host);
  }

  Future<void> _testConnection() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final checked = _checkedDraft();
    if (checked == null || checked.plan == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ConnectionProbeSheet(
        host: checked.host,
        plan: checked.plan!,
        verifyHostKey: widget.verifyHostKey!,
        keyboardInteractive: widget.keyboardInteractive,
        onSucceeded: () {
          if (mounted) {
            setState(() => _verifiedSignature = _signature(checked.host));
          }
        },
      ),
    );
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: LText(text)));
  }

  void _setOrRemove(Map<String, dynamic> data, String key, String? value) {
    if (value == null || value.isEmpty) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }
}

class _AdvancedNumberField extends StatelessWidget {
  const _AdvancedNumberField({
    required this.controller,
    required this.label,
    required this.helper,
    required this.fallback,
  });

  final TextEditingController controller;
  final String label;
  final String helper;
  final int fallback;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: LInputDecoration(
          labelText: label,
          hintText: '自动（$fallback）',
          floatingLabelBehavior: FloatingLabelBehavior.always,
          helperText: helper,
          suffixText: '秒',
          helperMaxLines: 2,
        ),
        validator: (value) {
          final text = value?.trim() ?? '';
          final seconds = int.tryParse(text);
          return text.isEmpty || (seconds != null && seconds >= 0)
              ? null
              : '填整数秒，或留空用自动';
        },
      );
}

/// 高级里的一组（R41）。收起时用 Offstage 藏起来而不是不建：字段还在表单里，保存时照样校验。
class _AdvancedGroup extends StatelessWidget {
  const _AdvancedGroup({
    required this.id,
    required this.title,
    required this.hint,
    required this.filled,
    required this.expanded,
    required this.onToggle,
    required this.children,
  });

  final String id;
  final String title;
  final String hint;
  final bool filled;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('advanced-$id'),
          onTap: onToggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LText(title, style: theme.textTheme.titleSmall),
                      LText(
                        filled ? '已填写' : '自动',
                        key: ValueKey('advanced-$id-state'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Icon(expanded ? Icons.expand_less : Icons.expand_more),
              ],
            ),
          ),
        ),
        Offstage(
          offstage: !expanded,
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LText(hint, style: theme.textTheme.bodySmall),
                const SizedBox(height: 10),
                ...children,
              ],
            ),
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
