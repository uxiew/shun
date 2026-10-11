import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 保活服务（Android 前台服务）这一代要显示什么。
class KeepAliveRequest {
  const KeepAliveRequest({
    required this.generation,
    required this.title,
    required this.text,
  });

  /// 第几代保活。平台报回来的事件带着它，会话控制器只认当前这一代（LIFE05）。
  final int generation;
  final String title;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is KeepAliveRequest &&
      other.generation == generation &&
      other.title == title &&
      other.text == text;

  @override
  int get hashCode => Object.hash(generation, title, text);
}

/// 开保活服务的结果。
class KeepAliveResult {
  const KeepAliveResult({
    required this.started,
    this.notificationsEnabled = true,
    this.error,
  });

  /// 没有平台实现（桌面、测试）时的结果：什么都没开，也不算出错。
  static const unsupported = KeepAliveResult(started: false);

  final bool started;

  /// 用户没给通知权限时为 false：服务照样开着，只是通知栏看不到，也就没法从通知上「全部断开」。
  final bool notificationsEnabled;

  /// 没开起来的原因（比如 Android 12+ 不让后台启动前台服务）。
  final String? error;
}

/// 当前默认网络。
class NetworkStatus {
  const NetworkStatus({
    required this.available,
    this.id,
    this.transports = const {},
    this.validated = false,
  });

  static const unknown = NetworkStatus(available: true);

  final bool available;

  /// 系统的网络编号。换了编号就是换了网络（Wi-Fi ↔ 蜂窝、连上 VPN）。
  final String? id;
  final Set<String> transports;
  final bool validated;

  factory NetworkStatus.fromMap(Map<Object?, Object?> map) => NetworkStatus(
        available: map['available'] == true,
        id: map['network'] as String?,
        transports: {
          for (final value in map['transports'] as List? ?? const [])
            value.toString(),
        },
        validated: map['validated'] == true,
      );

  /// 只给日志和测试报告看。
  @override
  String toString() => available
      ? '${transports.join('+')}#$id${validated ? '' : ' (unvalidated)'}'
      : 'none';
}

sealed class ConnectionPlatformEvent {
  const ConnectionPlatformEvent();
}

/// 用户在通知上点了「全部断开」。
class KeepAliveStopRequested extends ConnectionPlatformEvent {
  const KeepAliveStopRequested(this.generation);
  final int generation;
}

/// 保活服务不是本 App 让停的：被系统或别人停了，或者「全部断开」后 App 没在 5 秒内响应。
class KeepAliveStopped extends ConnectionPlatformEvent {
  const KeepAliveStopped(this.generation, this.reason);
  final int generation;
  final String reason;
}

class NetworkChanged extends ConnectionPlatformEvent {
  const NetworkChanged(this.status);
  final NetworkStatus status;
}

/// 连接生命周期要用的平台能力（R22）。测试换成假的。
abstract interface class ConnectionPlatform {
  /// [request] 为 null 表示停。
  Future<KeepAliveResult> setKeepAlive(KeepAliveRequest? request);

  /// 手机锁着、要密码/图案/指纹才能解开。没设锁屏密码的手机永远是 false。
  Future<bool> isDeviceLocked();

  Future<NetworkStatus> currentNetwork();

  Stream<ConnectionPlatformEvent> get events;

  /// iOS 的后台宽限，Android 上什么都不做。
  Future<void> beginBackgroundGrace();
  Future<void> endBackgroundGrace();
}

/// 只有手机上有这条平台通道；桌面和 `flutter test`（跑在电脑上）用 [NoConnectionPlatform]。
final connectionPlatformProvider = Provider<ConnectionPlatform>((ref) {
  if (!Platform.isAndroid && !Platform.isIOS) return NoConnectionPlatform();
  final platform = MethodChannelConnectionPlatform();
  ref.onDispose(platform.dispose);
  return platform;
});

/// 没有平台：保活什么都不做，手机永远没锁，网络一直在。测试可以继承它只改需要的。
class NoConnectionPlatform implements ConnectionPlatform {
  @override
  Stream<ConnectionPlatformEvent> get events => const Stream.empty();

  @override
  Future<KeepAliveResult> setKeepAlive(KeepAliveRequest? request) async =>
      KeepAliveResult.unsupported;

  @override
  Future<bool> isDeviceLocked() async => false;

  @override
  Future<NetworkStatus> currentNetwork() async => NetworkStatus.unknown;

  @override
  Future<void> beginBackgroundGrace() async {}

  @override
  Future<void> endBackgroundGrace() async {}
}

class MethodChannelConnectionPlatform implements ConnectionPlatform {
  MethodChannelConnectionPlatform() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('top.xdwa.shun/connection');
  final _events = StreamController<ConnectionPlatformEvent>.broadcast();

  @override
  Stream<ConnectionPlatformEvent> get events => _events.stream;

  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }

  Future<Object?> _onCall(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    final event = switch (call.method) {
      'keepAlive' when args['type'] == 'stopRequested' =>
        KeepAliveStopRequested((args['generation'] as num?)?.toInt() ?? -1),
      'keepAlive' when args['type'] == 'stopped' => KeepAliveStopped(
          (args['generation'] as num?)?.toInt() ?? -1,
          args['reason']?.toString() ?? '',
        ),
      'network' => NetworkChanged(NetworkStatus.fromMap(args)),
      _ => null,
    };
    if (event != null && !_events.isClosed) _events.add(event);
    return null;
  }

  @override
  Future<KeepAliveResult> setKeepAlive(KeepAliveRequest? request) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'setActive',
        {
          'active': request != null,
          if (request != null) ...{
            'generation': request.generation,
            'title': request.title,
            'text': request.text,
          },
        },
      );
      // iOS 回 null。
      if (result == null) return KeepAliveResult(started: request != null);
      return KeepAliveResult(
        started: result['started'] == true,
        notificationsEnabled: result['notifications'] != false,
        error: result['error'] as String?,
      );
    } on MissingPluginException {
      return KeepAliveResult.unsupported;
    } on PlatformException catch (error) {
      return KeepAliveResult(started: false, error: error.message);
    }
  }

  @override
  Future<bool> isDeviceLocked() async {
    try {
      return await _channel.invokeMethod<bool>('isDeviceLocked') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<NetworkStatus> currentNetwork() async {
    try {
      final map =
          await _channel.invokeMethod<Map<Object?, Object?>>('networkState');
      return map == null ? NetworkStatus.unknown : NetworkStatus.fromMap(map);
    } on MissingPluginException {
      return NetworkStatus.unknown;
    } on PlatformException {
      return NetworkStatus.unknown;
    }
  }

  @override
  Future<void> beginBackgroundGrace() async {
    try {
      await _channel.invokeMethod<void>('beginBackgroundGrace');
    } on MissingPluginException {
      // 只有 iOS 有实现。
    }
  }

  @override
  Future<void> endBackgroundGrace() async {
    try {
      await _channel.invokeMethod<void>('endBackgroundGrace');
    } on MissingPluginException {
      // 只有 iOS 有实现。
    }
  }
}
