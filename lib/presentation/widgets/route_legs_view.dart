import 'package:flutter/material.dart';

import '../../domain/connection_route.dart';
import '../../domain/route_description.dart';
import '../localization/localized_widgets.dart';

/// 把一条路线按「手机 → 代理 → 跳板… → 目标」逐段竖着列出来。
/// 编辑器的链路摘要、测试连接、连接失败页共用，三处看到的是同一份描述。
class RouteLegsView extends StatelessWidget {
  const RouteLegsView({super.key, required this.plan, this.dense = false});

  final RoutePlan plan;
  final bool dense;

  static IconData iconFor(RouteLegKind kind) => switch (kind) {
        RouteLegKind.phone => Icons.smartphone,
        RouteLegKind.proxy => Icons.public,
        RouteLegKind.jump => Icons.alt_route,
        RouteLegKind.target => Icons.dns_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final legs = describeRoute(plan);
    return Column(
      key: const ValueKey('route-legs'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < legs.length; index++)
          Padding(
            padding: EdgeInsets.symmetric(vertical: dense ? 2 : 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  iconFor(legs[index].kind),
                  size: dense ? 16 : 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LText(
                        '${index + 1}. ${legs[index].title}',
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (legs[index].detail.isNotEmpty)
                        LText(
                          legs[index].detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
