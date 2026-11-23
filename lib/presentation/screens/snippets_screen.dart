import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/fork_features.dart';
import '../../application/settings_controller.dart';
import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../ui/components.dart';
import '../widgets/empty_state.dart';
import '../widgets/form_gap.dart';
import '../widgets/hint.dart';

class SnippetsScreen extends ConsumerWidget {
  const SnippetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultControllerProvider).data;
    final snippets = vault?.snippets ?? const <CommandSnippet>[];
    return SafeArea(
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(ShunPageHeader.height),
          child: ShunPageHeader(
            title: localizedOf(context, '命令片段'),
            actions: [
              ShunBarButton(
                key: const ValueKey('snippet-add'),
                tooltip: localized('新建片段'),
                onPressed: () => _edit(context, ref),
                icon: Icons.add,
              ),
            ],
          ),
        ),
        body: snippets.isEmpty
            ? EmptyState(
                icon: Icons.code,
                title: '还没有命令片段',
                action: ShunButton(
                  key: const ValueKey('snippet-empty-add'),
                  icon: Icons.add,
                  label: '新建片段',
                  onPressed: () => _edit(context, ref),
                ),
              )
            : ListView(
                // 列表从浮动底栏底下滚过去，末尾留出它的高度。
                padding: EdgeInsets.fromLTRB(
                    16, 0, 16, 24 + prism.BottomInsetScope.of(context)),
                children: [
                  ShunSection(
                    children: [
                      for (final snippet in snippets)
                        ShunListRow(
                          key: ValueKey('snippet-${snippet.id}'),
                          leading: const Icon(Icons.code),
                          title: snippet.label,
                          // 命令原样显示，不翻译；最多两行。
                          details: Text(
                            snippet.command,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                          onTap: () {
                            final active =
                                ref.read(sessionControllerProvider).active;
                            if (active == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: LText('请先建立终端会话')),
                              );
                            } else {
                              try {
                                ref
                                    .read(sessionControllerProvider.notifier)
                                    .send(snippet.command,
                                        enter: snippet.autoRun);
                              } on TerminalTargetChangedException catch (error) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: LText(error.toString())),
                                );
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: LText('已发送到 ${active.host.label}'),
                                ),
                              );
                            }
                          },
                          trailing: PopupMenuButton<_SnippetAction>(
                            key: ValueKey('snippet-actions-${snippet.id}'),
                            tooltip: localized('片段操作'),
                            onSelected: (action) async {
                              switch (action) {
                                case _SnippetAction.edit:
                                  await _edit(context, ref, snippet);
                                  break;
                                case _SnippetAction.delete:
                                  await _delete(context, ref, snippet);
                                  break;
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: _SnippetAction.edit,
                                child: Row(
                                  children: [
                                    Icon(Icons.edit_outlined),
                                    SizedBox(width: 12),
                                    LText('编辑'),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                key: ValueKey('delete-snippet-${snippet.id}'),
                                value: _SnippetAction.delete,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.delete_outline,
                                      color:
                                          Theme.of(context).colorScheme.error,
                                    ),
                                    const SizedBox(width: 12),
                                    LText(
                                      '删除',
                                      style: TextStyle(
                                        color:
                                            Theme.of(context).colorScheme.error,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    CommandSnippet? snippet,
  ]) async {
    final label = TextEditingController(text: snippet?.label);
    final command = TextEditingController(text: snippet?.command);
    var autoRun = snippet?.autoRun ?? true;
    final result = await showModalBottomSheet<CommandSnippet>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            20,
            16,
            MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LText(
                snippet == null ? '新建命令片段' : '编辑命令片段',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const FormGap(),
              TextField(
                controller: label,
                decoration: LInputDecoration(labelText: '名称'),
              ),
              const FormGap(),
              TextField(
                controller: command,
                minLines: 4,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: LInputDecoration(labelText: '命令'),
              ),
              HintSwitchTile(
                key: const ValueKey('snippet-auto-run'),
                contentPadding: EdgeInsets.zero,
                title: '发送后立即执行',
                value: autoRun,
                onChanged: (value) => setState(() => autoRun = value),
              ),
              SizedBox(
                width: double.infinity,
                child: ShunButton(
                  key: const ValueKey('snippet-save'),
                  label: '保存',
                  onPressed: () {
                    if (label.text.trim().isEmpty ||
                        command.text.trim().isEmpty) {
                      return;
                    }
                    Navigator.pop(
                      context,
                      CommandSnippet({
                        ...?snippet?.data,
                        'id': snippet?.id ?? const Uuid().v4(),
                        'label': label.text.trim(),
                        'command': command.text,
                        'noAutoRun': !autoRun,
                        'kind': 'snippet',
                      }),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    await ref.read(vaultControllerProvider.notifier).upsertSnippet(result);
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    CommandSnippet snippet,
  ) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: const LText('删除命令片段？'),
            // 没开自动同步就不说「会传到其他设备」。
            content: LText(
              ref.read(forkFeaturesProvider).cloudSync &&
                      ref.read(settingsControllerProvider).autoSyncEnabled
                  ? '将删除“${snippet.label}”，此操作可通过云端备份传播到其他设备。'
                  : '将删除“${snippet.label}”，删了不能撤销。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                key: const ValueKey('confirm-delete-snippet'),
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                child: const LText('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final controller = ref.read(vaultControllerProvider.notifier);
    await controller.deleteSnippet(snippet.id);
  }
}

enum _SnippetAction { edit, delete }
