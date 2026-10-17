import 'package:flutter/material.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';

import '../../../infrastructure/ssh/system_management_service.dart';

/// 用户在 sudo 确认框里点了取消。没有对服务器做任何事，打印出来是当时的权限提示。
class SudoDeclined implements Exception {
  const SudoDeclined(this.request);

  final SudoRequired request;

  @override
  String toString() => request.message;
}

/// 跑 [action]；它报「要 sudo」时弹框问用户，同意了把密码（可能是空串：免密 sudo）交给 [grant]
/// 再跑。免密 sudo 不行会接着要密码，密码不对会再问，直到用户取消（抛 [SudoDeclined]）。
///
/// Docker、Compose、系统服务、Caddy 都走这里：权限不够时服务层不自己试 sudo，先由用户点头。
Future<T> runWithSudo<T>(
  BuildContext context,
  Future<T> Function() action,
  void Function(String password) grant,
) async {
  while (true) {
    try {
      return await action();
    } on SudoRequired catch (request) {
      if (!context.mounted) rethrow;
      final password = await showDialog<String>(
        context: context,
        builder: (context) => _SudoDialog(request: request),
      );
      if (password == null) throw SudoDeclined(request);
      grant(password);
    }
  }
}

class _SudoDialog extends StatefulWidget {
  const _SudoDialog({required this.request});

  final SudoRequired request;

  @override
  State<_SudoDialog> createState() => _SudoDialogState();
}

class _SudoDialogState extends State<_SudoDialog> {
  final _password = TextEditingController();
  var _obscure = true;

  bool get _optional => widget.request.passwordOptional;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_optional || _password.text.isNotEmpty) {
      Navigator.pop(context, _password.text);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: LText(_optional ? '用 sudo 再试？' : '需要 sudo 密码'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LText(widget.request.message),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('sudo-password'),
                controller: _password,
                autofocus: true,
                obscureText: _obscure,
                onSubmitted: (_) => _submit(),
                decoration: LInputDecoration(
                  labelText: 'sudo 密码',
                  helperText: _optional
                      ? '免密 sudo 的服务器可以留空；密码只在这次系统管理面板打开期间保留'
                      : '密码仅在本次系统管理面板打开期间保留',
                  helperMaxLines: 3,
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            key: const ValueKey('sudo-continue'),
            onPressed: _submit,
            child: LText(_optional ? '用 sudo 继续' : '继续'),
          ),
        ],
      );
}
