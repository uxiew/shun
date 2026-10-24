import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../application/tailscale_catalog_access.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../../infrastructure/tailscale/tailscale_api.dart';
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

/// 读完一次设备列表给用户看的那几句：成了几台、改了几台主机的地址、权限范围确认不了，
/// 失败了是什么原因。来源页和主机列表的「刷新」都用它。
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
    if (outcome.scope == TokenScopeStatus.unverified)
      localized('服务器没有回报 token 的权限范围，无法确认它只能读设备。'),
    if (outcome.persistRefusal case final refusal?)
      localized(switch (refusal) {
        PersistRefusal.notRequested => '没有保存 OAuth client。',
        PersistRefusal.scopeUnverified =>
          '没有保存 OAuth client：服务器没有回报权限范围，无法确认它只能读设备。',
        PersistRefusal.scopeBroaderThanDevices =>
          '没有保存 OAuth client：它能读的不止设备。请在 Tailscale 后台新建一个只有 devices:core:read 的 client。',
      }),
  ].join('\n');
}

/// 「标签：值」一行。标签走翻译，值是设备名、地址、时间这类数据，原样显示。
Widget catalogLine(String label, String value, {TextStyle? style, Key? key}) =>
    Text('${localized(label)}$value', style: style, key: key);

/// Tailscale 报告的控制面连接状态。故意不说「在线」：这只是设备连没连 Tailscale 的协调服务器，
/// 不代表手机能连到它，更不代表 SSH 开着（TSC03、TSC06）。
String controlPlaneText(bool? connected) => switch (connected) {
      true => 'Tailscale 控制面：已连接',
      false => 'Tailscale 控制面：未连接',
      null => 'Tailscale 控制面：不知道',
    };

/// 64 位十六进制按 4 位一组，方便和别处的证书对着看。
String formatDigest(String hex) => [
      for (var i = 0; i < hex.length; i += 4)
        hex.substring(i, i + 4 > hex.length ? hex.length : i + 4),
    ].join(' ');
