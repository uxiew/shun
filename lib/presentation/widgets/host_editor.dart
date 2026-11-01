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
import '../../domain/host_summary.dart';
import '../../domain/models/host.dart';
import '../../domain/models/vault.dart';
import '../../domain/plugins/mosh_route.dart';
import '../../domain/plugins/plugin_host.dart';
import '../../domain/tailscale_ssh.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import 'catalog_source_section.dart';
import 'connection_probe_sheet.dart';
import 'connection_type_sheet.dart';
import 'form_gap.dart';
import 'host_type_icon.dart';
import 'credential_field.dart';
import 'identity_editor.dart';
import 'route_legs_view.dart';
import 'connection_route_draft.dart';
import 'connection_route_editor.dart';
import 'proxy_profiles_page.dart';
import 'secret_content.dart';
import 'unsupported_connection_page.dart';
import 'connection_endpoint_fields.dart';
import 'hint.dart';
import '../../domain/vault_secrets.dart';
import '../../domain/credential_identity.dart';

class HostEditor extends ConsumerStatefulWidget {
  const HostEditor({
    super.key,
    this.host,
    this.initialProtocol = HostProtocol.ssh,
    this.initialPluginId,
    this.onOtherType,
    this.onDelete,
    this.verifyHostKey,
    this.keyboardInteractive,
  });

  final HostProfile? host;
  final HostProtocol initialProtocol;
  final String? initialPluginId;

  /// 新建时把类型换成 Tailscale、RustDesk、UU：表单建不了这些，关掉自己后交给调用方。
  /// 不传（编辑已有主机）就只能在终端类型里换。
  final ValueChanged<ConnectionTypeChoice>? onOtherType;
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

  /// 「凭据」里选的那个（R26 F25、F31）。[useCredential] 为真才用；保存前切回「用户名 / 密码」，填过的都还在。
  String? identityId;
  bool useCredential = false;
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

  /// 点过保存或测试连接。之前不报「必填」、不报路线问题：新建页一打开就满屏红字，
  /// 用户还没动手就被说错了（docs/dev/ui-text.md）。之后每次重画都重新校验，改对了红字马上消失
  /// ——以前点一次保存后「必填」会一直挂着，填好了也不走。
  var _triedSave = false;

  /// 新建、还没点过保存、地址也没填：这时路线必然算不出来，那条错误不是用户的错。
  bool get _quiet =>
      widget.host == null && !_triedSave && hostname.text.trim().isEmpty;

  /// 「高级」整块展开没有。默认收起，填过什么写在它的摘要里（F39，学 LobiShell 的高级卡片）。
  var _advancedOpen = false;

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
    identityId = host?.data['identityId']?.toString();
    useCredential = identityId != null;
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
    _initialSnapshot = _comparable(_draft());
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

  String get _labelOrAddress {
    final text = label.text.trim();
    return text.isNotEmpty ? text : hostname.text.trim();
  }

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
  // 整页防截屏（R44），不管协议有没有密码框：协议能在页内换，跟着开关会闪。
  Widget build(BuildContext context) => SecretContent(child: _page(context));

  Widget _page(BuildContext context) {
    if (_unsupported) {
      return UnsupportedConnectionPage(label: widget.host!.label);
    }
    final vaultState = ref.watch(vaultControllerProvider);
    final vault = vaultState.data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    if (identityFileId != null &&
        !keys.any((value) => value.id == identityFileId)) {
      identityFileId = null;
    }
    final identities =
        vault == null ? const <IdentityProfile>[] : vaultIdentities(vault);
    // 引用的身份被删了（桌面端删的、同步过来）：和私钥一样当没选，连接时本来也会退回主机自己的设置。
    if (vault != null &&
        identityId != null &&
        !identities.any((i) => i.id == identityId)) {
      identityId = null;
      useCredential = false;
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
          autovalidateMode: _triedSave
              ? AutovalidateMode.always
              : AutovalidateMode.onUserInteraction,
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _typeRow(),
              if (protocol == HostProtocol.plugin) ..._pluginSection(),
              // 插件主机没有地址、端口、用户名：连哪里由插件自己的设置页决定，本 App 不交给它任何主机数据。
              // 它自己顶上带一个 FormGap，这里不再放，放了间隔就是两倍。
              if (protocol != HostProtocol.plugin)
                ConnectionEndpointFields(
                  protocol: protocol,
                  hostname: hostname,
                  port: port,
                ),
              // 地址、端口写错时路线算不出来：路线编辑器收在高级里，错得在这里说，不然底部写
              //「按上面红字改好」，页面上却找不到红字。
              if (protocol != HostProtocol.plugin &&
                  preview.error != null &&
                  !_quiet &&
                  !_routeVisible(preview))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: LText(
                    preview.error!,
                    key: const ValueKey('host-editor-route-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (sshLike) ...[
                const FormGap(),
                Row(
                  children: [
                    Expanded(
                      child: LoginChoiceField(
                        key: const ValueKey('ssh-login-mode'),
                        value: _loginChoice,
                        withTailscale: true,
                        onChanged: _setLoginChoice,
                      ),
                    ),
                    const HintButton(
                      title: '认证方式',
                      message:
                          '用户名 / 密码只给这一台，不填密码就连接时问。凭据是多台共用的一份，改一次全跟着变，里面可以是密码、SSH 密钥或安全密钥。',
                    ),
                  ],
                ),
                const FormGap(),
                ...switch (_loginChoice) {
                  LoginChoice.simple => _simpleLogin(keys),
                  LoginChoice.credential => _credentialLogin(identities),
                  LoginChoice.tailscale => [
                      _usernameField(),
                      const FormGap(),
                      _tailscaleLoginNote(preview.plan),
                    ],
                },
              ],
              const FormGap(),
              TextFormField(
                controller: label,
                decoration: protocol == HostProtocol.plugin
                    ? LInputDecoration(labelText: '名称')
                    : LInputDecoration(
                        labelText: '名称',
                        hintText: '留空用地址',
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                // 插件主机没有地址可以拿来当名字。
                validator: protocol == HostProtocol.plugin ? _required : null,
              ),
              const SizedBox(height: 12),
              _AdvancedGroup(
                id: 'all',
                title: '高级',
                state: _advancedSummary,
                filled: false,
                expanded: _advancedVisible(preview),
                onToggle: () => setState(() => _advancedOpen = !_advancedOpen),
                children: _advancedGroups(vaultState, preview),
              ),
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

  LoginChoice get _loginChoice => loginMode == SshLoginMode.tailscale
      ? LoginChoice.tailscale
      : useCredential
          ? LoginChoice.credential
          : LoginChoice.simple;

  /// 选 Tailscale SSH 时原来的认证设置留着，改回普通 SSH 照常用。
  void _setLoginChoice(LoginChoice choice) => setState(() {
        loginMode = choice == LoginChoice.tailscale
            ? SshLoginMode.tailscale
            : SshLoginMode.standard;
        useCredential = choice == LoginChoice.credential;
      });

  /// 这次保存会用的凭据。选了「凭据」但还没选中哪个时是 null。
  IdentityProfile? get _chosenCredential {
    final vault = ref.read(vaultControllerProvider).data;
    if (vault == null || _loginChoice != LoginChoice.credential) return null;
    return vaultIdentities(vault)
        .where((item) => item.id == identityId)
        .firstOrNull;
  }

  /// 路线预览里写的用户名：选了凭据就是凭据的。
  String _shownUsername() {
    final fromCredential = _chosenCredential?.username ?? '';
    return fromCredential.isNotEmpty ? fromCredential : username.text;
  }

  Widget _usernameField() => TextFormField(
        controller: username,
        decoration: LInputDecoration(labelText: '用户名'),
        validator: _required,
      );

  /// 只显示登录时真会发的（`ssh_identity.dart`、`ssh_service.dart` 的 `onPasswordRequest`）：
  /// 没有凭据之前建的主机可能挂着自己的私钥，照常能连；设成「只用私钥」的不发密码，密码框不显示。
  /// 藏起来的密码不清：点「不用了」以后它照常用。
  List<Widget> _simpleLogin(List<SshKeyProfile> keys) {
    final ownKey = authMethod == HostAuthMethod.password
        ? null
        : keys.where((key) => key.id == identityFileId).firstOrNull;
    return [
      _usernameField(),
      const FormGap(),
      if (ownKey == null || authMethod != HostAuthMethod.key)
        TextFormField(
          controller: password,
          obscureText: obscurePassword,
          // 点小眼睛改成明文时也不让输入法学、不联想（R44）。
          enableIMEPersonalizedLearning: false,
          enableSuggestions: false,
          autocorrect: false,
          decoration: LInputDecoration(
            labelText: '密码（可选）',
            suffixIcon: IconButton(
              onPressed: () =>
                  setState(() => obscurePassword = !obscurePassword),
              tooltip: localized('显示或隐藏密码'),
              icon: Icon(
                obscurePassword ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          ),
        ),
      if (ownKey != null)
        OwnKeyRow(
          sshKey: ownKey,
          onDrop: () => setState(() {
            identityFileId = null;
            if (authMethod == HostAuthMethod.key) {
              authMethod = HostAuthMethod.auto;
            }
          }),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('host-save-as-credential'),
          onPressed: username.text.trim().isEmpty ? null : _saveAsCredential,
          icon: const Icon(Icons.bookmark_add_outlined),
          label: const LText('存为凭据'),
        ),
      ),
    ];
  }

  /// 把这台填的账号存成凭据并改用它。预填的按现在登录真会发的拼：
  /// 「自动」挂着私钥又存了密码，就是「SSH 密钥 + 密码」，展开后还是先公钥再密码，登录行为不变。
  Future<void> _saveAsCredential() async {
    final usesKey = authMethod != HostAuthMethod.password &&
        (identityFileId ?? '').isNotEmpty;
    final secret = authMethod == HostAuthMethod.key ? '' : password.text.trim();
    final id = await editAndSaveIdentity(context, ref, draft: {
      'username': username.text.trim(),
      'authMethod': usesKey ? 'key' : 'password',
      if (usesKey) 'keyId': identityFileId,
      if (secret.isNotEmpty) 'password': secret,
    });
    if (id == null || !mounted) return;
    setState(() {
      identityId = id;
      useCredential = true;
    });
  }

  List<Widget> _credentialLogin(List<IdentityProfile> identities) {
    final selected = identities.where((i) => i.id == identityId).firstOrNull;
    return [
      CredentialField(
        key: const ValueKey('host-identity'),
        value: identityId,
        errorText: _triedSave && selected == null ? '选一个凭据' : null,
        onChanged: (id) => setState(() => identityId = id),
      ),
      // 桌面端建的凭据可能没写用户名：那还是用这台自己的（[applyHostIdentity]）。
      if (selected != null && selected.username.isEmpty) ...[
        const FormGap(),
        _usernameField(),
      ],
    ];
  }

  /// 所有类型都在这一行切换（F39），原来是表单前一整页加表单后面一组「首选连接方式」。
  Widget _typeRow() {
    // R42：终端顶上的 SSH / MOSH 徽标能切换。不写「切网不断」——X10 还没在真机上证实。
    // Mosh 怎么连、要装什么原来是选项下面常驻的一段，也收进这里（docs/dev/ui-text.md）。
    final hint = switch (protocol) {
      HostProtocol.ssh => _hint([
          localized('建议先用 SSH，连上后点终端顶上的「SSH」徽标能切到 Mosh。'),
          localized('上面选的 SSH / Mosh 只管网络这一段怎么走；断开以后远端程序还在不在，要看它跑在哪。'),
          ..._persistenceLines().map(localized),
        ]),
      HostProtocol.mosh => _hint([
          localized('建议先用 SSH，连上后点终端顶上的「SSH」徽标能切到 Mosh。'),
          localized(
              'Mosh 先用 SSH 登录这台主机、在上面启动 mosh-server，然后断开 SSH，改由 Mosh 插件经 UDP 直连。要先装好 Mosh 插件并在「设置 → 插件（实验）」批准；服务器上要有 mosh-server，没有时连接会停下、给出安装命令。只能直连：UDP 走不了代理和跳板机。'),
          localized('上面选的 SSH / Mosh 只管网络这一段怎么走；断开以后远端程序还在不在，要看它跑在哪。'),
          ..._persistenceLines().map(localized),
        ]),
      _ => null,
    };
    return Row(
      children: [
        Expanded(
          child: InkWell(
            key: const ValueKey('host-protocol'),
            onTap: _pickType,
            child: InputDecorator(
              decoration: LInputDecoration(
                labelText: '连接类型',
                prefixIcon: Icon(hostProtocolIcon(protocol)),
                suffixIcon: const Icon(Icons.arrow_drop_down),
              ),
              child: switch (protocol) {
                HostProtocol.mosh => const Text('Mosh'),
                HostProtocol.telnet => const Text('Telnet'),
                HostProtocol.plugin => const LText('终端插件'),
                _ => const Text('SSH'),
              },
            ),
          ),
        ),
        if (hint != null)
          HintButton(
            key: const ValueKey('protocol-advice'),
            title: '连接类型',
            message: hint,
          ),
      ],
    );
  }

  Future<void> _pickType() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final choice = await showConnectionTypeSheet(
      context,
      current: protocol,
      currentPluginId: pluginId,
      terminalsOnly: widget.onOtherType == null,
    );
    if (choice == null || !mounted) return;
    final next = choice.protocol;
    if (next == null) {
      // 填了的东西带不过去：换到外部 App 或 Tailscale 等于放弃这张表。
      if (_dirty && !await _confirmDiscard()) return;
      if (!mounted) return;
      widget.onOtherType!(choice);
      Navigator.pop(context);
      return;
    }
    setState(() {
      protocol = next;
      if (next == HostProtocol.plugin) pluginId = choice.pluginId ?? pluginId;
      if (port.text == '22' || port.text == '23') {
        port.text = next == HostProtocol.telnet ? '23' : '22';
      }
    });
  }

  bool get _moshFilled => [moshServerPath, moshPorts, moshLocale]
      .any((c) => c.text.trim().isNotEmpty);
  bool get _timeoutsFilled => [keepalive, connectTimeout, authTimeout]
      .any((c) => c.text.trim().isNotEmpty);
  bool get _startupFilled => startupCommand.text.trim().isNotEmpty;
  bool get _organizeFilled =>
      group.text.trim().isNotEmpty || tags.text.trim().isNotEmpty || pinned;
  bool get _routeSet => route.usesProxy || route.jumpHostIds.isNotEmpty;
  bool get _hasCatalog =>
      widget.host != null && CatalogBinding.of(widget.host!) != null;

  Set<String> _filledGroups() => {
        if (_routeSet) 'route',
        if (_moshFilled) 'mosh',
        if (_timeoutsFilled) 'timeouts',
        if (_startupFilled) 'startup',
        if (_organizeFilled) 'organize',
      };

  void _toggle(String group) => setState(() {
        if (!_expanded.remove(group)) _expanded.add(group);
      });

  /// 收着的「高级」下面那一行：设过什么就写什么，不用点开就知道这台走不走代理。没设过就写里面有什么，
  /// 要找代理的人才知道该点这里。
  String get _advancedSummary {
    final set = [
      if (route.usesProxy) localized('代理'),
      if (route.jumpHostIds.isNotEmpty) localized('跳板机'),
      if (protocol == HostProtocol.mosh && _moshFilled) localized('Mosh 启动参数'),
      if (protocol == HostProtocol.ssh && _startupFilled) localized('启动命令'),
      if (_sshLike && _timeoutsFilled) localized('超时与保活'),
      if (_organizeFilled) localized('分组和标签'),
    ];
    if (set.isNotEmpty) return set.join(' · ');
    return protocol == HostProtocol.plugin ? '分组和标签' : '连接路径、分组和标签等';
  }

  bool get _sshLike =>
      protocol == HostProtocol.ssh || protocol == HostProtocol.mosh;

  /// 这台配了代理或跳板，而现在的类型用不了：必须摆在用户面前，不能收着。
  /// Mosh 会报错、保存不了；Telnet 保存时会把它们去掉。
  bool _routeForced(
    ({RoutePlan? plan, String? error, List<String> warnings}) preview,
  ) =>
      _routeSet &&
      (protocol == HostProtocol.telnet ||
          (_sshLike && preview.error != null && !_quiet));

  bool _advancedVisible(
    ({RoutePlan? plan, String? error, List<String> warnings}) preview,
  ) =>
      _advancedOpen || _routeForced(preview);

  bool _routeVisible(
    ({RoutePlan? plan, String? error, List<String> warnings}) preview,
  ) =>
      _routeForced(preview) || (_advancedOpen && _expanded.contains('route'));

  /// 代理、跳板那一组收起时的状态。
  String get _routeState => protocol == HostProtocol.telnet
      ? '仅直连'
      : switch ((route.usesProxy, route.jumpHostIds.isNotEmpty)) {
          (true, true) => '经代理和跳板机',
          (true, false) => '经代理',
          (false, true) => '经跳板机',
          (false, false) => '直连',
        };

  /// 高级选项按组折叠（R41）。填过值的组展开高级后就是开着的；没填的写「自动」，输入框里也不预填默认值。
  /// 收起的组只是不显示，字段仍在表单里参与校验；校验没过时 [_checkedDraft] 把填过值的组展开。
  List<Widget> _advancedGroups(
    VaultState vaultState,
    ({RoutePlan? plan, String? error, List<String> warnings}) preview,
  ) =>
      [
        if (protocol == HostProtocol.telnet)
          _AdvancedGroup(
            id: 'route',
            title: '连接路径',
            state: _routeState,
            filled: false,
            expanded: _routeVisible(preview),
            onToggle: () => _toggle('route'),
            children: [
              const LText(
                'Telnet 只能直连；保存时会去掉这台主机的代理和跳板。',
                key: ValueKey('telnet-direct-only'),
              ),
              _routePreview(preview),
            ],
          ),
        if (_sshLike)
          _AdvancedGroup(
            id: 'route',
            title: '连接路径',
            hint: '手机 →（代理）→（跳板机）→ 目标。代理只用于手机连第一跳，之后由上一台跳板转发。跳板机要先存成普通 SSH 主机。',
            state: _routeState,
            filled: false,
            expanded: _routeVisible(preview),
            onToggle: () => _toggle('route'),
            children: [
              ConnectionRouteEditor(
                canConfirmRoutes: !vaultState.loading &&
                    vaultState.error == null &&
                    !vaultState.unreadableSecrets.any((key) =>
                        key.startsWith('proxy.') ||
                        key.endsWith('.proxyPassword')),
                draft: route,
                hosts: vaultState.data?.hosts ?? const [],
                profiles: vaultState.data?.proxyProfiles ?? const [],
                targetHostId: widget.host?.id,
                plan: preview.plan,
                error: _quiet ? null : preview.error,
                warnings: preview.warnings,
                targetLabel: _labelOrAddress,
                targetDetail: hostname.text.trim().isEmpty
                    ? ''
                    : '${_shownUsername()}@${hostname.text}:${port.text}',
                onSelectProxy: (inline) => selectRouteProxy(context, inline),
                onManageProxies: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ProxyProfilesPage())),
                onChanged: _refresh,
              ),
            ],
          ),
        if (protocol == HostProtocol.mosh)
          _AdvancedGroup(
            id: 'mosh',
            title: 'Mosh 启动参数',
            hint: _hint([
              localized('建议留空让 App 自动处理；连接时报错、提示要改这里再填。'),
              _fieldHint('mosh-server 路径',
                  '留空就先按 PATH 找，再查 /usr/bin、/usr/local/bin、/opt/homebrew/bin、~/.local/bin、nix profile。装在别处、连接时报「没有找到 mosh-server」才填，如 /opt/mosh/bin/mosh-server。'),
              _fieldHint('Mosh UDP 端口范围',
                  'mosh-server 只在这个范围里挑 UDP 端口。服务器或防火墙只放行了某几个端口时填它，比如 60001 或 60001:60010。'),
              _fieldHint('Mosh locale',
                  '留空用 en_US.UTF-8。连接时报「没有可用的 UTF-8 语言环境」才填服务器上有的，比如 C.UTF-8。'),
            ]),
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
                ),
                validator: _validMoshServerPath,
              ),
              const FormGap(),
              TextFormField(
                key: const ValueKey('mosh-ports'),
                controller: moshPorts,
                decoration: LInputDecoration(
                  labelText: 'Mosh UDP 端口范围',
                  hintText: '自动（60001:60999）',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
                validator: _validMoshPorts,
              ),
              const FormGap(),
              TextFormField(
                key: const ValueKey('mosh-locale'),
                controller: moshLocale,
                decoration: LInputDecoration(
                  labelText: 'Mosh locale',
                  hintText: '自动（en_US.UTF-8）',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
                validator: _validMoshLocale,
              ),
            ],
          ),
        if (protocol == HostProtocol.ssh)
          _AdvancedGroup(
            id: 'startup',
            title: '启动命令',
            hint: localized('连上后在 shell 里执行一次；断线恢复时不会再执行。'),
            filled: _startupFilled,
            state: _startupFilled ? null : '未填写',
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
        if (_sshLike)
          _AdvancedGroup(
            id: 'timeouts',
            title: '超时与保活',
            // Mosh 只在启动 mosh-server 那段用 SSH，之后的 UDP 会话自己保活：这三项管不到它。
            hint: _hint([
              localized(protocol == HostProtocol.mosh
                  ? '只管启动 mosh-server 前那段 SSH 登录；之后的 Mosh 会话自己保活，不用这里的值。'
                  : '一般不用改。网络很慢、经多跳代理时连接总超时，再把超时调大。'),
              _fieldHint('Keepalive 间隔', '每隔多少秒发送一次保活消息'),
              _fieldHint('连接超时', '建立 TCP 连接的最长等待时间'),
              _fieldHint('认证超时', 'SSH 身份认证的最长等待时间'),
            ]),
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
                      fallback: _defaultKeepalive,
                    ),
                    _AdvancedNumberField(
                      controller: connectTimeout,
                      label: '连接超时',
                      fallback: _defaultConnectTimeout,
                    ),
                    _AdvancedNumberField(
                      controller: authTimeout,
                      label: '认证超时',
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
                        if (index < fields.length - 1)
                          const SizedBox(width: 12),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        _AdvancedGroup(
          id: 'organize',
          title: '分组和标签',
          filled: _organizeFilled,
          state: _organizeFilled ? null : '未填写',
          expanded: _expanded.contains('organize'),
          onToggle: () => _toggle('organize'),
          children: [
            TextFormField(
              controller: group,
              decoration: LInputDecoration(labelText: '分组（可选）'),
            ),
            const FormGap(),
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
          ],
        ),
        if (_sshLike && _hasCatalog)
          CatalogSourceSection(
            host: widget.host!,
            currentHostname: hostname.text.trim(),
            unlinked: unlinkCatalog,
            onUnlinkChanged: (value) => setState(() => unlinkCatalog = value),
          ),
      ];

  /// 连接方式和「断开后程序还在不在」是两回事（R41，借鉴 meshTerm 的持久性说明）。
  /// 这里只说明，不存会话名：按名字自动附着会碰到 tmux 的前缀匹配，选会话按 R21 的完整目标在终端里做。
  /// 不能写「重连就恢复原来的 shell」：普通 SSH 重连拿到的是新 shell。
  List<String> _persistenceLines() {
    return protocol == HostProtocol.mosh
        ? const [
            '从主机列表直接连 Mosh，开的是 mosh-server 里的普通 shell。关标签或服务器重启时，mosh-server 和里面的程序一起结束；「重新连接」是新起的 mosh-server，接不回原来那个。',
            '想断开后程序还在：先用 SSH 连上，在「性能监控 → tmux」里附着一个 tmux 会话，再点终端顶上的徽标切到 Mosh——还是同一个 tmux 会话。这样的 Mosh 标签断了，点「重新连接」会核对后附着回那个会话。',
            'App 里留着的终端画面只是这台手机上的历史，不代表远端还开着。',
          ]
        : const [
            '普通 shell：现在连这台主机开的都是它。连接一断，shell 和里面前台的程序一起结束；重新连接得到的是一个新 shell，不是原来那个。',
            'tmux 会话：程序跑在服务器上的 tmux 里，连接断了也继续跑。连上后在终端快捷键栏「性能监控 → tmux」里选一个已有会话附着；认的是那个会话本身，同名新建的不会被当成它，也不会悄悄新建。',
            'App 里留着的终端画面只是这台手机上的历史，不代表远端还开着。',
            '「测试连接」会只读查一次远端有没有 tmux、有几个会话，不新建、不附着。',
          ];
  }

  /// ⓘ 里的几段：逐段本地化再拼，拼好的整段在英文表里查不到。
  static String _hint(List<String> paragraphs) => paragraphs.join('\n\n');

  /// ⓘ 里的一段「字段名：什么时候填」。原来挂在输入框下面，页面上只留字段名和默认值。
  static String _fieldHint(String label, String helper) =>
      '${localized(label)}：${localized(helper)}';

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
    if (preview.error != null && !_quiet) {
      return (
        icon: Icons.error_outline,
        text: '按上面红字改好才能保存',
        color: scheme.error,
      );
    }
    // 只写状态：旁边就是「测试连接」按钮，它测什么写在使用手册第 4 节。
    return switch (protocol) {
      HostProtocol.plugin => (
          icon: info,
          text: '插件自己联网，这里测不了',
          color: null,
        ),
      HostProtocol.telnet => (
          icon: info,
          text: '保存后连一次才知道通不通',
          color: null,
        ),
      HostProtocol.mosh => (
          icon: info,
          text: 'Mosh 连接时才验证',
          color: null,
        ),
      _ when widget.verifyHostKey == null => (
          icon: unknown,
          text: '未验证',
          color: null,
        ),
      _ when _verifiedSignature == _signature(_draft()) => (
          icon: Icons.verified_outlined,
          text: '已验证',
          color: scheme.primary,
        ),
      _ when _verifiedSignature != null => (
          icon: unknown,
          text: '未验证：测试后改过',
          color: null,
        ),
      _ => (
          icon: unknown,
          text: '未验证',
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
    'identityId',
    sshLoginModeKey,
    'proxyProfileId',
    'proxyConfig',
    'hostChain',
  ];

  String _signature(HostProfile host) =>
      jsonEncode({for (final key in _verifiedKeys) key: host.data[key]});

  bool get _dirty => _comparable(_draft()) != _initialSnapshot;

  /// 拿来比「有没有改」的样子。新建主机的 createdAt 是每次拼草稿时的当前时间，不去掉的话
  /// 一个字没填、按返回也会问「放弃没保存的改动？」（R25 大字号扫页时撞到的）。
  String _comparable(HostProfile draft) =>
      jsonEncode(Map<String, dynamic>.from(draft.data)..remove('createdAt'));

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
            '不发密码和私钥，由 Tailscale 按策略放行。要 check 时在浏览器里确认。',
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
            '已存的密码、私钥留着不用，改回普通 SSH 还能用。',
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
            '还没有能用的插件。装好后到「设置 → 插件（实验）」批准；Mosh 请选 Mosh 协议。',
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
        '插件自己联网，不走代理和跳板，也拿不到这台主机的地址和凭据。',
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

  Widget _section(String title, {String? hint, Key? hintKey}) {
    const style = TextStyle(fontWeight: FontWeight.w700, fontSize: 15);
    if (hint == null) {
      return Padding(
        // 下边留 16：紧跟的输入框浮动标签会往上占 8dp，留少了就压到分组标题。
        padding: const EdgeInsets.fromLTRB(2, 22, 2, 16),
        child: LText(title, style: style),
      );
    }
    // ⓘ 自带 48dp 高，上下边距收掉一些，和没有 ⓘ 的分组标题对齐。
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
      child: Row(
        children: [
          Flexible(child: LText(title, style: style)),
          HintButton(key: hintKey, title: title, message: hint),
        ],
      ),
    );
  }

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
          label: _labelOrAddress,
          hostname: hostname.text.trim(),
          username: username.text.trim(),
        );
    final data = Map<String, dynamic>.from(base.data)
      ..['label'] = _labelOrAddress
      ..['hostname'] = hostname.text.trim()
      ..['username'] = username.text.trim()
      ..['port'] = int.tryParse(port.text.trim()) ?? 0
      ..['protocol'] = protocol.name
      // 「只用私钥」但私钥已经删了：界面上没地方再选一把，按「用户名 / 密码」存。
      // Tailscale SSH 不用它，字段原样留着。
      ..['authMethod'] = loginMode == SshLoginMode.standard &&
              authMethod == HostAuthMethod.key &&
              identityFileId == null
          ? HostAuthMethod.auto.name
          : authMethod.name
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
    _setOrRemove(
      data,
      'identityId',
      _loginChoice == LoginChoice.credential ? identityId : null,
    );
    if (_chosenCredential case final credential?) {
      useCredentialOn(data, credential);
      // 凭据没写用户名时用表单里的。
      if (credential.username.isEmpty) data['username'] = username.text.trim();
    }
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
    // 和主机详情、真正连接用同一套路线计算。Mosh 配了代理、跳板在这里就报错：存下来也连不上，
    // 保存前就拦住（docs/02：不支持的路线不让保存）。
    final status = hostRouteStatus(
      _draft(),
      hosts: vault.hosts,
      proxyProfiles: vault.proxyProfiles,
      keys: vault.keys,
      identities: vaultIdentityMaps(vault),
    );
    final plan = status.plan;
    if (status.error != null || plan == null) {
      return (plan: plan, error: status.error, warnings: const []);
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

  /// 保存前的共同检查：表单必填项、选了「凭据」就要选中一个、路线要算得出来。
  /// 返回能用的草稿和路线；不能用时已经提示过原因，返回 null。
  ({HostProfile host, RoutePlan? plan})? _checkedDraft() {
    if (!_triedSave) setState(() => _triedSave = true);
    if (!(_form.currentState?.validate() ?? false)) {
      // 写错的值可能在收起的高级组里：写了东西的组都展开，红字才看得见。
      setState(() {
        _expanded.addAll(_filledGroups());
        // 只有这两组有校验。地址没填而已，不必把高级打开。
        if (_moshFilled || _timeoutsFilled) _advancedOpen = true;
      });
      return null;
    }
    if (protocol != HostProtocol.telnet &&
        protocol != HostProtocol.plugin &&
        _loginChoice == LoginChoice.credential &&
        _chosenCredential == null) {
      _message('选一个凭据，或者改成用户名 / 密码。');
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
    required this.fallback,
  });

  final TextEditingController controller;
  final String label;
  final int fallback;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: LInputDecoration(
          labelText: label,
          hintText: '自动（$fallback）',
          floatingLabelBehavior: FloatingLabelBehavior.always,
          suffixText: '秒',
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
    this.hint,
    required this.filled,
    required this.expanded,
    required this.onToggle,
    required this.children,
    this.state,
  });

  final String id;
  final String title;
  final String? hint;
  final bool filled;
  final bool expanded;

  /// 收起时标题下那一行。不给就按 [filled] 写「已填写」或「自动」；只有说明的组自己给。
  final String? state;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 说明在组名旁的 ⓘ 里，展开后页面上只有字段（docs/dev/ui-text.md）。
                HintTitle(title, hint: hint, style: theme.textTheme.titleSmall),
                LText(
                  state ?? (filled ? '已填写' : '自动'),
                  key: ValueKey('advanced-$id-state'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (children.isNotEmpty)
            Icon(expanded ? Icons.expand_less : Icons.expand_more),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (children.isEmpty)
          KeyedSubtree(key: ValueKey('advanced-$id'), child: header)
        else ...[
          InkWell(
            key: ValueKey('advanced-$id'),
            onTap: onToggle,
            child: header,
          ),
          Offstage(
            offstage: !expanded,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
        const Divider(height: 1),
      ],
    );
  }
}
