import 'dart:async';

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

class HostEditor extends ConsumerStatefulWidget {
  const HostEditor({
    super.key,
    this.host,
    this.onDelete,
    this.verifyHostKey,
    this.keyboardInteractive,
  });

  final HostProfile? host;
  final Future<bool> Function()? onDelete;

  /// 测试连接用的指纹核对和交互式登录。和正式连接用同一套，测试不能绕过指纹确认。
  /// 不传（比如测试环境）就不显示「测试连接」。
  final HostKeyVerifier? verifyHostKey;
  final KeyboardInteractiveHandler? keyboardInteractive;

  @override
  ConsumerState<HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends ConsumerState<HostEditor> {
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

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    route = ConnectionRouteDraft.forHost(host);
    label = TextEditingController(text: host?.label);
    hostname = TextEditingController(text: host?.hostname);
    username = TextEditingController(text: host?.username);
    port = TextEditingController(text: (host?.port ?? 22).toString());
    password = TextEditingController(text: host?.password);
    group = TextEditingController(text: host?.group);
    tags = TextEditingController(text: host?.tags.join(', '));
    startupCommand = TextEditingController(text: host?.startupCommand);
    keepalive = TextEditingController(
      text:
          ((host?.data['keepaliveInterval'] as num?)?.toInt() ?? 10).toString(),
    );
    connectTimeout = TextEditingController(
      text: ((host?.data['sshTcpConnectTimeoutSeconds'] as num?)?.toInt() ?? 15)
          .toString(),
    );
    authTimeout = TextEditingController(
      text: ((host?.data['sshAuthReadyTimeoutSeconds'] as num?)?.toInt() ?? 30)
          .toString(),
    );
    moshPorts = TextEditingController(
      text: host?.data[moshPortsKey]?.toString() ?? '',
    );
    protocol = host?.protocol ?? HostProtocol.ssh;
    authMethod = host?.authMethod ?? HostAuthMethod.auto;
    loginMode = host == null ? SshLoginMode.standard : sshLoginModeOf(host);
    identityFileId = host?.identityFileId;
    pinned = host?.pinned ?? false;
    pluginId = host == null ? null : pluginIdOf(host);
    // App 启动时不自动发现插件（X04）：编辑器里要列出能选的插件，先让发现跑一次。
    unawaited(
        ref.read(pluginHostDiscoveryProvider.future).catchError((Object _) {}));
    // 路线摘要跟着输入实时更新。
    for (final controller in [
      hostname,
      port,
      username,
      label,
      route.proxyHost,
      route.proxyPort,
      route.proxyUsername,
    ]) {
      controller.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final controller in [
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
    ]) {
      controller.dispose();
    }
    route.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(vaultControllerProvider).data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    final profiles = vault?.proxyProfiles ?? const <ProxyProfile>[];
    if (identityFileId != null &&
        !keys.any((value) => value.id == identityFileId)) {
      identityFileId = null;
    }
    if (route.proxyMode.startsWith('profile:') &&
        !profiles.any((value) => 'profile:${value.id}' == route.proxyMode)) {
      route.proxyMode = 'custom';
    }
    final preview = _preview(vault);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
        title: LText(widget.host == null ? '新建连接' : '编辑连接'),
        actions: [TextButton(onPressed: _save, child: const LText('保存'))],
      ),
      body: Form(
        key: _form,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            SegmentedButton<HostProtocol>(
              segments: [
                const ButtonSegment(
                  value: HostProtocol.ssh,
                  label: LText('SSH'),
                  icon: Icon(Icons.lock_outline),
                ),
                const ButtonSegment(
                  value: HostProtocol.telnet,
                  label: LText('Telnet'),
                  icon: Icon(Icons.cable),
                ),
                const ButtonSegment(
                  value: HostProtocol.mosh,
                  label: LText('Mosh'),
                  icon: Icon(Icons.wifi_tethering),
                ),
                const ButtonSegment(
                  value: HostProtocol.plugin,
                  label: LText('插件'),
                  icon: Icon(Icons.extension_outlined),
                ),
              ],
              selected: {protocol},
              onSelectionChanged: (value) => setState(() {
                protocol = value.first;
                if (port.text == '22' || port.text == '23') {
                  port.text = protocol == HostProtocol.telnet ? '23' : '22';
                }
              }),
            ),
            if (protocol == HostProtocol.mosh)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LText(
                  'Mosh 先用 SSH 登录这台主机、在上面启动 mosh-server，然后断开 SSH，改由 Mosh 插件经 UDP 直连。'
                  '要先装好 Mosh 插件并在「设置 → 插件（实验）」批准；服务器上要装好 mosh，本 App 不会替你装。'
                  '只能直连：UDP 走不了代理和跳板机。',
                  key: const ValueKey('mosh-note'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            _section('基本信息'),
            TextFormField(
              controller: label,
              decoration: LInputDecoration(labelText: '名称'),
              validator: _required,
            ),
            // 插件主机没有地址、端口、用户名：连哪里由插件自己的设置页决定，本 App 不交给它任何主机数据。
            if (protocol != HostProtocol.plugin) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: hostname,
                decoration: LInputDecoration(labelText: '主机名 / IP'),
                keyboardType: TextInputType.url,
                validator: _required,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: username,
                      decoration: LInputDecoration(labelText: '用户名'),
                      validator: _required,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: port,
                      decoration: LInputDecoration(
                        labelText: protocol == HostProtocol.telnet
                            ? 'Telnet 端口'
                            : 'SSH 端口',
                      ),
                      keyboardType: TextInputType.number,
                      validator: _validPort,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: group,
              decoration: LInputDecoration(labelText: '分组（可选）'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: tags,
              decoration: LInputDecoration(
                labelText: '标签（逗号分隔）',
              ),
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
            if (protocol != HostProtocol.telnet &&
                protocol != HostProtocol.plugin) ...[
              _section('身份认证'),
              SegmentedButton<SshLoginMode>(
                key: const ValueKey('ssh-login-mode'),
                segments: const [
                  ButtonSegment(
                    value: SshLoginMode.standard,
                    label: LText('普通 SSH'),
                    icon: Icon(Icons.password),
                  ),
                  ButtonSegment(
                    value: SshLoginMode.tailscale,
                    label: LText('Tailscale SSH'),
                    icon: Icon(Icons.hub_outlined),
                  ),
                ],
                selected: {loginMode},
                onSelectionChanged: (value) =>
                    setState(() => loginMode = value.first),
              ),
              const SizedBox(height: 12),
              if (loginMode == SshLoginMode.tailscale)
                _tailscaleLoginNote(preview.plan),
              if (loginMode == SshLoginMode.standard) ...[
                DropdownButtonFormField<HostAuthMethod>(
                  initialValue: authMethod,
                  decoration: LInputDecoration(labelText: '认证方式'),
                  items: const [
                    DropdownMenuItem(
                      value: HostAuthMethod.auto,
                      child: LText('自动（私钥 / 密码 / 交互式）'),
                    ),
                    DropdownMenuItem(
                      value: HostAuthMethod.password,
                      child: LText('密码'),
                    ),
                    DropdownMenuItem(
                      value: HostAuthMethod.key,
                      child: LText('私钥'),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => authMethod = value ?? HostAuthMethod.auto),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: password,
                  obscureText: obscurePassword,
                  decoration: LInputDecoration(
                    labelText: '密码（可选）',
                    suffixIcon: IconButton(
                      onPressed: () =>
                          setState(() => obscurePassword = !obscurePassword),
                      icon: Icon(
                        obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
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
                          const DropdownMenuItem(
                            value: '',
                            child: LText('不指定'),
                          ),
                          for (final key in keys)
                            DropdownMenuItem(
                              value: key.id,
                              child: LText(key.label),
                            ),
                        ],
                        onChanged: (value) => setState(
                          () => identityFileId =
                              value?.isEmpty == true ? null : value,
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
              ],
              _section('连接路径'),
              ConnectionRouteEditor(
                draft: route,
                hosts: vault?.hosts ?? const [],
                profiles: profiles,
                targetHostId: widget.host?.id,
                presentation: ConnectionRouteEditorPresentation.host,
                onChanged: _refresh,
                requiredValidator: _required,
                portValidator: _validPort,
              ),
              if (protocol == HostProtocol.mosh) ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('mosh-ports'),
                  controller: moshPorts,
                  decoration: LInputDecoration(
                    labelText: 'Mosh UDP 端口范围（可选）',
                    hintText: '60001:60999',
                    helperText:
                        'mosh-server 只在这个范围里挑 UDP 端口。服务器或防火墙只放行了某几个端口时填它，比如 60001 或 60001:60010。',
                    helperMaxLines: 3,
                  ),
                  validator: _validMoshPorts,
                ),
              ],
              _routePreview(preview),
              // 测试连接只走 SSH、只查 PTY，测不了 Mosh 的 UDP 那一段：给 Mosh 主机一个「测试通过」反而误导。
              if (widget.verifyHostKey != null && protocol != HostProtocol.mosh)
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    key: const ValueKey('test-connection'),
                    onPressed: _testConnection,
                    icon: const Icon(Icons.network_check),
                    label: const LText('测试连接'),
                  ),
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
              _section('高级选项'),
              TextFormField(
                controller: startupCommand,
                minLines: 1,
                maxLines: 4,
                decoration: LInputDecoration(labelText: '连接后执行命令（可选）'),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final fields = [
                    _AdvancedNumberField(
                      controller: keepalive,
                      label: 'Keepalive 间隔',
                      helper: '每隔多少秒发送一次保活消息',
                    ),
                    _AdvancedNumberField(
                      controller: connectTimeout,
                      label: '连接超时',
                      helper: '建立 TCP 连接的最长等待时间',
                    ),
                    _AdvancedNumberField(
                      controller: authTimeout,
                      label: '认证超时',
                      helper: 'SSH 身份认证的最长等待时间',
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
                        if (index < fields.length - 1)
                          const SizedBox(width: 12),
                      ],
                    ],
                  );
                },
              ),
              if (widget.host != null && widget.onDelete != null) ...[
                const SizedBox(height: 28),
                OutlinedButton.icon(
                  key: const ValueKey('delete-host-from-editor'),
                  onPressed: _delete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    side:
                        BorderSide(color: Theme.of(context).colorScheme.error),
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const LText('删除此服务器'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

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
                  route.mode = ConnectionRouteMode.direct;
                  route.entryProxy = false;
                }),
                child: const LText('改成直连（去掉这台主机上的代理和跳板设置）'),
              ),
            ],
          ),
        ),
      ],
      if (widget.host != null && widget.onDelete != null) ...[
        const SizedBox(height: 28),
        OutlinedButton.icon(
          key: const ValueKey('delete-host-from-editor'),
          onPressed: _delete,
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            side: BorderSide(color: theme.colorScheme.error),
          ),
          icon: const Icon(Icons.delete_outline),
          label: const LText('删除此服务器'),
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

  String? _validPort(String? value) {
    final parsed = int.tryParse(value ?? '');
    return parsed == null || parsed < 1 || parsed > 65535 ? '端口无效' : null;
  }

  String? _validMoshPorts(String? value) {
    try {
      parseMoshPorts(value);
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
      ..['keepaliveInterval'] = int.tryParse(keepalive.text) ?? 10
      ..['sshTcpConnectTimeoutSeconds'] =
          int.tryParse(connectTimeout.text) ?? 15
      ..['sshAuthReadyTimeoutSeconds'] = int.tryParse(authTimeout.text) ?? 30;
    _setOrRemove(data, 'password', password.text.trim());
    _setOrRemove(data, 'group', group.text.trim());
    _setOrRemove(data, 'identityFileId', identityFileId);
    _setOrRemove(data, 'startupCommand', startupCommand.text.trim());
    // 只有 Mosh 主机才留端口范围；切回 SSH 时去掉，免得留一份看不见的设置。
    _setOrRemove(
      data,
      moshPortsKey,
      protocol == HostProtocol.mosh ? moshPorts.text.trim() : null,
    );
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
    if (route.mode == ConnectionRouteMode.jump &&
        protocol != HostProtocol.telnet &&
        route.jumpHostIds.isEmpty) {
      return (plan: null, error: '选了「经跳板机」，但还没有添加跳板机。', warnings: const []);
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
    if (!(_form.currentState?.validate() ?? false)) return null;
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
  });

  final TextEditingController controller;
  final String label;
  final String helper;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: LInputDecoration(
          labelText: label,
          helperText: helper,
          suffixText: '秒',
          helperMaxLines: 2,
        ),
      );
}
