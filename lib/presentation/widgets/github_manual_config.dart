import 'package:flutter/material.dart';
import '../localization/localized_widgets.dart';
import 'form_gap.dart';

class GitHubManualConfig extends StatelessWidget {
  const GitHubManualConfig(
      {super.key,
      required this.resourceId,
      required this.secret,
      required this.onSecretChanged});
  final TextEditingController resourceId;
  final TextEditingController secret;
  final ValueChanged<String> onSecretChanged;

  @override
  Widget build(BuildContext context) => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 18, bottom: 12),
        title: const LText('高级 / 手动配置'),
        subtitle: const LText('仅用于迁移或登录故障排查'),
        children: [
          TextField(
              key: const ValueKey('github-manual-resource-id'),
              controller: resourceId,
              decoration: LInputDecoration(labelText: 'Gist ID（通常自动识别）')),
          const FormGap(),
          TextField(
              key: const ValueKey('github-manual-secret'),
              controller: secret,
              obscureText: true,
              // 防截屏由外面的云端备份页管（R44），这里只关输入法学习。
              enableIMEPersonalizedLearning: false,
              enableSuggestions: false,
              autocorrect: false,
              onChanged: onSecretChanged,
              decoration: LInputDecoration(labelText: 'GitHub Token（备用）')),
        ],
      );
}
