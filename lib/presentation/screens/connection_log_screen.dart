import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/connection_events.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import '../widgets/connection_event_text.dart';

/// 连接记录页（R25）。给了 [hostId] 只看这一台（主机 ⋮ 菜单、连接失败页进来），
/// 不给是全部主机（设置里进来）。
///
/// 页面只读本机记录，不连任何东西：打开它不会去探主机、也不会触发重连。
/// 名字按保险库现在的查（记录里只有 ID），导出不查名字。
class ConnectionLogScreen extends ConsumerStatefulWidget {
  const ConnectionLogScreen({super.key, this.hostId});

  final String? hostId;

  @override
  ConsumerState<ConnectionLogScreen> createState() =>
      _ConnectionLogScreenState();
}

class _ConnectionLogScreenState extends ConsumerState<ConnectionLogScreen> {
  @override
  void initState() {
    super.initState();
    // 过了 7 天的在这时删：不在后台定时扫。
    unawaited(ref.read(connectionEventLogProvider.notifier).prune());
  }

  /// 旧的在前。
  List<ConnectionEvent> _events() {
    final all = ref.read(connectionEventLogProvider);
    final hostId = widget.hostId;
    return hostId == null
        ? all
        : all.where((event) => event.hostId == hostId).toList();
  }

  Future<void> _export() async {
    final events = _events();
    final text = exportConnectionEvents(events, now: DateTime.now());
    final copy = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('导出前预览'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LText(
                '下面就是要复制的全部内容：主机换成了编号，路线上只写「跳板 1」「目标」。只复制到剪贴板，不会上传。',
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    key: const ValueKey('connection-log-export-preview'),
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('取消'),
          ),
          FilledButton.icon(
            key: const ValueKey('connection-log-copy'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.copy),
            label: const LText('复制到剪贴板'),
          ),
        ],
      ),
    );
    if (copy != true || !mounted) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          localized('已复制 {n} 条记录').replaceAll('{n}', '${events.length}'),
        ),
      ),
    );
  }

  Future<void> _clear() async {
    final count = _events().length;
    final all = widget.hostId == null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: LText(all ? '清除全部连接记录？' : '清除这台主机的连接记录？'),
        content: Text(
          localized('会删掉 {n} 条，删了找不回来。主机、连着的标签和保险库都不动。')
              .replaceAll('{n}', '$count'),
        ),
        actions: [
          // 取消在前、是默认；删除不是默认动作（UX03）。
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const LText('取消'),
          ),
          TextButton(
            key: const ValueKey('connection-log-clear-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const LText('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final log = ref.read(connectionEventLogProvider.notifier);
    if (all) {
      await log.clearAll();
    } else {
      await log.clearHost(widget.hostId!);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: LText('已清除')),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(connectionEventLogProvider);
    final hosts = {
      for (final host in ref.watch(vaultControllerProvider).data?.hosts ??
          const <HostProfile>[])
        host.id: host,
    };
    final events = _events();
    final newestFirst = events.reversed.toList();
    final hostId = widget.hostId;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LText('连接记录'),
            if (hostId != null)
              Text(
                hosts[hostId]?.label ?? localized('已删除的主机'),
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          IconButton(
            key: const ValueKey('connection-log-export'),
            tooltip: localized('导出（先预览）'),
            onPressed: events.isEmpty ? null : _export,
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            key: const ValueKey('connection-log-clear'),
            tooltip: localized('清除记录'),
            onPressed: events.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: ListView(
        key: const ValueKey('connection-log-list'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          LText(connectionLogScope, style: small),
          const SizedBox(height: 6),
          LText(connectionTimingNote, style: small),
          const SizedBox(height: 12),
          if (events.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: LText(
                hostId == null
                    ? '还没有记录。连一次主机，或者断线、恢复以后，这里就会有。'
                    : '这台主机最近 7 天没有记录。连一次，或者断线、恢复以后，这里就会有。',
                key: const ValueKey('connection-log-empty'),
                textAlign: TextAlign.center,
              ),
            )
          else ...[
            LText(
              connectionLogSummary(events),
              key: const ValueKey('connection-log-summary'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            for (final event in newestFirst)
              _EventCard(
                event: event,
                hostLabel: hostId == null
                    ? hosts[event.hostId]?.label ?? localized('已删除的主机')
                    : null,
                hopName: (hop) => connectionHopName(
                  hop,
                  event.hopCount,
                  hop < event.hopIds.length
                      ? hosts[event.hopIds[hop]]?.label
                      : null,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.hostLabel,
    required this.hopName,
  });

  final ConnectionEvent event;

  /// 看全部主机时才有：这条是哪台的。
  final String? hostLabel;
  final String Function(int hop) hopName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final (icon, color) = switch (event.kind) {
      ConnectionEventKind.drop => (Icons.link_off, scheme.tertiary),
      ConnectionEventKind.recoveryStopped => (
          Icons.pause_circle_outline,
          scheme.tertiary
        ),
      _ => switch (event.outcome) {
          ConnectionOutcome.connected => (
              Icons.check_circle_outline,
              scheme.primary
            ),
          ConnectionOutcome.failed => (Icons.error_outline, scheme.error),
          _ => (Icons.cancel_outlined, scheme.onSurfaceVariant),
        },
    };
    final facts = [
      formatConnectionEventTime(event.at),
      if (hostLabel != null) hostLabel!,
      ...connectionEventFacts(event),
    ];
    final stages = connectionStageLines(event, hopName);
    final next = connectionEventNextStep(event);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        key: PageStorageKey(event),
        leading: Icon(icon, color: color),
        title: Text(
          '${connectionEventTitle(event)} · ${connectionEventOutcome(event)}',
        ),
        subtitle: Text(facts.join(' · '), style: small),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (event.isAttempt)
            Text(connectionRouteLine(event, hopName), style: small),
          if (event.failureHop case final hop? when hop < event.hopCount)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                connectionFailedAt(hopName(hop)),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          if (stages.isNotEmpty) const SizedBox(height: 8),
          for (final line in stages)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(line.text, style: theme.textTheme.bodySmall),
                  ),
                  const SizedBox(width: 8),
                  Text(line.elapsed, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          if (event.isAttempt && event.stages.isEmpty)
            Text(
              localized('一个阶段都没开始就停了：还没拨号。'),
              style: theme.textTheme.bodySmall,
            ),
          if (next != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                connectionNextStepLine(next),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSecondaryContainer),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
