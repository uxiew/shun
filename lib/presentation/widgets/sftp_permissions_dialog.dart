import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import '../../infrastructure/ssh/sftp_service.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';

class SftpPermissionsDialog extends StatefulWidget {
  const SftpPermissionsDialog(
      {super.key, required this.name, required this.initialMode});
  final String name;
  final String initialMode;
  @override
  State<SftpPermissionsDialog> createState() => _SftpPermissionsDialogState();
}

class _SftpPermissionsDialogState extends State<SftpPermissionsDialog> {
  final _form = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initialMode);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const LText('修改文件权限'),
      content: SingleChildScrollView(
          child: Form(
              key: _form,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.name,
                        style: prism.AppTextStyle.headline.of(context)),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const ValueKey('sftp-permissions-input'),
                      controller: _controller,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      decoration: LInputDecoration(
                          labelText: 'Unix 权限',
                          hintText: '例如 644 或 0755',
                          errorMaxLines: 3),
                      validator: (value) =>
                          parseUnixPermissions(value ?? '') == null
                              ? localized('请输入 3 或 4 位八进制权限（0-7）')
                              : null,
                    ),
                    const SizedBox(height: 8),
                    LText(
                      '依次表示所有者、用户组和其他用户的读写执行权限',
                      key: const ValueKey('sftp-permissions-help'),
                      style: prism.AppTextStyle.footnote.of(context).copyWith(
                            color: prism.Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                  ]))),
      actions: [
        ShunButton(
          key: const ValueKey('sftp-permissions-cancel'),
          kind: ShunButtonKind.text,
          label: '取消',
          onPressed: () => Navigator.pop(context),
        ),
        ShunButton(
          key: const ValueKey('sftp-permissions-apply'),
          label: '应用',
          onPressed: () {
            if (_form.currentState?.validate() == true) {
              Navigator.pop(context, parseUnixPermissions(_controller.text));
            }
          },
        ),
      ],
    );
  }
}
