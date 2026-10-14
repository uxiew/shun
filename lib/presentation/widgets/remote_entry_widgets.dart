import 'package:flutter/material.dart';
import '../../domain/remote_entry.dart';
import '../localization/localized_widgets.dart';

Future<String?> remoteEntryName(BuildContext context, {String? initial}) =>
    showDialog<String>(context: context, builder: (_) => _NameDialog(initial));

class _NameDialog extends StatefulWidget {
  const _NameDialog(this.initial);
  final String? initial;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _form = GlobalKey<FormState>();
  late final _text = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: LText(widget.initial == null ? '新建远控连接' : '重命名'),
        content: Form(
            key: _form,
            child: TextFormField(
              key: const ValueKey('remote-entry-name'),
              controller: _text,
              autofocus: true,
              maxLength: 200,
              decoration: LInputDecoration(labelText: '名称'),
              validator: (value) =>
                  value?.trim().isNotEmpty == true ? null : localized('请填写名称'),
            )),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const LText('取消')),
          FilledButton(
              key: const ValueKey('remote-entry-save'),
              onPressed: () {
                if (_form.currentState!.validate()) {
                  Navigator.pop(context, _text.text.trim());
                }
              },
              child: const LText('保存')),
        ],
      );
}

class RemoteEntryActions extends StatefulWidget {
  const RemoteEntryActions({
    super.key,
    required this.entry,
    required this.rename,
    required this.delete,
  });
  final RemoteEntry entry;
  final Future<void> Function(String) rename;
  final Future<void> Function() delete;
  @override
  State<RemoteEntryActions> createState() => _RemoteEntryActionsState();
}

class _RemoteEntryActionsState extends State<RemoteEntryActions> {
  bool _busy = false;
  Future<void> _act(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (action == 'rename') {
        final name = await remoteEntryName(
          context,
          initial: widget.entry.label,
        );
        if (name != null && mounted) await widget.rename(name);
      } else {
        final yes = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const LText('删除远控连接？'),
            content: const LText(
              '只删除本机条目和绑定，并作废它的待回调；不影响 SSH、其他远控连接或外部 App。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const LText('删除'),
              ),
            ],
          ),
        );
        if (yes == true && mounted) {
          await widget.delete();
          if (mounted) Navigator.pop(context);
        }
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: LText('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        key: const ValueKey('remote-entry-actions'),
        enabled: !_busy,
        onSelected: _act,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: LText('重命名')),
          PopupMenuItem(value: 'delete', child: LText('删除远控连接')),
        ],
      );
}

class RemoteEntryTile extends StatelessWidget {
  const RemoteEntryTile({
    super.key,
    required this.entry,
    required this.provider,
    required this.onOpen,
    this.status,
  });
  final RemoteEntry entry;
  final String provider;
  final VoidCallback onOpen;
  final String? status;
  @override
  Widget build(BuildContext context) => ListTile(
        key: ValueKey('remote-$provider-${entry.id}'),
        leading: Icon(
          provider == 'RustDesk'
              ? Icons.connected_tv_outlined
              : Icons.desktop_windows_outlined,
        ),
        title: Text(entry.label),
        subtitle: LText('$provider · ${status ?? '仅本机保存'}'),
        onTap: onOpen,
      );
}
