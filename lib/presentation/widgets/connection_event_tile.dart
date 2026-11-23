import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../application/connection_events.dart';
import '../localization/localized_widgets.dart';
import 'connection_event_text.dart';

/// 日志页里的一条连接（R25）：收起来是结果，展开是路线、每步用时和下一步。
class ConnectionEventTile extends StatelessWidget {
  const ConnectionEventTile({
    super.key,
    required this.event,
    required this.hostLabel,
    required this.hopName,
  });

  final ConnectionEvent event;

  /// 看整份日志时才有：这条是哪台的。
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
    return ExpansionTile(
      key: PageStorageKey(event),
      leading: Icon(icon, color: color),
      title: Text(
        '${connectionEventTitle(event)} · ${connectionEventOutcome(event)}',
      ),
      subtitle: Text(facts.join(' · '), style: small),
      shape: const Border(),
      collapsedShape: const Border(),
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
            // 「下一步」是建议不是状态：中性的底，比所在的卡片高一层。
            decoration: ShapeDecoration(
              color: prism.SurfaceContext(context)
                  .raisedSurfaceLevel
                  .colorOf(prism.Theme.of(context).colorScheme),
              shape: prism.AppShape.sm,
            ),
            child: Text(
              connectionNextStepLine(next),
              style:
                  theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface),
            ),
          ),
        ],
      ],
    );
  }
}
