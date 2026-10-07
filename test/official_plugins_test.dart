import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/mosh_session.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/domain/plugins/official_plugins.dart';
import 'package:plugin_api/plugin_api.dart';

// X12（所有者 10-07 决定）：xwshun.mosh 只认 Mosh 插件现在的签名证书。用的是 App 里真正的
// pluginRegistryProvider（准入口径和发布出去的一样），安装包信息是手写的；模拟器上的装包见 evidence/X12.md。

const realPackage = 'top.xdwa.xwshun.mosh';
const fakePackage = 'example.xwshun.fixture.fakemosh';
const otherCert =
    'e257e747678f3ce38aa6fa1878c87a8f26dd7d9503ac8da3289d598fb472397f';

String moshDescriptor(String package) => jsonEncode({
      'schemaVersion': 1,
      'pluginId': 'xwshun.mosh',
      'displayName': 'Mosh',
      'version': '0.1.0',
      'apiMajor': 1,
      'apiMinor': 0,
      'deployment': 'android-service',
      'capabilities': ['terminal-session'],
      'supportedRoutes': ['system-default'],
      'platforms': ['android'],
      'permissions': [
        'own-session-input-output',
        'own-session-ephemeral-secret',
      ],
      'packageName': package,
      'serviceClass': '$package.MoshProviderService',
      'license': 'GPL-3.0-or-later',
    });

void main() {
  late ProviderContainer container;
  late PluginRegistry registry;

  setUp(() {
    container = ProviderContainer();
    registry = container.read(pluginRegistryProvider.notifier);
  });
  tearDown(() => container.dispose());

  void install(String package, String cert) => registry.offerInstalled(
        packageName: package,
        descriptorJson: moshDescriptor(package),
        signerDigests: {cert},
        serviceClass: '$package.MoshProviderService',
      );

  PluginEntry entryOf(String package) =>
      registry.entries.singleWhere((e) => e.packageName == package);

  test('登记的 ID 就是 Mosh 连接找插件用的那个', () {
    expect(OfficialPlugins.moshPluginId, PluginMoshRuntime.pluginId);
    expect(OfficialPlugins.reserved.keys, [PluginMoshRuntime.pluginId]);
  });

  test('别的证书签的包自称 xwshun.mosh：直接已拒绝，没有批准记录可用，说明只认官方证书', () {
    install(fakePackage, otherCert);
    final fake = entryOf(fakePackage);
    expect(fake.status, PluginStatus.rejected);
    expect(fake.reason, 'xwshun.mosh 只认登记过的官方证书，这个安装包的证书不是那张，不能批准');
    expect(fake.hasApproval, isFalse);
    expect(registry.readyEntry('xwshun.mosh'), isNull);

    // 就算批准记录里有它（比如偏好被改过），也进不了 Ready。
    registry.approve(ApprovedBinding(
      pluginId: 'xwshun.mosh',
      packageName: fakePackage,
      signingDigest: otherCert,
      capabilities: const {Capability.terminalSession},
    ));
    expect(entryOf(fakePackage).status, PluginStatus.rejected);
    expect(registry.readyEntry('xwshun.mosh'), isNull);
  });

  test('真 Mosh 插件（登记的证书）照常：待批准 → 批准后可用；冒充者同时装着也不影响它', () {
    install(fakePackage, otherCert);
    install(realPackage, OfficialPlugins.moshTestAuthorCertSha256);
    expect(entryOf(realPackage).status, PluginStatus.needsApproval);

    registry.approve(const ApprovedBinding(
      pluginId: 'xwshun.mosh',
      packageName: realPackage,
      signingDigest: OfficialPlugins.moshTestAuthorCertSha256,
      capabilities: {Capability.terminalSession},
    ));
    expect(entryOf(realPackage).status, PluginStatus.ready);
    expect(registry.readyEntry('xwshun.mosh')!.packageName, realPackage);
    expect(entryOf(fakePackage).status, PluginStatus.rejected);
  });

  test('只登记了 Mosh：别的 pluginId 不受影响，照常待批准', () {
    registry.offerInstalled(
      packageName: 'example.xwshun.hello',
      descriptorJson: jsonEncode({
        'schemaVersion': 1,
        'pluginId': 'example.hello_terminal',
        'displayName': 'Hello',
        'version': '0.1.0',
        'apiMajor': 1,
        'apiMinor': 0,
        'deployment': 'android-service',
        'capabilities': ['terminal-session'],
        'supportedRoutes': ['system-default'],
        'platforms': ['android'],
        'permissions': ['own-session-input-output'],
        'packageName': 'example.xwshun.hello',
        'serviceClass': 'example.xwshun.hello.HelloProviderService',
      }),
      signerDigests: {otherCert},
      serviceClass: 'example.xwshun.hello.HelloProviderService',
    );
    expect(entryOf('example.xwshun.hello').status, PluginStatus.needsApproval);
  });
}
