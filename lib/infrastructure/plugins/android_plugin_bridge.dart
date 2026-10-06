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
    this.settingsActivity,
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

  /// 包里唯一声明了设置 action 的导出 Activity（系统查出来的）；没有或不止一个为 null。
  final String? settingsActivity;

  static DiscoveredPackage fromMap(Map<Object?, Object?> m) =>
      DiscoveredPackage(
        packageName: m['package']! as String,
        serviceClass: m['serviceClass']! as String,
        descriptorJson: m['descriptor'] as String?,
        problem: m['problem'] as String?,
        versionName: m['versionName'] as String?,
        versionCode: (m['versionCode'] as num?)?.toInt(),
        settingsActivity: m['settingsActivity'] as String?,
        signers: [
          for (final s in (m['signers'] as List<Object?>? ?? const []))
            (
              sha256: (s! as Map)['sha256'] as String,
              androidDebug: s['androidDebug'] == true,
            ),
        ],
      );
}

/// 系统报告某个包装上、更新、卸载或组件启停（X04）。只说「哪个包变了」，怎么变由重新发现判定。
class PackageChange {
  const PackageChange(this.packageName, this.action, {this.replacing = false});
  final String packageName;

  /// added / replaced / removed / changed。
  final String action;

  /// 更新时系统先发 removed、再发 added，都带 replacing=true；这不是卸载。
  final bool replacing;
}

/// 桥上发来的事件：插件回报、被拒绝的调用、连接关闭。
class PluginBridgeEvent {
  const PluginBridgeEvent(this.type, this.packageName, this.detail);
  final String type;
  final String packageName;
  final String detail;
}

/// 会话字节（插件 → 宿主）。收到后必须 [AndroidPluginBridge.ackSession]，否则宿主不再读下一块。
class SessionDataEvent {
  const SessionDataEvent(
      this.packageName, this.handle, this.generation, this.bytes);
  final String packageName;
  final String handle;
  final int generation;
  final Uint8List bytes;
}

/// 会话控制事件（与字节流分开的通道）：
/// sessionEvent（插件回报状态）/ sessionEof（插件关了它那一端）/ sessionClosed（宿主断开了整个连接）/
/// droppedEvent（宿主丢弃的事件：旧代次、别人的句柄、连接已关…）。
class SessionBridgeEvent {
  const SessionBridgeEvent({
    required this.type,
    required this.packageName,
    this.handle,
    this.generation,
    this.sequence,
    this.state,
    this.reason,
    this.cause,
    this.providerAlive,
  });
  final String type;
  final String packageName;
  final String? handle;
  final int? generation;
  final int? sequence;
  final String? state;
  final String? reason;
  final String? cause;

  /// sessionEof 时插件进程是否还在（宿主 pingBinder 的结果）。
  final bool? providerAlive;
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
      final m = call.arguments as Map<Object?, Object?>;
      final package = m['package'] as String? ?? '';
      if (call.method == 'packageChanged') {
        _packageChanges.add(PackageChange(
          package,
          m['action'] as String? ?? 'changed',
          replacing: m['replacing'] == true,
        ));
        return;
      }
      if (call.method == 'sessionData') {
        _sessionData.add(
          SessionDataEvent(
            package,
            m['handle']! as String,
            (m['generation']! as num).toInt(),
            m['bytes']! as Uint8List,
          ),
        );
        return;
      }
      if (call.method != 'event') return;
      final type = m['type'] as String? ?? '';
      if (const {'sessionEvent', 'sessionEof', 'sessionClosed', 'droppedEvent'}
          .contains(type)) {
        _sessionEvents.add(
          SessionBridgeEvent(
            type: type,
            packageName: package,
            handle: m['handle'] as String?,
            generation: (m['generation'] as num?)?.toInt(),
            sequence: (m['sequence'] as num?)?.toInt(),
            state: m['state'] as String?,
            reason: m['reason'] as String?,
            cause: m['cause'] as String?,
            providerAlive: m['providerAlive'] as bool?,
          ),
        );
        if (type != 'droppedEvent') return;
      }
      final event = m['event'];
      final sequence = m['sequence'];
      final method = m['method'];
      final reason = m['reason'] ?? '';
      final handle = m['handle'];
      _events.add(
        PluginBridgeEvent(
          type,
          package,
          switch (type) {
            'providerEvent' => '$event（序号 $sequence）',
            'rejectedCall' => '$method：$reason',
            'droppedEvent' => '$handle：$reason',
            _ => '$reason',
          },
        ),
      );
    });
  }

  final MethodChannel _channel;
  final _events = StreamController<PluginBridgeEvent>.broadcast();
  final _packageChanges = StreamController<PackageChange>.broadcast();
  final _sessionData = StreamController<SessionDataEvent>.broadcast(sync: true);
  final _sessionEvents =
      StreamController<SessionBridgeEvent>.broadcast(sync: true);

  bool get supported => Platform.isAndroid;
  Stream<PluginBridgeEvent> get events => _events.stream;
  Stream<PackageChange> get packageChanges => _packageChanges.stream;
  Stream<SessionDataEvent> get sessionData => _sessionData.stream;
  Stream<SessionBridgeEvent> get sessionEvents => _sessionEvents.stream;

  Future<List<DiscoveredPackage>> discover() async {
    if (!supported) return const [];
    final raw =
        await _channel.invokeListMethod<Object?>('discover') ?? const [];
    return [
      for (final item in raw)
        DiscoveredPackage.fromMap(item! as Map<Object?, Object?>),
    ];
  }

  /// 打开插件自己的设置页。桥会再向系统核一次这个类确实是该包的设置页才启动。
  Future<void> openSettings(String packageName, String activity) async {
    try {
      await _channel.invokeMethod<void>(
        'openSettings',
        {'package': packageName, 'activity': activity},
      );
    } on PlatformException catch (e) {
      throw PluginBridgeException(e.code, e.message ?? e.code);
    }
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

  Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw PluginBridgeException(e.code, e.message ?? e.code);
    }
  }

  /// [moshHost]/[moshPort]/[moshKey] 三个一起给时走插件的 openMoshSession（X08）：
  /// 目标必须是数字 IP（插件不做 DNS），key 是 22 个 base64 字符的字节。key 经平台通道传过去后，
  /// Kotlin 那边用完就清零；这一侧由调用方清（[MoshBootstrapResult.wipe]）。
  Future<void> openSession({
    required String packageName,
    required String handle,
    required int generation,
    required int cols,
    required int rows,
    String? moshHost,
    int? moshPort,
    Uint8List? moshKey,
  }) {
    final mosh = moshHost != null || moshPort != null || moshKey != null;
    if (mosh &&
        (moshHost == null ||
            InternetAddress.tryParse(moshHost) == null ||
            moshPort == null ||
            moshPort < 1 ||
            moshPort > 65535 ||
            moshKey == null ||
            moshKey.length != 22)) {
      throw const PluginBridgeException('BAD_ARGS', 'Mosh 目标或材料无效');
    }
    return _invoke<void>('openSession', {
      'package': packageName,
      'handle': handle,
      'generation': generation,
      'cols': cols,
      'rows': rows,
      if (mosh) ...{'udpHost': moshHost, 'udpPort': moshPort, 'key': moshKey},
    });
  }

  Future<void> resizeSession(
    String packageName,
    String handle,
    int generation,
    int cols,
    int rows,
  ) =>
      _invoke<void>('resizeSession', {
        'package': packageName,
        'handle': handle,
        'generation': generation,
        'cols': cols,
        'rows': rows,
      });

  /// 返回 false 表示宿主这边已经没有这个会话（重复关闭）。
  Future<bool> closeSession(
          String packageName, String handle, int generation) async =>
      await _invoke<bool>('closeSession', {
        'package': packageName,
        'handle': handle,
        'generation': generation,
      }) ??
      false;

  Future<void> writeSession(
    String packageName,
    String handle,
    int generation,
    Uint8List bytes,
  ) =>
      _invoke<void>('writeSession', {
        'package': packageName,
        'handle': handle,
        'generation': generation,
        'bytes': bytes,
      });

  Future<void> ackSession(String packageName, String handle, int generation) =>
      _invoke<void>('ackSession', {
        'package': packageName,
        'handle': handle,
        'generation': generation,
      });

  /// 宿主这一端的缓冲情况（在途输出块、积压输入字节），用来核对背压确实有界。
  Future<Map<String, Object?>?> sessionStats(
    String packageName,
    String handle,
    int generation,
  ) async =>
      (await _invoke<Map<Object?, Object?>>('sessionStats', {
        'package': packageName,
        'handle': handle,
        'generation': generation,
      }))
          ?.cast<String, Object?>();

  Future<void> disconnect(String packageName) =>
      _channel.invokeMethod<void>('disconnect', {'package': packageName});
}
