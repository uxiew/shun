import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/tailscale_catalog_refresh.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'connection_endpoint_fields.dart';
import 'credential_field.dart';
import 'form_gap.dart';
import 'no_intrinsics.dart';
import 'secret_content.dart';
import '../../domain/credential_identity.dart';

/// 连接前要不要先问登录信息（R26 所有者：不是每台机器都用同一个用户和密码，Tailscale 导入时不统一填，
/// 单独连接时再配）：
/// - 没有用户名的 SSH / Mosh 主机：要问，不然只会拿空用户名去登录、被拒。
/// - 从目录导入、还没登录成功过、也没配密码和私钥的：用户名是来源的默认值，第一次连之前让人看一眼、顺便填密码。
///   登录成功过一次就不再问；之后没存密码的，连接时在「密码」那一步问（ssh_service）。
///
/// 主机引用了「凭据」时按展开后的看（R26 F25）：选了凭据就算配好了，凭据没存密码的连接时问。
bool needsFirstLogin(
  HostProfile stored, {
  List<Map<String, dynamic>> identities = const [],
}) {
  final host = HostProfile(Map<String, dynamic>.from(stored.data));
  applyHostIdentity(host.data, identities);
  if (host.protocol != HostProtocol.ssh && host.protocol != HostProtocol.mosh) {
    return false;
  }
  if (host.username.trim().isEmpty) return true;
  if (hostIdentity(stored, identities) != null) return false;
  return CatalogBinding.of(host) != null &&
      host.lastConnectedAt == 0 &&
      host.password == null &&
      (host.identityFileId ?? '').isEmpty &&
      host.authMethod != HostAuthMethod.key;
}

/// 首次登录填的东西。[identity] 不是 null 就是选了凭据，不然是直接填的用户名和密码。
typedef FirstLogin = ({
  String username,
  String? password,
  IdentityProfile? identity,
});

/// 问用户名和密码，或者选一个凭据。密码可以不填：连接时再问。取消返回 null。
Future<FirstLogin?> askFirstLogin(BuildContext context, HostProfile host) =>
    showDialog<FirstLogin>(
      context: context,
      builder: (context) => _FirstLoginDialog(host: host),
    );

/// 把首次登录填的写回这一台。
HostProfile hostWithFirstLogin(HostProfile host, FirstLogin login) {
  final data = {
    ...host.data,
    'username': login.username,
    if (login.password != null) 'password': login.password,
  };
  if (login.identity case final identity?) useCredentialOn(data, identity);
  return HostProfile(data);
}

class _FirstLoginDialog extends ConsumerStatefulWidget {
  const _FirstLoginDialog({required this.host});

  final HostProfile host;

  @override
  ConsumerState<_FirstLoginDialog> createState() => _FirstLoginDialogState();
}

class _FirstLoginDialogState extends ConsumerState<_FirstLoginDialog> {
  late final _username = TextEditingController(text: widget.host.username);
  final _password = TextEditingController();
  var _choice = LoginChoice.simple;
  String? _identityId;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  IdentityProfile? get _identity {
    final vault = ref.read(vaultControllerProvider).data;
    if (_choice != LoginChoice.credential || vault == null) return null;
    return vaultIdentities(vault)
        .where((item) => item.id == _identityId)
        .firstOrNull;
  }

  /// 选了凭据就不用填用户名；桌面端建的凭据可能没写用户名，那还得填。
  bool get _needsUsername =>
      _choice == LoginChoice.simple || _identity?.username.isEmpty == true;

  /// 空的或带空格、控制字符的用户名不收（和编辑器、导入一个规矩）。
  bool get _valid {
    if (_choice == LoginChoice.credential && _identity == null) return false;
    if (!_needsUsername) return true;
    final name = _username.text.trim();
    return name.isNotEmpty && !RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(name);
  }

  void _submit() {
    if (!_valid) return;
    final identity = _identity;
    final password = identity == null ? _password.text : '';
    Navigator.pop<FirstLogin>(context, (
      username: _username.text.trim(),
      password: password.isEmpty ? null : password,
      identity: identity,
    ));
  }

  @override
  Widget build(BuildContext context) {
    // 当场新建的凭据写进保险库以后，「连接」按钮要跟着变。
    ref.watch(vaultControllerProvider);
    final host = widget.host;
    final small = Theme.of(context).textTheme.bodySmall;
    final address = '${host.hostname}:${host.port}';
    // 密码框：对话框开着时防截屏（R44）。
    return SecretContent(
      child: AlertDialog(
        key: const ValueKey('first-login-dialog'),
        title: LText('登录 ${host.label}'),
        content: ConnectionFieldTheme(
            dialog: true,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(address, style: small),
                  const FormGap(),
                  // 分段选择里有 LayoutBuilder，AlertDialog 的固有尺寸测量过不去（见 NoIntrinsics）。
                  NoIntrinsics(
                    child: LoginChoiceField(
                      key: const ValueKey('first-login-mode'),
                      value: _choice,
                      onChanged: (value) => setState(() => _choice = value),
                    ),
                  ),
                  if (_choice == LoginChoice.credential) ...[
                    const FormGap(),
                    CredentialField(
                      key: const ValueKey('first-login-credential'),
                      value: _identityId,
                      onChanged: (id) => setState(() => _identityId = id),
                    ),
                  ],
                  if (_needsUsername) ...[
                    const FormGap(),
                    TextField(
                      key: const ValueKey('first-login-username'),
                      controller: _username,
                      autofocus: host.username.trim().isEmpty,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: LInputDecoration(labelText: '用户名'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                  if (_choice == LoginChoice.simple) ...[
                    const FormGap(),
                    // 切成明文时三个输入法开关也一直关着、不让输入法学（ShunSecretField 保证，R44）。
                    ShunSecretField(
                      key: const ValueKey('first-login-password'),
                      controller: _password,
                      autofocus: host.username.trim().isNotEmpty,
                      label: '密码（可不填）',
                      helperText: '填了加密存本机，不填就连接时问',
                      onSubmitted: (_) => _submit(),
                    ),
                  ],
                  const SizedBox(height: 8),
                  LText('只给这一台。以后在主机的「编辑」里改。', style: small),
                ],
              ),
            )),
        actions: [
          ShunButton(
            key: const ValueKey('first-login-cancel'),
            kind: ShunButtonKind.text,
            onPressed: () => Navigator.pop(context),
            label: '取消',
          ),
          ShunButton(
            key: const ValueKey('first-login-connect'),
            onPressed: _valid ? _submit : null,
            label: '连接',
          ),
        ],
      ),
    );
  }
}
