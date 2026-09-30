import 'package:flutter/material.dart';

import '../../application/vault_import.dart';
import '../localization/localized_widgets.dart';

/// 导入前的确认框：说清楚会新增、更新、删除什么，哪些凭据要重新填。返回用户选的方式，取消返回 null。
///
/// 本机有独有条目时才出现「替换」，而且不是默认按钮：替换会连同密码和私钥一起删，
/// 导出文件又不带凭据，删了就找不回来。主机名等用户数据用普通 Text 显示，不走翻译。
Future<VaultImportMode?> confirmVaultImport(
  BuildContext context,
  VaultImportPlan plan,
) {
  final theme = Theme.of(context);
  final fileHosts = plan.incoming.hosts.length;
  final added = plan.addedHosts.length;
  final updated = plan.updatedHosts.length;
  final summary =
      '文件里有 $fileHosts 台主机：本机没有的 $added 台会新增，本机已有的 $updated 台以文件为准更新。';
  final localOnly = <(String, List<String>)>[
    ('主机', [for (final value in plan.localOnlyHosts) value.label]),
    ('私钥', [for (final value in plan.localOnlyKeys) value.label]),
    ('代理配置', [for (final value in plan.localOnlyProxies) value.label]),
    ('命令片段', [for (final value in plan.localOnlySnippets) value.label]),
  ].where((row) => row.$2.isNotEmpty);
  final keys = [for (final value in plan.keysWithoutMaterial) value.label];
  return showDialog<VaultImportMode>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.file_download_outlined),
      title: const LText('导入保险库文件'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LText(summary),
            if (plan.hasLocalOnly) ...[
              const SizedBox(height: 12),
              const LText(
                '本机有、文件里没有的：',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final (label, names) in localOnly)
                _NamedCount(label: label, names: names),
              const SizedBox(height: 4),
              LText(
                '选「合并」会保留它们。选「替换」会把它们连同密码和私钥一起删除，之后再导入不带凭据的备份也找不回来。',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            if (plan.credentialsNotCarried.isNotEmpty) ...[
              const SizedBox(height: 12),
              const LText('这些条目的地址、端口或用户名和本机不同，本机存的密码不会沿用，导入后要重新填：'),
              Text(plan.credentialsNotCarried.join('、')),
            ],
            if (keys.isNotEmpty) ...[
              const SizedBox(height: 12),
              const LText('这些私钥在文件里只有名字、没有内容（本 App 导出的文件不带私钥），导入后要重新导入私钥：'),
              Text(keys.join('、')),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('vault-import-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const LText('取消'),
        ),
        if (plan.hasLocalOnly)
          TextButton(
            key: const ValueKey('vault-import-replace'),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, VaultImportMode.replace),
            child: const LText('替换'),
          ),
        FilledButton(
          key: const ValueKey('vault-import-merge'),
          onPressed: () => Navigator.pop(context, VaultImportMode.merge),
          child: LText(plan.hasLocalOnly ? '合并' : '导入'),
        ),
      ],
    ),
  );
}

class _NamedCount extends StatelessWidget {
  const _NamedCount({required this.label, required this.names});

  final String label;
  final List<String> names;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: localized(label),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(text: ' ${names.length} · ${names.join('、')}'),
            ],
          ),
        ),
      );
}
