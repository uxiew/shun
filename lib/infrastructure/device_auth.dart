import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DeviceAuthResult {
  success,

  /// 用户点了取消、退出了，或者验证页被系统收了。
  canceled,

  /// 手机没设屏幕锁，系统没法验证。
  unavailable,

  failed,
}

class DeviceAuthOutcome {
  const DeviceAuthOutcome(this.result, [this.message]);

  final DeviceAuthResult result;

  /// 系统给的原因，已经是手机当前的语言。
  final String? message;
}

/// 系统的生物识别和手机 PIN。不自建密码（R46），实现在 android/.../AppLockChannel.kt。
abstract class DeviceAuth {
  /// 手机有没有设屏幕锁。
  Future<bool> isDeviceSecure();

  /// [description] 显示在系统验证框上，写清按下去会发生什么。
  Future<DeviceAuthOutcome> authenticate({
    required String title,
    String? description,
    required bool pinOnly,
    required bool allowWeak,
  });

  /// 最近任务存不存缩略图。
  Future<void> setProtectRecents(bool enabled);

  /// 界面退到后台时调，参数是否因为打开了自己拉起的页面（选文件、扫码）。
  set onActivityPaused(void Function(bool ownActivity)? callback);
}

class PlatformDeviceAuth implements DeviceAuth {
  PlatformDeviceAuth() {
    _channel.setMethodCallHandler(_handle);
  }

  static const _channel = MethodChannel('top.xdwa.shun/app_lock');

  void Function(bool ownActivity)? _onActivityPaused;

  @override
  set onActivityPaused(void Function(bool ownActivity)? callback) =>
      _onActivityPaused = callback;

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'activityPaused') return;
    final args = call.arguments as Map<Object?, Object?>?;
    _onActivityPaused?.call(args?['ownActivity'] == true);
  }

  @override
  Future<bool> isDeviceSecure() async =>
      await _channel.invokeMethod<bool>('isDeviceSecure') ?? false;

  @override
  Future<DeviceAuthOutcome> authenticate({
    required String title,
    String? description,
    required bool pinOnly,
    required bool allowWeak,
  }) async {
    final reply = await _channel.invokeMapMethod<String, Object?>(
      'authenticate',
      {
        'title': title,
        'description': description,
        'pinOnly': pinOnly,
        'allowWeak': allowWeak,
      },
    );
    return DeviceAuthOutcome(
      switch (reply?['result']) {
        'success' => DeviceAuthResult.success,
        'canceled' => DeviceAuthResult.canceled,
        'unavailable' => DeviceAuthResult.unavailable,
        _ => DeviceAuthResult.failed,
      },
      reply?['message'] as String?,
    );
  }

  @override
  Future<void> setProtectRecents(bool enabled) =>
      _channel.invokeMethod<void>('setProtectRecents', {'enabled': enabled});
}

final deviceAuthProvider = Provider<DeviceAuth>((ref) => PlatformDeviceAuth());
