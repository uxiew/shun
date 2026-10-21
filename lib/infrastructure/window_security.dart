import 'dart:io';

import 'package:flutter/services.dart';

/// 给 App 的窗口开关防截屏（R44）。什么时候开由 [SensitiveScreenGuard] 算，这里只管告诉平台。
abstract interface class WindowSecurity {
  Future<void> setSecure(bool secure);
}

/// Android 给窗口加 FLAG_SECURE（见 WindowSecurityChannel.kt）。
///
/// iOS 没有对应的东西：系统不让 App 拦截屏，只在截完以后通知一声，所以别的平台什么都不做，
/// 使用手册写明只有 Android 有。
class PlatformWindowSecurity implements WindowSecurity {
  const PlatformWindowSecurity();

  static const _channel = MethodChannel('top.xdwa.shun/window_security');

  @override
  Future<void> setSecure(bool secure) async {
    if (!Platform.isAndroid) return;
    // 不吞 MissingPluginException：通道跟引擎一起建（ProcessEngine），Android 上正常不会缺；
    // 真缺了就是防截屏失效了，要报出来，不能当没事。
    await _channel.invokeMethod<void>('setSecure', {'secure': secure});
  }
}
