import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/models/vault.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import 'connection_probe_sheet.dart';
import 'keychain_sheet.dart';
import 'route_legs_view.dart';

/// 连接路径三选一（R10）。「经跳板机」里还可以显式打开「先经代理连第一台跳板机」这个高级组合。
enum _RouteMode { direct, proxy, jump }

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
  late final TextEditingController proxyHost;
  late final TextEditingController proxyPort;
  late final TextEditingController proxyUsername;
  late final TextEditingController proxyPassword;
  late final TextEditingController keepalive;
  late final TextEditingController connectTimeout;
  late final TextEditingController authTimeout;
  late HostProtocol protocol;
  late HostAuthMethod authMethod;
  late ProxyType proxyType;
  late List<String> jumpHostIds;
  String? identityFileId;
  String proxyMode = 'custom';
  _RouteMode routeMode = _RouteMode.direct;
  bool entryProxy = false;
  bool obscurePassword = true;
  bool obscureProxyPassword = true;
  bool pinned = false;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    final proxy = host?.proxyConfig;
    label = TextEditingController(text: host?.label);
    hostname = TextEditingController(text: host?.hostname);
    username = TextEditingController(text: host?.username);
    port = TextEditingController(text: (host?.port ?? 22).toString());
    password = TextEditingController(text: host?.password);
    group = TextEditingController(text: host?.group);
    tags = TextEditingController(text: host?.tags.join(', '));
    startupCommand = TextEditingController(text: host?.startupCommand);
    proxyHost = TextEditingController(text: proxy?.host);
    proxyPort = TextEditingController(
      text: proxy == null || proxy.port == 0 ? '' : proxy.port.toString(),
    );
    proxyUsername = TextEditingController(text: proxy?.username);
    proxyPassword = TextEditingController(text: proxy?.password);
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
    protocol = host?.protocol ?? HostProtocol.ssh;
    authMethod = host?.authMethod ?? HostAuthMethod.auto;
    identityFileId = host?.identityFileId;
    jumpHostIds = [...?host?.hostChainIds];
    proxyType = proxy?.type ?? ProxyType.socks5;
    final hasProfile = host?.proxyProfileId?.isNotEmpty == true;
    proxyMode = hasProfile ? 'profile:${host!.proxyProfileId}' : 'custom';
    final hasProxy = hasProfile || proxy != null;
    routeMode = jumpHostIds.isNotEmpty
        ? _RouteMode.jump
        : hasProxy
            ? _RouteMode.proxy
            : _RouteMode.direct;
    entryProxy = jumpHostIds.isNotEmpty && hasProxy;
    pinned = host?.pinned ?? false;
    // 路线摘要跟着输入实时更新。
    for (final controller in [
      hostname,
      port,
      username,
      label,
      proxyHost,
      proxyPort,
      proxyUsername,
    ]) {
      controller.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  bool get _usesProxy =>
      routeMode == _RouteMode.proxy ||
      (routeMode == _RouteMode.jump && entryProxy);

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
      proxyHost,
      proxyPort,
      proxyUsername,
      proxyPassword,
      keepalive,
      connectTimeout,
      authTimeout,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(vaultControllerProvider).data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    final availableHosts = (vault?.hosts ?? const <HostProfile>[])
        .where((value) =>
            value.id != widget.host?.id &&
            value.protocol == HostProtocol.ssh &&
            !jumpHostIds.contains(value.id))
        .toList();
    final profiles = vault?.proxyProfiles ?? const <ProxyProfile>[];
    if (identityFileId != null &&
        !keys.any((value) => value.id == identityFileId)) {
      identityFileId = null;
    }
    if (proxyMode.startsWith('profile:') &&
        !profiles.any((value) => 'profile:${value.id}' == proxyMode)) {
      proxyMode = 'custom';
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
                  // Mosh 由独立插件提供（X08–X10），插件还没有：新建时不能选，不列出没实现的功能（UX04）。
                  enabled: false,
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
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LText(
                  'Mosh 由独立插件提供，目前还没有这个插件：这台主机暂时连不上，可以先改用 SSH。',
                  key: ValueKey('mosh-unavailable'),
                  style: TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
            _section('基本信息'),
            TextFormField(
              controller: label,
              decoration: LInputDecoration(labelText: '名称'),
              validator: _required,
            ),
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
            if (protocol == HostProtocol.telnet) ...[
              _section('连接路径'),
              const LText(
                'Telnet 只支持直连，不能经代理或跳板机；保存时会去掉这台主机上的代理和跳板设置。',
                key: ValueKey('telnet-direct-only'),
              ),
              _routePreview(preview),
            ],
            if (protocol != HostProtocol.telnet) ...[
              _section('身份认证'),
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
              _section('连接路径'),
              SegmentedButton<_RouteMode>(
                key: const ValueKey('route-mode'),
                segments: const [
                  ButtonSegment(
                    value: _RouteMode.direct,
                    label: LText('直连'),
                    icon: Icon(Icons.arrow_forward),
                  ),
                  ButtonSegment(
                    value: _RouteMode.proxy,
                    label: LText('经代理'),
                    icon: Icon(Icons.public),
                  ),
                  ButtonSegment(
                    value: _RouteMode.jump,
                    label: LText('经跳板机'),
                    icon: Icon(Icons.alt_route),
                  ),
                ],
                selected: {routeMode},
                onSelectionChanged: (value) =>
                    setState(() => routeMode = value.first),
              ),
              const SizedBox(height: 8),
              if (routeMode == _RouteMode.direct)
                LText(
                  '手机直接连目标，不经过 App 的代理；你开着的 VPN 照常生效。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (routeMode == _RouteMode.jump) ...[
                if (jumpHostIds.isEmpty)
                  const LText(
                    '还没有选跳板机：从下面添加，按连接顺序排列（最多 3 台）。',
                    style: TextStyle(color: Colors.redAccent, fontSize: 12),
                  )
                else
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: jumpHostIds.length,
                    onReorderItem: (oldIndex, newIndex) => setState(() {
                      final id = jumpHostIds.removeAt(oldIndex);
                      jumpHostIds.insert(newIndex, id);
                    }),
                    itemBuilder: (context, index) {
                      final id = jumpHostIds[index];
                      final jump = vault?.hosts.cast<HostProfile?>().firstWhere(
                            (value) => value?.id == id,
                            orElse: () => null,
                          );
                      return ListTile(
                        key: ValueKey(id),
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(child: LText('${index + 1}')),
                        title: LText(jump?.label ?? '缺失的主机'),
                        subtitle: jump == null
                            ? LText(id)
                            : LText(
                                '${jump.username}@${jump.hostname}:${jump.port}'),
                        trailing: IconButton(
                          onPressed: () =>
                              setState(() => jumpHostIds.removeAt(index)),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                      );
                    },
                  ),
                if (availableHosts.isNotEmpty)
                  // 每加一台就换 key 让它重置成空：否则它还记着刚选的那台，而那台已不在候选里，
                  // Flutter 断言「当前值必须在选项里恰好出现一次」失败——上游这里选一次跳板机就红屏。
                  KeyedSubtree(
                    key: ValueKey('add-jump-${jumpHostIds.length}'),
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('add-jump-host'),
                      decoration: LInputDecoration(
                        labelText: '添加跳板机',
                        prefixIcon: Icon(Icons.add_road),
                      ),
                      items: [
                        for (final value in availableHosts)
                          DropdownMenuItem(
                            value: value.id,
                            child: LText(value.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => jumpHostIds.add(value));
                        }
                      },
                    ),
                  ),
                SwitchListTile(
                  key: const ValueKey('entry-proxy-switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const LText('先经代理连第一台跳板机（高级）'),
                  subtitle: const LText(
                    '代理只用于手机连第一台跳板机；之后每一跳由上一跳转发，不再经过代理。',
                  ),
                  value: entryProxy,
                  onChanged: (value) => setState(() => entryProxy = value),
                ),
              ],
              if (_usesProxy) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: proxyMode,
                  decoration: LInputDecoration(labelText: '代理'),
                  items: [
                    const DropdownMenuItem(
                      value: 'custom',
                      child: LText('自定义 HTTP / SOCKS5 代理'),
                    ),
                    for (final profile in profiles)
                      DropdownMenuItem(
                        value: 'profile:${profile.id}',
                        child: LText('已保存 · ${profile.label}'),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => proxyMode = value ?? 'custom'),
                ),
                if (proxyMode == 'custom') ...[
                  const SizedBox(height: 12),
                  SegmentedButton<ProxyType>(
                    segments: const [
                      ButtonSegment(
                        value: ProxyType.socks5,
                        label: LText('SOCKS5'),
                      ),
                      ButtonSegment(
                          value: ProxyType.http, label: LText('HTTP')),
                    ],
                    selected: {proxyType},
                    onSelectionChanged: (value) =>
                        setState(() => proxyType = value.first),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          key: const ValueKey('proxy-host'),
                          controller: proxyHost,
                          decoration: LInputDecoration(labelText: '代理地址'),
                          validator: _required,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          key: const ValueKey('proxy-port'),
                          controller: proxyPort,
                          decoration: LInputDecoration(labelText: '代理端口'),
                          keyboardType: TextInputType.number,
                          validator: _validPort,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: proxyUsername,
                    decoration: LInputDecoration(labelText: '代理用户名（可选）'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: proxyPassword,
                    obscureText: obscureProxyPassword,
                    decoration: LInputDecoration(
                      labelText: '代理密码（可选）',
                      suffixIcon: IconButton(
                        onPressed: () => setState(
                          () => obscureProxyPassword = !obscureProxyPassword,
                        ),
                        icon: Icon(
                          obscureProxyPassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                      ),
                    ),
                  ),
                ],
                // SOX04：SOCKS5/HTTP 代理认证本身不加密。别让用户以为「SSH 是加密的」就连代理口令也受保护。
                const SizedBox(height: 8),
                LText(
                  '代理的用户名和密码是明文发给代理的：SSH 只加密之后的终端会话，保护不了这段口令。'
                  '远程代理请只在可信网络（比如你自己的 VPN）里使用。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              _routePreview(preview),
              if (widget.verifyHostKey != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    key: const ValueKey('test-connection'),
                    onPressed: _testConnection,
                    icon: const Icon(Icons.network_check),
                    label: const LText('测试连接'),
                  ),
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
    // 路线只按当前选的方式保存：切到「直连」就真的去掉代理和跳板，不留一份看不见却还生效的旧设置。
    final usesJumps =
        protocol != HostProtocol.telnet && routeMode == _RouteMode.jump;
    final usesProxy = protocol != HostProtocol.telnet && _usesProxy;
    if (usesJumps && jumpHostIds.isNotEmpty) {
      data['hostChain'] = {
        'hostIds': [...jumpHostIds]
      };
    } else {
      data.remove('hostChain');
    }
    if (!usesProxy) {
      data.remove('proxyProfileId');
      data.remove('proxyConfig');
    } else if (proxyMode.startsWith('profile:')) {
      data['proxyProfileId'] = proxyMode.substring('profile:'.length);
      data.remove('proxyConfig');
    } else {
      data.remove('proxyProfileId');
      data['proxyConfig'] = ProxyConfig(
        type: proxyType,
        host: proxyHost.text.trim(),
        port: int.tryParse(proxyPort.text.trim()) ?? 0,
        username: proxyUsername.text.trim(),
        password: proxyPassword.text,
      ).toJson();
    }
    return HostProfile(data);
  }

  late final String _newId = const Uuid().v4();

  /// 按表单当前内容算路线，和连接时用的是同一个函数。配置矛盾时给出原因。
  ({RoutePlan? plan, String? error, List<String> warnings}) _preview(
    VaultData? vault,
  ) {
    if (vault == null) return (plan: null, error: null, warnings: const []);
    if (routeMode == _RouteMode.jump &&
        protocol != HostProtocol.telnet &&
        jumpHostIds.isEmpty) {
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
