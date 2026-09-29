import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 系统报告的一个插件安装包（X02）。这里的每个字段都来自 PackageManager，
/// 只有 [descriptorJson] 是插件自己写的「自称」，要经 PluginRegistry 严格校验。
class DiscoveredPackage {
  const DiscoveredPackage({
    required this.packageName,
    required this.serviceClass,
    required this.signers,
    this.descriptorJson,
    this.problem,
    this.versionName,
    this.versionCode,
  });

  final String packageName;

  /// 实际声明插件 action 的服务类。绑定只用它，不用描述符里自称的 serviceClass。
  final String serviceClass;

  /// 当前签名证书（系统读出），不含签名轮换历史里的旧证书。
  final List<({String sha256, bool androidDebug})> signers;
  final String? descriptorJson;

  /// 平台层就能确定的问题（没导出、声明了多个服务、描述符超 16 KiB…）。有它就判为不兼容。
  final String? problem;
  final String? versionName;
  final int? versionCode;

  static DiscoveredPackage fromMap(Map<Object?, Object?> m) =>
      DiscoveredPackage(
        packageName: m['package']! as String,
        serviceClass: m['serviceClass']! as String,
        descriptorJson: m['descriptor'] as String?,
        problem: m['problem'] as String?,
        versionName: m['versionName'] as String?,
        versionCode: (m['versionCode'] as num?)?.toInt(),
        signers: [
          for (final s in (m['signers'] as List<Object?>? ?? const []))
            (
              sha256: (s! as Map)['sha256'] as String,
              androidDebug: s['androidDebug'] == true,
            ),
        ],
      );
}

/// 桥上发来的事件：插件回报、被拒绝的调用、连接关闭。
class PluginBridgeEvent {
  const PluginBridgeEvent(this.type, this.packageName, this.detail);
  final String type;
  final String packageName;
  final String detail;
}

class PluginBridgeException implements Exception {
  const PluginBridgeException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// 与 Kotlin 端 PluginBridge 的通道。非 Android 平台上什么都发现不了（独立插件 APK 只有 Android 有）。
class AndroidPluginBridge {
  AndroidPluginBridge({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('app.netcatty.mobile/plugins') {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'event') return;
      final m = call.arguments as Map<Object?, Object?>;
      final type = m['type'] as String? ?? '';
      final event = m['event'];
      final sequence = m['sequence'];
      final method = m['method'];
      final reason = m['reason'] ?? '';
      _events.add(
        PluginBridgeEvent(
          type,
          m['package'] as String? ?? '',
          switch (type) {
            'providerEvent' => '$event（序号 $sequence）',
            'rejectedCall' => '$method：$reason',
            _ => '$reason',
          },
        ),
      );
    });
  }

  final MethodChannel _channel;
  final _events = StreamController<PluginBridgeEvent>.broadcast();

  bool get supported => Platform.isAndroid;
  Stream<PluginBridgeEvent> get events => _events.stream;

  Future<List<DiscoveredPackage>> discover() async {
    if (!supported) return const [];
    final raw =
        await _channel.invokeListMethod<Object?>('discover') ?? const [];
    return [
      for (final item in raw)
        DiscoveredPackage.fromMap(item! as Map<Object?, Object?>),
    ];
  }

  /// 某个包为什么没出现在插件列表里。
  Future<String> inspect(String packageName) async {
    if (!supported) return '独立插件只支持 Android';
    final m = await _channel.invokeMapMethod<String, Object?>(
      'inspect',
      {'package': packageName},
    );
    return m?['reason'] as String? ?? '';
  }

  /// 绑定并握手。返回插件握手时给的描述符 JSON。
  Future<String> connect({
    required String packageName,
    required String serviceClass,
    required String pluginId,
    required String sha256,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('connect', {
        'package': packageName,
        'serviceClass': serviceClass,
        'pluginId': pluginId,
        'sha256': sha256,
      });
      return m?['descriptor'] as String? ?? '';
    } on PlatformException catch (e) {
      throw PluginBridgeException(e.code, e.message ?? e.code);
    }
  }

  Future<int> ping(String packageName, int nonce) async {
    try {
      final value = await _channel.invokeMethod<Object?>(
        'ping',
        {'package': packageName, 'nonce': nonce},
      );
      return (value as num).toInt();
    } on PlatformException catch (e) {
      throw PluginBridgeException(e.code, e.message ?? e.code);
    }
  }

  Future<void> disconnect(String packageName) =>
      _channel.invokeMethod<void>('disconnect', {'package': packageName});
}
