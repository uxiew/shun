import 'package:flutter/material.dart';

import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import 'host_system_icon.dart';

/// 每种连接类型用哪个图标。「选择连接类型」页和主机列表的角标都用这里，改一处两边一起变。
/// 不认识的类型返回 null：系统图标那里已经画了问号。
IconData? hostProtocolIcon(HostProtocol protocol) => switch (protocol) {
      HostProtocol.ssh => Icons.lock_outline,
      HostProtocol.mosh => Icons.wifi_tethering,
      HostProtocol.telnet => Icons.cable,
      HostProtocol.plugin => Icons.extension_outlined,
      HostProtocol.unknown => null,
    };

/// 读屏念的名字。整句翻译：「连接」单独翻是动词 Connect。
String _protocolLabel(HostProtocol protocol) => switch (protocol) {
      HostProtocol.ssh => 'SSH 连接',
      HostProtocol.mosh => 'Mosh 连接',
      HostProtocol.telnet => 'Telnet 连接',
      HostProtocol.plugin => '插件连接',
      HostProtocol.unknown => '不支持的连接类型',
    };

/// 主机条目前面的图标（R43）：系统图标的右下角压一个连接类型角标，一眼看出这台走 Mosh、Telnet 还是插件。
/// 角标是这台主机保存的默认方式；终端里临时换了方式的标签不影响它。
/// SSH 不压：绝大多数主机都是 SSH，那把锁所有者看不懂是什么意思（R26），只在不是默认的时候提醒。
class HostLeadingIcon extends StatelessWidget {
  const HostLeadingIcon({super.key, required this.host, this.size = 42});

  final HostProfile host;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = host.protocol == HostProtocol.ssh
        ? null
        : hostProtocolIcon(host.protocol);
    final system = HostSystemIcon(host: host, size: size);
    if (icon == null) return system;
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (host.protocol) {
      HostProtocol.mosh => (
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer
        ),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    // 再小就看不清：38 的树形视图上是 16。
    final badge = (size * 0.42).clamp(16.0, 22.0);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          system,
          Positioned(
            right: -badge * 0.2,
            bottom: -badge * 0.2,
            child: Semantics(
              key: ValueKey('host-type-${host.protocol.name}'),
              label: localized(_protocolLabel(host.protocol)),
              child: Container(
                width: badge,
                height: badge,
                decoration: BoxDecoration(
                  color: background,
                  shape: BoxShape.circle,
                  // 和卡片底色隔开，压在彩色系统图标上也看得出边。
                  border: Border.all(color: scheme.surface, width: 1.5),
                ),
                child: Icon(icon, size: badge * 0.62, color: foreground),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
