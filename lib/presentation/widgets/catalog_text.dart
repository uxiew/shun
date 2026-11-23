import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../application/catalog_overview.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';

/// 来源在界面上叫什么。没起名字时不拿本机 ID（`ts-ozz7e7tmue`）当标题，那串字对人没有意义：
/// 填过具体 tailnet 的用 tailnet，都没有就叫「未命名来源」。
/// 几个未命名来源要分开看时，来源列表里另写一行 ID（[catalogSourceUnnamed]）。
String catalogSourceName(CatalogCache cache) {
  final label = cache.label?.trim() ?? '';
  if (label.isNotEmpty) return label;
  if (cache.tailnet != '-') return cache.tailnet;
  return localized('未命名来源');
}

/// 名字和 tailnet 都没有：界面上只能叫「未命名来源」，要靠 ID 区分。
bool catalogSourceUnnamed(CatalogCache cache) =>
    (cache.label?.trim() ?? '').isEmpty && cache.tailnet == '-';

/// 目录里的时间一律按本机时区显示到分钟。
String catalogTime(DateTime at) =>
    DateFormat('yyyy-MM-dd HH:mm').format(at.toLocal());

/// 缓存有多旧：「3 小时前」。控制面状态变得快，光写绝对时间看不出它已经旧了。
/// 手机时钟被往回调过（缓存时间在现在之后）返回 null，只显示绝对时间，不编一个负数。
String? catalogAge(DateTime at, DateTime now) {
  final age = now.difference(at);
  if (age.isNegative) return null;
  if (age.inMinutes < 1) return localized('刚刚');
  final (count, unit) = age.inHours < 1
      ? (age.inMinutes, localized('分钟前'))
      : age.inDays < 1
          ? (age.inHours, localized('小时前'))
          : (age.inDays, localized('天前'));
  return '$count $unit';
}

/// 读完一次设备列表给用户看的那几句：成了几台、改了几台主机的地址，失败了是什么原因。
/// 来源页和主机列表的「刷新」都用它。
String catalogRefreshReport(CatalogRefreshOutcome outcome) {
  final error = outcome.error;
  if (error != null) {
    final head = localized('读取失败，缓存里的设备和主机都没动：');
    return '$head${error.message}';
  }
  final read = localized('读取成功，设备数：');
  final moved = localized('跟着目录改了地址的主机：');
  return [
    '$read${outcome.cache.lastSuccess?.deviceCount ?? 0}',
    if (outcome.hostsReaddressed > 0) '$moved${outcome.hostsReaddressed}',
  ].join('\n');
}

/// 「标签：值」一行。标签走翻译，值是设备名、地址、时间这类数据，原样显示。
Widget catalogLine(String label, String value, {TextStyle? style, Key? key}) =>
    Text('${localized(label)}$value', style: style, key: key);

/// 设置面板和导入页共用的表单底色；只去掉静止时的边框，焦点和错误仍清楚可见。
class CatalogFormList extends StatelessWidget {
  const CatalogFormList({
    super.key,
    required this.children,
    required this.padding,
    this.shrinkWrap = false,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    final level = prism.SurfaceScope.of(context);
    final raised = level.next.colorOf(colors);
    return InputDecorationTheme(
      data: InputDecorationTheme.of(context).copyWith(
        filled: true,
        fillColor: raised == level.colorOf(colors)
            ? prism.SurfaceLevel.inset.colorOf(colors)
            : raised,
        enabledBorder: const OutlineInputBorder(
          borderRadius: prism.AppRadius.md,
          borderSide: BorderSide.none,
        ),
      ),
      child: ListView(
        padding: padding,
        shrinkWrap: shrinkWrap,
        children: children,
      ),
    );
  }
}

/// 设备在 Tailscale 里在不在线（R26：所有者要像 Tailscale App 那样看在线状态）。
///
/// 和 Tailscale App、后台显示的是同一回事：设备连没连着 Tailscale 的协调服务器。它不说明手机连得到、
/// SSH 开着——那要真连一次才知道。官方的说法是「最近」连着，所以设备刚掉线时可能还显示在线一小会儿。
/// 状态截至缓存时间，组头写着。
enum DeviceOnline { online, offline, unknown, gone }

/// 读到的状态过了这么久，文字就写上是多久前的（R67）：自动刷新每分钟一次，10 分钟都没读到新的，
/// 多半是没网、key 失效或没存 key。
///
/// 点照画（所有者 11-01）：R67 曾经过期就不画点，结果没存 key、读取一直失败的来源永远看不到状态。
const catalogStatusFreshFor = Duration(minutes: 10);

DeviceOnline deviceOnline(CatalogDeviceRecord? record) {
  if (record == null || record.missing) return DeviceOnline.gone;
  return switch (record.device.connectedToControl) {
    true => DeviceOnline.online,
    false => DeviceOnline.offline,
    null => DeviceOnline.unknown,
  };
}

/// 「在线」「离线 · 3 小时前在线」「列表里没有它了」。[statusAt] 是读到这份状态的时间，
/// 过期了（[catalogStatusFreshFor]）前面写上多久前：「3 小时前：在线」。
String deviceOnlineText(
  CatalogDeviceRecord? record,
  DateTime now, {
  DateTime? statusAt,
}) {
  if (record == null) return localized('缓存里没有这台设备');
  if (record.missing) return localized('最近的设备列表里没有它了');
  final text = _deviceOnlineNow(record, now);
  if (statusAt == null || now.difference(statusAt) < catalogStatusFreshFor) {
    return text;
  }
  return '${catalogAge(statusAt, now) ?? catalogTime(statusAt)}${localized('：')}$text';
}

String _deviceOnlineNow(CatalogDeviceRecord record, DateTime now) {
  final lastSeen = record.device.lastSeen;
  return switch (record.device.connectedToControl) {
    true => localized('在线'),
    false when lastSeen != null =>
      '${localized('离线 · 上次在线：')}${catalogAge(lastSeen, now) ?? catalogTime(lastSeen)}',
    false => localized('离线'),
    null => localized('在线状态不明'),
  };
}

/// 这台主机关联的 Tailscale 设备报的系统，从本机目录缓存里查。没关联、来源不在本机、缓存里没有这台都是 null。
String? catalogOsOf(HostProfile host, List<CatalogSourceView> sources) {
  final binding = CatalogBinding.of(host);
  if (binding == null) return null;
  final source =
      sources.where((s) => s.cache.catalogId == binding.catalogId).firstOrNull;
  return source?.cache.devices[binding.deviceId]?.device.os;
}

/// 在线绿点、离线灰点；不明和不见了的不画点，免得被当成离线。
Color? deviceOnlineColor(DeviceOnline presence) => switch (presence) {
      DeviceOnline.online => const Color(0xff22c55e),
      DeviceOnline.offline => const Color(0xff9ca3af),
      _ => null,
    };

/// 在线点放在条目第二行（地址）的行首。以前压在图标右上角，所有者嫌和图标上的角标挤在一起（R26）。
/// 不明和不见了的不画点，这一行照常从行首开始。
class PresenceLine extends StatelessWidget {
  const PresenceLine({
    super.key,
    required this.presence,
    required this.child,
  });

  final DeviceOnline presence;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = deviceOnlineColor(presence);
    if (color == null) return child;
    return Row(
      children: [
        Container(
          key: ValueKey('presence-${presence.name}'),
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Flexible(child: child),
      ],
    );
  }
}

/// 「✓ 登录过」：这台主机在本机成功登录过（R26）。只看本机记录，不同步、不代表现在还登得上。
class LoggedInMark extends StatelessWidget {
  const LoggedInMark({super.key, this.style});

  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final color =
        prism.ColorSchemeExtension(prism.Theme.of(context).colorScheme).success;
    return Row(
      key: const ValueKey('logged-in-mark'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle,
            size: (style?.fontSize ?? 12) + 2, color: color),
        const SizedBox(width: 3),
        LText('登录过', style: style?.copyWith(color: color)),
      ],
    );
  }
}

/// 64 位十六进制按 4 位一组，方便和别处的证书对着看。
String formatDigest(String hex) => [
      for (var i = 0; i < hex.length; i += 4)
        hex.substring(i, i + 4 > hex.length ? hex.length : i + 4),
    ].join(' ');
