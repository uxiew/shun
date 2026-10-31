import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../domain/credential_identity.dart';
import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import 'form_gap.dart';
import 'secret_content.dart';

/// 新建或编辑「凭据」里的一个登录身份（R26 F25）。取消返回 null。
///
/// 存成桌面端 Netcatty 的格式（见 [IdentityProfile]）：「密钥 + 密码」就是带了密码的 `key`。
/// 编辑时不认识的字段原样留着；换掉登录方式时，用不到的密码或密钥引用会去掉，不留一份看不见的密码。
Future<Map<String, dynamic>?> editIdentity(
  BuildContext context, {
  IdentityProfile? existing,
  required List<SshKeyProfile> keys,
}) =>
    showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => SecretContent(
        child: _IdentityDialog(existing: existing, keys: keys),
      ),
    );

class _IdentityDialog extends StatefulWidget {
  const _IdentityDialog({required this.existing, required this.keys});

  final IdentityProfile? existing;
  final List<SshKeyProfile> keys;

  @override
  State<_IdentityDialog> createState() => _IdentityDialogState();
}

class _IdentityDialogState extends State<_IdentityDialog> {
  late final _label =
      TextEditingController(text: widget.existing?.data['label']?.toString());
  late final _username = TextEditingController(text: widget.existing?.username);
  late final _password = TextEditingController(text: widget.existing?.password);
  late var _auth = widget.existing?.auth ?? IdentityAuth.password;
  late String? _keyId = widget.existing?.keyId;
  var _obscure = true;
  var _tried = false;

  @override
  void dispose() {
    _label.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _usesKey => _auth != IdentityAuth.password;
  bool get _usesPassword => _auth != IdentityAuth.key;

  /// 和主机编辑器、导入一个规矩：空的或带空格、控制字符的用户名不收。
  String? get _usernameError {
    final name = _username.text.trim();
    if (name.isEmpty) return '必填';
    if (RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(name)) return '用户名不能有空格';
    return null;
  }

  String? get _keyError => _usesKey &&
          (_keyId == null || !widget.keys.any((key) => key.id == _keyId))
      ? '选一把 SSH 密钥'
      : null;

  /// 「密码」可以不填：连接时再问。「密钥 + 密码」必须填，不然它和「密钥」是一回事。
  String? get _passwordError =>
      _auth == IdentityAuth.keyAndPassword && _password.text.isEmpty
          ? '「密钥 + 密码」要填密码'
          : null;

  void _save() {
    setState(() => _tried = true);
    if (_usernameError != null || _keyError != null || _passwordError != null) {
      return;
    }
    final data = Map<String, dynamic>.from(widget.existing?.data ?? const {});
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
    return AlertDialog(
      title: LText(widget.existing == null ? '新建登录身份' : '编辑登录身份'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('identity-label'),
              controller: _label,
              decoration: LInputDecoration(labelText: '名称（可选，默认用用户名）'),
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
            const FormGap(),
            DropdownButtonFormField<IdentityAuth>(
              key: const ValueKey('identity-auth'),
              initialValue: _auth,
              isExpanded: true,
              decoration: LInputDecoration(labelText: '登录方式'),
              items: const [
                DropdownMenuItem(
                  value: IdentityAuth.password,
                  child: LText('密码'),
                ),
                DropdownMenuItem(
                  value: IdentityAuth.key,
                  child: LText('SSH 密钥'),
                ),
                DropdownMenuItem(
                  value: IdentityAuth.keyAndPassword,
                  child: LText('SSH 密钥 + 密码'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _auth = value ?? IdentityAuth.password),
            ),
            if (_auth == IdentityAuth.keyAndPassword) ...[
              const SizedBox(height: 6),
              LText(
                '服务器要求先过公钥、再输密码时用（sshd 配了 AuthenticationMethods publickey,password）。'
                '密钥自己的口令存在密钥上，不在这里。',
                style: hint,
              ),
            ],
            if (_usesKey) ...[
              const SizedBox(height: 10),
              if (widget.keys.isEmpty)
                LText(
                  '还没有 SSH 密钥。先在「凭据」里导入一把，再回来选。',
                  style: hint?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  key: const ValueKey('identity-key'),
                  initialValue: widget.keys.any((key) => key.id == _keyId)
                      ? _keyId
                      : null,
                  isExpanded: true,
                  decoration: LInputDecoration(
                    labelText: 'SSH 密钥',
                    errorText: _tried ? _keyError : null,
                  ),
                  items: [
                    for (final key in widget.keys)
                      DropdownMenuItem(
                        value: key.id,
                        child: Text(key.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) => setState(() => _keyId = value),
                ),
            ],
            if (_usesPassword) ...[
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('identity-password'),
                controller: _password,
                obscureText: _obscure,
                // 点小眼睛改成明文时也不让输入法学、不联想（R44）。
                enableIMEPersonalizedLearning: false,
                enableSuggestions: false,
                autocorrect: false,
                onChanged: (_) => setState(() {}),
                decoration: LInputDecoration(
                  labelText:
                      _auth == IdentityAuth.password ? '密码（可选，不填就连接时问）' : '密码',
                  errorText: _tried ? _passwordError : null,
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    tooltip: localized('显示或隐藏密码'),
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const LText('取消'),
        ),
        FilledButton(
          key: const ValueKey('identity-save'),
          onPressed: _save,
          child: const LText('保存'),
        ),
      ],
    );
  }
}
