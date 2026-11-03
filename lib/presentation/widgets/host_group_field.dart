import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/vault_controller.dart';
import '../localization/localized_widgets.dart';

/// 选这台放哪个分组：列出已有的，没有合适的当场新建。
///
/// 不让直接打字：以前是个输入框，打错一个字就多出一个组，「生产」和「生产 」连接页上是两个筛选。
/// 分组不单独存，就是主机上的一个名字；组里最后一台移走，这个组也就没了。
class HostGroupField extends ConsumerWidget {
  const HostGroupField({super.key, required this.value, required this.onChanged});

  /// 空字符串是不分组。
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) => InkWell(
        onTap: () => _pick(context, ref),
        child: InputDecorator(
          decoration: LInputDecoration(
            labelText: '分组',
            suffixIcon: const Icon(Icons.arrow_drop_down),
          ),
          child: value.isEmpty
              ? const LText('不分组')
              : Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      );

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final hosts = ref.read(vaultControllerProvider).data?.hosts ?? const [];
    final counts = <String, int>{};
    for (final host in hosts) {
      final name = host.group?.trim() ?? '';
      if (name.isNotEmpty) counts[name] = (counts[name] ?? 0) + 1;
    }
    final names = counts.keys.toList()..sort();
    final choice = await showModalBottomSheet<_GroupChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          ListTile(
            key: const ValueKey('host-group-none'),
            leading: const Icon(Icons.folder_off_outlined),
            title: const LText('不分组'),
            trailing: value.isEmpty ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, const _GroupChoice('')),
          ),
          for (final name in names)
            ListTile(
              key: ValueKey('host-group-option-$name'),
              leading: const Icon(Icons.folder_outlined),
              title: Text(name),
              subtitle: LText(
                localized('{n} 台主机').replaceAll('{n}', '${counts[name]}'),
              ),
              trailing: name == value ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, _GroupChoice(name)),
            ),
          ListTile(
            key: const ValueKey('host-group-new'),
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const LText('新建分组'),
            onTap: () => Navigator.pop(context, const _GroupChoice.create()),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    final name = choice.create
        ? await showDialog<String>(
            context: context,
            builder: (_) => const _NewGroupDialog(),
          )
        : choice.name;
    if (name != null) onChanged(name);
  }
}

class _GroupChoice {
  const _GroupChoice(this.name) : create = false;
  const _GroupChoice.create()
      : name = '',
        create = true;
  final String name;
  final bool create;
}

class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog();

  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const LText('新建分组'),
        content: TextField(
          key: const ValueKey('host-group-new-name'),
          controller: _name,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _create(),
          decoration: LInputDecoration(labelText: '组名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            key: const ValueKey('host-group-new-save'),
            onPressed: _name.text.trim().isEmpty ? null : _create,
            child: const LText('创建'),
          ),
        ],
      );
}
