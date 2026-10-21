import 'dart:async';

import '../infrastructure/window_security.dart';

/// 屏幕上现在有没有带密码、私钥口令、代理口令、token 的页面（R44），有就让窗口防截屏。
///
/// 每个正显示的 SecretContent 算一个，一个都没有就放开。用户在设置里打开
/// 「敏感页面允许截屏」时一律不加。只在结果变了时告诉平台，连着开关两个对话框不会来回切。
class SensitiveScreenGuard {
  SensitiveScreenGuard(this._window);

  /// App 只有一个窗口，守卫也只有一个。SecretContent 直接用它、不经 Riverpod：
  /// 密码对话框从哪里弹都行，不用管外面有没有 ProviderScope、保险库起没起来。
  /// 「敏感页面允许截屏」由 ShunApp 同步进来。测试里换成记录调用的。
  static SensitiveScreenGuard instance =
      SensitiveScreenGuard(const PlatformWindowSecurity());

  final WindowSecurity _window;
  final _showing = <Object>{};
  var _allowScreenshots = false;

  // 和 Android 窗口的初始状态一致：不带 FLAG_SECURE。
  var _applied = false;

  bool get secure => _showing.isNotEmpty && !_allowScreenshots;

  set allowScreenshots(bool allowed) {
    _allowScreenshots = allowed;
    _apply();
  }

  void show(Object holder) {
    if (_showing.add(holder)) _apply();
  }

  void hide(Object holder) {
    if (_showing.remove(holder)) _apply();
  }

  void _apply() {
    final wanted = secure;
    if (wanted == _applied) return;
    _applied = wanted;
    unawaited(_window.setSecure(wanted));
  }
}
