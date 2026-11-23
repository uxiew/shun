import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/credential_identity.dart';
import '../../domain/models/host.dart';
import '../../domain/security_key.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'credential_field.dart' show CredentialFields;
import 'form_gap.dart';
import 'secret_content.dart';
import 'security_key_actions.dart';
import 'ssh_key_import.dart';

/// 新建或编辑一个「凭据」（R26 F25、F31）。取消返回 null。
///
/// 存成桌面端 Netcatty 的格式（见 [IdentityProfile]）：「密钥 + 密码」就是带了密码的 `key`，
/// 安全密钥也是 `key`，`keyId` 指向那把安全密钥。
/// 编辑时不认识的字段原样留着；换掉登录方式时，用不到的密码或密钥引用会去掉，不留一份看不见的密码。
///
/// [draft] 是「存为凭据」带过来的内容：预填，但还没存过，所以仍算新建。
/// [passwordOnly] 给代理用：只能是用户名加存好的密码。
Future<Map<String, dynamic>?> editIdentity(
  BuildContext context, {
  IdentityProfile? existing,
  Map<String, dynamic>? draft,
  bool passwordOnly = false,
}) =>
    showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => SecretContent(
        child: _IdentityDialog(
          existing: existing,
          draft: draft,
          passwordOnly: passwordOnly,
        ),
      ),
    );

/// 编辑完存进保险库，返回凭据 id。取消返回 null。
Future<String?> editAndSaveIdentity(
  BuildContext context,
  WidgetRef ref, {
  IdentityProfile? existing,
  Map<String, dynamic>? draft,
  bool passwordOnly = false,
}) async {
  final controller = ref.read(vaultControllerProvider.notifier);
  // 等安全存储读完：对话框里要列出密钥。
  await controller.ready();
  if (!context.mounted) return null;
  final data = await editIdentity(
    context,
    existing: existing,
    draft: draft,
    passwordOnly: passwordOnly,
  );
  if (data == null) return null;
  await controller.saveIdentity(data);
  return data['id']?.toString();
}

/// 对话框里的四种登录方式。安全密钥在数据上就是 [IdentityAuth.key]，只是引用的密钥不一样，分开列才找得到。
enum _Kind { password, key, securityKey, keyAndPassword }

class _IdentityDialog extends ConsumerStatefulWidget {
  const _IdentityDialog({
    required this.existing,
    required this.draft,
    required this.passwordOnly,
  });

  final IdentityProfile? existing;
  final Map<String, dynamic>? draft;
  final bool passwordOnly;

  @override
  ConsumerState<_IdentityDialog> createState() => _IdentityDialogState();
}

class _IdentityDialogState extends ConsumerState<_IdentityDialog> {
  late final IdentityProfile? _initial = widget.existing ??
      (widget.draft == null ? null : IdentityProfile(widget.draft!));
  late final _label =
      TextEditingController(text: _initial?.data['label']?.toString());
  late final _username = TextEditingController(text: _initial?.username);
  late final _password = TextEditingController(text: _initial?.password);
  late _Kind _kind;
  late String? _keyId = _initial?.keyId;
  var _tried = false;

  @override
  void initState() {
    super.initState();
    final initial = _initial;
    final keys = _keys;
    _kind = initial == null || widget.passwordOnly
        ? _Kind.password
        : switch (initial.auth) {
            IdentityAuth.password => _Kind.password,
            IdentityAuth.keyAndPassword => _Kind.keyAndPassword,
            IdentityAuth.key => identityUsesSecurityKey(initial, keys)
                ? _Kind.securityKey
                : _Kind.key,
          };
  }

  @override
  void dispose() {
    _label.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  List<SshKeyProfile> get _keys =>
      ref.read(vaultControllerProvider).data?.keys ?? const [];

  bool get _usesKey => _kind != _Kind.password;
  bool get _usesPassword =>
      _kind == _Kind.password || _kind == _Kind.keyAndPassword;

  /// 选安全密钥只列安全密钥，选 SSH 密钥只列普通私钥。已经选中的那把一直列着：
  /// 桌面端可能建过「安全密钥 + 密码」，打开时不能显示成没选。
  List<SshKeyProfile> _choices(List<SshKeyProfile> keys) => [
        for (final key in keys)
          if (key.id == _keyId ||
              SecurityKeyStub.isStubPem(key.privateKey) ==
                  (_kind == _Kind.securityKey))
            key,
      ];

  void _changeKind(_Kind kind) => setState(() {
        _kind = kind;
        final key = _keys.where((value) => value.id == _keyId).firstOrNull;
        if (key != null &&
            SecurityKeyStub.isStubPem(key.privateKey) !=
                (kind == _Kind.securityKey)) {
          _keyId = null;
        }
      });

  Future<void> _addKey() async {
    final added = _kind == _Kind.securityKey
        ? (await addSecurityKey(context, ref)).firstOrNull
        : await importSshKey(context, ref);
    if (added != null && mounted) setState(() => _keyId = added.id);
  }

  /// 和主机编辑器、导入一个规矩：空的或带空格、控制字符的用户名不收。
  String? get _usernameError {
    final name = _username.text.trim();
    if (name.isEmpty) return '必填';
    if (RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(name)) return '用户名不能有空格';
    return null;
  }

  String? get _keyError =>
      _usesKey && (_keyId == null || !_keys.any((key) => key.id == _keyId))
          ? (_kind == _Kind.securityKey ? '选一把安全密钥' : '选一把 SSH 密钥')
          : null;

  /// 「密码」可以不填：连接时再问。「密钥 + 密码」必须填，不然它和「密钥」是一回事。
  /// 代理没法连接时问，也必须填。
  String? get _passwordError {
    if (_password.text.isNotEmpty) return null;
    if (_kind == _Kind.keyAndPassword) return '「密钥 + 密码」要填密码';
    return widget.passwordOnly ? '代理用的凭据要填密码' : null;
  }

  void _save() {
    setState(() => _tried = true);
    if (_usernameError != null || _keyError != null || _passwordError != null) {
      return;
    }
    final data = Map<String, dynamic>.from(_initial?.data ?? const {});
    data['id'] ??= const Uuid().v4();
    data['created'] ??= DateTime.now().millisecondsSinceEpoch;
    final username = _username.text.trim();
    final label = _label.text.trim();
    data['label'] = label.isEmpty ? username : label;
    data['username'] = username;
    if (_usesKey) {
      // 桌面端的证书身份（certificate）也是引用一把密钥，编辑时不把它改成 key。
      if (data['authMethod'] != 'certificate') data['authMethod'] = 'key';
      data['keyId'] = _keyId;
    } else {
      data['authMethod'] = 'password';
      data.remove('keyId');
    }
    if (_usesPassword && _password.text.isNotEmpty) {
      data['password'] = _password.text;
    } else {
      data.remove('password');
    }
    Navigator.pop(context, data);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).textTheme.bodySmall;
    final choices = _choices(
      ref.watch(vaultControllerProvider).data?.keys ?? const [],
    );
    final askable = _kind == _Kind.password && !widget.passwordOnly;
    return AlertDialog(
      title: LText(widget.existing == null ? '新建凭据' : '编辑凭据'),
      content: CredentialFields(
          inDialog: true,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('identity-label'),
                  controller: _label,
                  decoration: LInputDecoration(labelText: '名称（可选）'),
                ),
                const FormGap(),
                TextField(
                  key: const ValueKey('identity-username'),
                  controller: _username,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                  decoration: LInputDecoration(
                    labelText: '用户名',
                    errorText: _tried ? _usernameError : null,
                  ),
                ),
                if (!widget.passwordOnly) ...[
                  const FormGap(),
                  DropdownButtonFormField<_Kind>(
                    key: const ValueKey('identity-auth'),
                    initialValue: _kind,
                    isExpanded: true,
                    decoration: LInputDecoration(labelText: '登录方式'),
                    items: const [
                      DropdownMenuItem(
                        value: _Kind.password,
                        child: LText('密码'),
                      ),
                      DropdownMenuItem(
                        value: _Kind.key,
                        child: LText('SSH 密钥'),
                      ),
                      DropdownMenuItem(
                        value: _Kind.securityKey,
                        child: LText('安全密钥'),
                      ),
                      DropdownMenuItem(
                        value: _Kind.keyAndPassword,
                        child: LText('SSH 密钥 + 密码'),
                      ),
                    ],
                    onChanged: (value) => _changeKind(value ?? _Kind.password),
                  ),
                ],
                if (_kind == _Kind.keyAndPassword) ...[
                  const SizedBox(height: 6),
                  LText(
                    '要先过公钥、再输密码的服务器用。这里的密码不是密钥口令。',
                    style: hint,
                  ),
                ],
                if (_usesKey) ...[
                  const FormGap(),
                  if (choices.isNotEmpty)
                    // initialValue 只认第一次：刚导入的那把要显示成选中，得换 key。
                    KeyedSubtree(
                      key: ValueKey('identity-key-$_keyId-${_kind.name}'),
                      child: DropdownButtonFormField<String>(
                        key: const ValueKey('identity-key'),
                        initialValue: choices.any((key) => key.id == _keyId)
                            ? _keyId
                            : null,
                        isExpanded: true,
                        decoration: LInputDecoration(
                          labelText:
                              _kind == _Kind.securityKey ? '安全密钥' : 'SSH 密钥',
                          errorText: _tried ? _keyError : null,
                        ),
                        items: [
                          for (final key in choices)
                            DropdownMenuItem(
                              value: key.id,
                              child: Text(key.label,
                                  overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (value) => setState(() => _keyId = value),
                      ),
                    )
                  else if (_tried && _keyError != null)
                    LText(
                      _keyError!,
                      style: hint?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ShunButton(
                      key: const ValueKey('identity-add-key'),
                      kind: ShunButtonKind.text,
                      onPressed: _addKey,
                      icon: Icons.add,
                      label:
                          _kind == _Kind.securityKey ? '添加安全密钥' : '导入 SSH 私钥',
                    ),
                  ),
                ],
                if (_usesPassword) ...[
                  const FormGap(),
                  // 切成明文时三个输入法开关也一直关着（ShunSecretField 保证，R44）。
                  ShunSecretField(
                    key: const ValueKey('identity-password'),
                    controller: _password,
                    label: askable ? '密码（可选）' : '密码',
                    helperText: askable ? '不填就连接时问' : null,
                    errorText: _tried ? _passwordError : null,
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ],
            ),
          )),
      actions: [
        ShunButton(
          key: const ValueKey('identity-cancel'),
          kind: ShunButtonKind.text,
          onPressed: () => Navigator.pop(context),
          label: '取消',
        ),
        ShunButton(
          key: const ValueKey('identity-save'),
          onPressed: _save,
          label: '保存',
        ),
      ],
    );
  }
}
