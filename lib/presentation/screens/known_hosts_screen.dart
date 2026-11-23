import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/host_trust.dart';
import '../../application/vault_controller.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import '../widgets/connection_event_text.dart';
import '../widgets/empty_state.dart';
import '../widgets/hint.dart';

/// 可信主机密钥（R65）：看、删，别的都不给。
///
/// 故意不能改指纹、不能加记录：指纹只从连接时的核对框来（docs/dev/security.md 第 3 节），
/// 这里能写的话，等于多一条绕过核对的路。
class KnownHostsScreen extends ConsumerWidget {
  const KnownHostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final extras = ref.watch(vaultControllerProvider).data?.extras;
    final entries = sortedKnownHosts(
      extras == null ? const [] : knownHostsFromExtras(extras),
    );
    return Scaffold(
      appBar: ShunAppBar(
        title: const HintTitle(
          '可信主机密钥',
          hint: '这里是你核对后接受过的服务器。删一条后，下次连这台要重新核对。只记在这台手机上，同步和导入都不带。',
        ),
      ),
      body: entries.isEmpty
          ? const EmptyState(
              icon: Icons.verified_user_outlined, title: '还没有接受过服务器')
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                ShunSection(
                  children: [
                    for (final entry in entries) _KnownHostTile(entry: entry),
                  ],
                ),
              ],
            ),
    );
  }
}

class _KnownHostTile extends ConsumerWidget {
  const _KnownHostTile({required this.entry});

  final Map<String, dynamic> entry;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final name = knownHostLabel(entry);
    final vault = ref.read(vaultControllerProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: LText('删除 $name 的指纹？'),
        content: const LText('下次连这台要重新核对。'),
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
    if (confirmed != true) return;
    await vault.forgetHostKey(
      hostname: '${entry['hostname'] ?? ''}',
      port: (entry['port'] as num?)?.toInt() ?? 22,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acceptedAt = (entry['acceptedAt'] as num?)?.toInt();
    final keyType = '${entry['keyType'] ?? ''}';
    final name = knownHostLabel(entry);
    return ShunListRow(
      key: ValueKey('known-host-$name'),
      title: name,
      details: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (keyType.isNotEmpty) ShunPill(keyType),
          // 能选中复制：核对时要拿去和服务器上的输出比。
          SelectableText('${entry['fingerprint'] ?? ''}'),
          if (acceptedAt != null)
            Text(formatConnectionEventTime(
                DateTime.fromMillisecondsSinceEpoch(acceptedAt))),
        ],
      ),
      trailing: ShunBarButton(
        tooltip: localized('删除'),
        icon: Icons.delete_outline,
        onPressed: () => _delete(context, ref),
      ),
    );
  }
}
