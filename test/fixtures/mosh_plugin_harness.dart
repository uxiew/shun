import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/mosh_session.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/application/plugin_sessions.dart';
import 'package:netcatty_mobile/domain/plugins/builtin_plugins.dart';
import 'package:netcatty_mobile/domain/plugins/mosh_bootstrap.dart';
import 'package:netcatty_mobile/infrastructure/plugins/android_plugin_bridge.dart';
import 'package:plugin_api/plugin_api.dart';

/// Mosh 插件这一侧的测试替身（X09）：真的 AndroidPluginBridge + PluginRegistry + PluginSessionManager，
/// 只把平台通道换成假的。宿主交给插件的每个参数，都按平台通道实际编码、解码后的样子记在 [calls] 里，
/// 所以测得出「到底有什么离开了 Dart」（PLG14）。真插件、真 FD 在模拟器上测，见 integration_test/mosh_session_test.dart。
class MoshPluginHarness implements MoshRuntime {
  MoshPluginHarness() {
    _messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'closeSession' => true,
        _ => null,
      };
    });
    bridge = AndroidPluginBridge();
    registry = PluginRegistry(
      policy: AdmissionPolicy(builtinIds: BuiltinPlugins.ids),
    );
    registry
      ..offerInstalled(
        packageName: package,
        descriptorJson: jsonEncode({
          'schemaVersion': 1,
          'pluginId': PluginMoshRuntime.pluginId,
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
        }),
        signerDigests: {'cert-mosh'},
        serviceClass: '$package.MoshProviderService',
      )
      ..approve(
        const ApprovedBinding(
          pluginId: PluginMoshRuntime.pluginId,
          packageName: package,
          signingDigest: 'cert-mosh',
          capabilities: {Capability.terminalSession},
        ),
      );
    manager = PluginSessionManager(bridge, registry);
  }

  static const channel = MethodChannel('app.netcatty.mobile/plugins');
  static const package = PluginMoshRuntime.packageName;

  static TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];
  late final AndroidPluginBridge bridge;
  late final PluginRegistry registry;
  late final PluginSessionManager manager;

  /// 设了就让 [prepare] 失败（模拟没装、没批准插件）。
  MoshPluginUnavailable? unavailable;
  var prepareCount = 0;

  List<MethodCall> get opens =>
      calls.where((call) => call.method == 'openSession').toList();

  List<MethodCall> get writes =>
      calls.where((call) => call.method == 'writeSession').toList();

  @override
  Future<PluginEntry> prepare() async {
    prepareCount++;
    if (unavailable case final error?) throw error;
    return registry.readyEntry(PluginMoshRuntime.pluginId)!;
  }

  @override
  Future<PluginTerminalSession> open(
    PluginEntry entry, {
    required int cols,
    required int rows,
    required MoshSessionTarget target,
  }) =>
      manager.open(entry, cols: cols, rows: rows, mosh: target);

  /// 插件回报状态，像真插件那样经平台通道进来。
  Future<void> state(PluginTerminalSession session, int sequence, String state) =>
      _deliver('event', {
        'type': 'sessionEvent',
        'package': package,
        'handle': session.handle,
        'generation': session.generation,
        'sequence': sequence,
        'state': state,
      });

  /// 插件进程死了，宿主断开整个连接。
  Future<void> providerDied(PluginTerminalSession session) =>
      _deliver('event', {
        'type': 'sessionClosed',
        'package': package,
        'handle': session.handle,
        'generation': session.generation,
        'reason': '插件进程已退出',
        'cause': 'providerDied',
      });

  /// 插件送来一块终端输出。
  Future<void> output(PluginTerminalSession session, List<int> bytes) =>
      _deliver('sessionData', {
        'package': package,
        'handle': session.handle,
        'generation': session.generation,
        'bytes': Uint8List.fromList(bytes),
      });

  Future<void> _deliver(String method, Map<String, Object?> args) {
    final done = Completer<void>();
    _messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) => done.complete(),
    );
    return done.future;
  }

  /// 关掉还开着的会话。假通道留着：关会话的调用是异步发出的，先撤掉通道它们就报 MissingPluginException；
  /// 下一条测试的 harness 会换上自己的通道。
  void dispose() => manager.dispose();
}
