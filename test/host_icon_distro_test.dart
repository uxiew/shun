import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/catalog_overview.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';
import 'package:shun/presentation/widgets/catalog_text.dart';
import 'package:shun/presentation/widgets/host_system_icon.dart';
import 'package:shun/presentation/widgets/host_type_icon.dart';

// R26 F21：设置里的 Tailscale 设备页图标对、首页不对。首页已导入的主机以前只看主机自己存的系统：
// 26 包导入的没存→当 Linux；连上后探测把 android 冲成 linux。现在 Tailscale 报的系统大类优先。
void main() {
  HostProfile host([Map<String, Object?> extra = const {}]) => HostProfile({
        'id': 'h1',
        'label': 'pc',
        'hostname': '100.64.0.9',
        'username': 'me',
        'protocol': 'ssh',
        CatalogBinding.key:
            const CatalogBinding(catalogId: 'ts-home', deviceId: 'd1').toJson(),
        ...extra,
      });

  group('hostIconDistro', () {
    test('26 包导入、没连过（主机上什么系统都没存）：按 Tailscale 报的画', () {
      expect(host().distro, 'linux', reason: '主机自己只能当 Linux');
      expect(hostIconDistro(host(), catalogOs: 'windows'), 'windows');
      expect(hostIconDistro(host(), catalogOs: 'macOS'), 'macos');
      expect(hostIconDistro(host(), catalogOs: 'iOS'), 'ios');
      expect(hostIconDistro(host(), catalogOs: 'android'), 'android');
      expect(hostIconDistro(host(), catalogOs: 'freebsd'), 'freebsd');
    });

    test('探测把 Android 报成 Linux：仍按 Tailscale 的 android', () {
      final termux = host({'os': 'linux', 'distro': 'linux'});
      expect(hostIconDistro(termux, catalogOs: 'android'), 'android');
    });

    test('Tailscale 说是 Linux 或没说：用连上后探测到的具体发行版', () {
      final ubuntu = host({'os': 'linux', 'distro': 'ubuntu'});
      expect(hostIconDistro(ubuntu, catalogOs: 'linux'), 'ubuntu');
      expect(hostIconDistro(ubuntu), 'ubuntu');
      expect(hostIconDistro(ubuntu, catalogOs: ''), 'ubuntu');
    });
  });

  test('catalogOsOf：按主机的目录绑定从本机缓存里查；没绑定、来源不在、缓存里没有都是 null', () {
    final cache = CatalogCache(catalogId: 'ts-home', tailnet: '-').merge(
        TailscaleDeviceSnapshot.parse(jsonEncode({
          'devices': [
            {
              'id': 'd1',
              'name': 'pc.tail0000.ts.net',
              'hostname': 'pc',
              'addresses': ['100.64.0.9'],
              'os': 'windows',
            },
          ],
        })),
        DateTime(2026, 10, 30));
    final sources = [
      CatalogSourceView(cache: cache, hasSavedCredentials: false),
    ];
    expect(catalogOsOf(host(), sources), 'windows');
    expect(catalogOsOf(host(), const []), isNull);
    expect(
        catalogOsOf(
            HostProfile({
              'id': 'h2',
              'label': 'plain',
              'hostname': '192.0.2.1',
              'protocol': 'ssh',
            }),
            sources),
        isNull);
    final other = host({
      CatalogBinding.key:
          const CatalogBinding(catalogId: 'ts-home', deviceId: 'gone').toJson(),
    });
    expect(catalogOsOf(other, sources), isNull);
  });

  testWidgets('主机图标画的是 Tailscale 报的系统，不是 Linux 企鹅', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HostLeadingIcon(host: host(), size: 40, catalogOs: 'windows'),
      ),
    ));
    expect(
        tester.widget<SystemIcon>(find.byType(SystemIcon)).distro, 'windows');
  });
}
