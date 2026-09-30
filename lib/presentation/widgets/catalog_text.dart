import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../localization/localized_widgets.dart';

/// 目录里的时间一律按本机时区显示到分钟。
String catalogTime(DateTime at) =>
    DateFormat('yyyy-MM-dd HH:mm').format(at.toLocal());

/// 「标签：值」一行。标签走翻译，值是设备名、地址、时间这类数据，原样显示。
Widget catalogLine(String label, String value, {TextStyle? style}) =>
    Text('${localized(label)}$value', style: style);

/// Tailscale 报告的控制面连接状态。故意不说「在线」：这只是设备连没连 Tailscale 的协调服务器，
/// 不代表手机能连到它，更不代表 SSH 开着（TSC03、TSC06）。
String controlPlaneText(bool? connected) => switch (connected) {
      true => 'Tailscale 控制面：已连接',
      false => 'Tailscale 控制面：未连接',
      null => 'Tailscale 控制面：不知道',
    };
