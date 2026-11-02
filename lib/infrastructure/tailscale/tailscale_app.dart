import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 拉起手机上的 Tailscale App（R77）。桥在 android/.../TailscaleAppBridge.kt。
abstract final class TailscaleApp {
  static const _channel = MethodChannel('top.xdwa.shun/tailscale_app');

  /// 只有 Android 有这座桥，别的平台不给按钮。
  static bool get supported => defaultTargetPlatform == TargetPlatform.android;

  /// false：手机上没装，或系统不让打开。
  static Future<bool> open() async =>
      await _channel.invokeMethod<bool>('open') ?? false;
}
