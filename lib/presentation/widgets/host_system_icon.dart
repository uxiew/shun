import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../domain/models/host.dart';
import '../../domain/models/server_stats.dart';

class HostSystemIcon extends StatelessWidget {
  const HostSystemIcon({
    super.key,
    required this.host,
    this.size = 44,
    this.systemInfo,
    this.catalogOs,
  });

  final HostProfile host;
  final double size;
  final ServerSystemInfo? systemInfo;

  /// 这台主机关联的 Tailscale 设备报的系统（本机目录缓存里的），见 [hostIconDistro]。
  final String? catalogOs;

  @override
  Widget build(BuildContext context) {
    if (host.protocol == HostProtocol.unknown) {
      return Icon(Icons.help_outline, size: size);
    }
    final distro = switch (systemInfo?.distro) {
      final live? => normalizeDistroId(live),
      null => hostIconDistro(host, catalogOs: catalogOs),
    };
    return SystemIcon(
      distro: distro,
      size: size,
      label: systemInfo?.prettyName ?? host.systemInfo?.prettyName,
    );
  }
}

/// 主机图标按哪个系统画（R26 所有者：设置里的设备页图标对，首页的不对）。
///
/// Tailscale 报的系统大类（Windows、macOS、Android、iOS、FreeBSD）说了就用它：
/// 用 26 包导入的主机没记 Tailscale 的系统，没连过只能当 Linux；连上后的探测跑的是 sh 脚本，
/// Termux 这类 Android 上的 sshd 会报成 Linux，把导入时记的 android 冲掉。
/// Tailscale 说是 Linux 或没说，才用主机自己的（连上后探测到的 Ubuntu、Debian…）。
String hostIconDistro(HostProfile host, {String? catalogOs}) =>
    switch (normalizeDistroId(catalogOs ?? '')) {
      final reported &&
            ('windows' || 'macos' || 'ios' || 'android' || 'freebsd') =>
        reported,
      _ => host.distro,
    };

/// 一个系统的图标（还没成为主机的 Tailscale 设备也用它）。[distro] 是 [normalizeDistroId] 的结果。
/// Android、iOS 没有 SVG，用 Material 自带的图标；不认识的显示服务器图标。
class SystemIcon extends StatelessWidget {
  const SystemIcon({
    super.key,
    required this.distro,
    this.size = 44,
    this.label,
  });

  final String distro;
  final double size;

  /// 读屏念的名字（比如 os-release 的 PRETTY_NAME），没有就念 [distro]。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = _brandColors[distro] ?? Theme.of(context).colorScheme.primary;
    final material = switch (distro) {
      'android' => Icons.android,
      'ios' => Icons.apple,
      _ => null,
    };
    return Semantics(
      label: '${label ?? distro} 系统',
      image: true,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(size * 0.27),
          border: Border.all(color: color.withValues(alpha: 0.32)),
        ),
        child: material != null
            ? FittedBox(child: Icon(material, color: color))
            : SvgPicture.asset(
                'assets/distro/$distro.svg',
                fit: BoxFit.contain,
                placeholderBuilder: (_) => Icon(
                  Icons.dns_outlined,
                  size: size * 0.55,
                  color: color,
                ),
              ),
      ),
    );
  }
}

const _brandColors = <String, Color>{
  'ubuntu': Color(0xffe95420),
  'debian': Color(0xffa80030),
  'centos': Color(0xff932279),
  'rocky': Color(0xff10b981),
  'fedora': Color(0xff51a2da),
  'redhat': Color(0xffee0000),
  'almalinux': Color(0xff0f4266),
  'arch': Color(0xff1793d1),
  'alpine': Color(0xff0d597f),
  'amazon': Color(0xffff9900),
  'opensuse': Color(0xff73ba25),
  'oracle': Color(0xfff80000),
  'kali': Color(0xff557c94),
  'alinux': Color(0xffff6a00),
  'openeuler': Color(0xff002fa7),
  'macos': Color(0xffa2aaad),
  'ios': Color(0xffa2aaad),
  'android': Color(0xff3ddc84),
  'freebsd': Color(0xffab2b28),
  'windows': Color(0xff0078d4),
  'linux': Color(0xfff2c94c),
  'cisco': Color(0xff1ba0d7),
  'juniper': Color(0xff84b135),
  'huawei': Color(0xffcf0a2c),
  'h3c': Color(0xffe60012),
  'hpe': Color(0xff01a982),
  'mikrotik': Color(0xff293239),
  'fortinet': Color(0xffee3124),
  'paloalto': Color(0xfff04e23),
  'zyxel': Color(0xfff39800),
};
