import 'package:flutter/material.dart';

import '../../application/tailscale_catalog_refresh.dart';
import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import 'secret_content.dart';

/// 连接前要不要先问登录信息（R26 所有者：不是每台机器都用同一个用户和密码，Tailscale 导入时不统一填，
/// 单独连接时再配）：
/// - 没有用户名的 SSH / Mosh 主机：要问，不然只会拿空用户名去登录、被拒。
/// - 从目录导入、还没登录成功过、也没配密码和私钥的：用户名是来源的默认值，第一次连之前让人看一眼、顺便填密码。
///   登录成功过一次就不再问；之后没存密码的，连接时在「密码」那一步问（ssh_service）。
bool needsFirstLogin(HostProfile host) {
  if (host.protocol != HostProtocol.ssh && host.protocol != HostProtocol.mosh) {
    return false;
  }
  if (host.username.trim().isEmpty) return true;
  return CatalogBinding.of(host) != null &&
      host.lastConnectedAt == 0 &&
      host.password == null &&
      (host.identityFileId ?? '').isEmpty &&
      host.authMethod != HostAuthMethod.key;
}

/// 问用户名和密码。密码可以不填：用私钥登录，或者连接时再问。取消返回 null。
Future<({String username, String? password})?> askFirstLogin(
  BuildContext context,
  HostProfile host,
) =>
    showDialog<({String username, String? password})>(
      context: context,
      builder: (context) => _FirstLoginDialog(host: host),
    );

class _FirstLoginDialog extends StatefulWidget {
  const _FirstLoginDialog({required this.host});

  final HostProfile host;

  @override
  State<_FirstLoginDialog> createState() => _FirstLoginDialogState();
}

class _FirstLoginDialogState extends State<_FirstLoginDialog> {
  late final _username = TextEditingController(text: widget.host.username);
  final _password = TextEditingController();
  var _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 空的或带空格、控制字符的用户名不收（和编辑器、导入一个规矩）。
  bool get _valid {
    final name = _username.text.trim();
    return name.isNotEmpty && !RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(name);
  }

  void _submit() {
    if (!_valid) return;
    final password = _password.text;
    Navigator.pop(context, (
      username: _username.text.trim(),
      password: password.isEmpty ? null : password,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final small = Theme.of(context).textTheme.bodySmall;
    final address = '${host.hostname}:${host.port}';
    // 密码框：对话框开着时防截屏（R44）。
    return SecretContent(
      child: AlertDialog(
        key: const ValueKey('first-login-dialog'),
        title: LText('登录 ${host.label}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(address, style: small),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('first-login-username'),
                controller: _username,
                autofocus: host.username.trim().isEmpty,
                autocorrect: false,
                enableSuggestions: false,
                decoration: LInputDecoration(labelText: '用户名'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('first-login-password'),
                controller: _password,
                autofocus: host.username.trim().isNotEmpty,
                obscureText: _obscure,
                enableIMEPersonalizedLearning: false,
                enableSuggestions: false,
                autocorrect: false,
                decoration: LInputDecoration(
                  labelText: '密码（可不填）',
                  helperText: '填了就加密存在本机，以后不再问；不填就用私钥，或连接时再问',
                  helperMaxLines: 3,
                  suffixIcon: IconButton(
                    tooltip: localized(_obscure ? '显示密码' : '隐藏密码'),
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              LText('只给这一台。以后在主机的「编辑」里改。', style: small),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            key: const ValueKey('first-login-connect'),
            onPressed: _valid ? _submit : null,
            child: const LText('连接'),
          ),
        ],
      ),
    );
  }
}
