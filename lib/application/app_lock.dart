import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/settings.dart';
import '../infrastructure/device_auth.dart';
import '../infrastructure/storage/vault_repository.dart';
import '../presentation/localization/localized_widgets.dart';
import 'session_controller.dart';
import 'settings_controller.dart';

/// 从自己拉起的页面（选文件、扫码）回来，这么久之内不锁。设成「立即」时，选个文件回来也要解锁就太烦了；
/// 又不能不设上限：选文件页开着人走开，别人选一下就回到解锁的 App 了。
const appLockOwnActivityGrace = Duration(minutes: 1);

class AppLockState {
  const AppLockState({
    this.locked = false,
    this.covered = false,
    this.authenticating = false,
    this.failure,
  });

  /// 要过验证才能看到内容。
  final bool locked;

  /// 刚离开 App：先盖上，回来再决定锁不锁。回来的第一帧就不会露内容。
  /// 最近任务的缩略图不靠它，系统截得比这快，见 MainActivity.onPause。
  final bool covered;

  final bool authenticating;

  /// 系统说的失败原因。
  final String? failure;

  bool get obscured => locked || covered;
}

/// 应用锁（R46）。
///
/// 只管「能不能看到这个 App」。它不碰任何连接、凭据或签名：解锁成功、宽限期内返回、终端连着免锁，都不等于同意签名
/// 或访问请求，那些各问各的（R36、R59）。锁着时后台恢复照 SEC07 走，这里不插手。
class AppLockController extends StateNotifier<AppLockState> {
  AppLockController({
    required DeviceAuth auth,
    required AppSettings settings,
    required this.hasConnectedTerminal,
    this.promptTitle = _defaultTitle,
    DateTime Function() now = DateTime.now,
  })  : _auth = auth,
        _settings = settings,
        _now = now,
        super(AppLockState(locked: settings.appLockEnabled)) {
    _auth.onActivityPaused = activityPaused;
    // 冷启动算一次「刚从外面回来」：第一次 resumed 时弹验证。
    if (settings.appLockEnabled) _leftAt = _now();
    unawaited(_applyProtectRecents());
  }

  static String _defaultTitle() => '解锁 shun';

  final DeviceAuth _auth;
  final DateTime Function() _now;
  final bool Function() hasConnectedTerminal;
  final String Function() promptTitle;
  AppSettings _settings;

  /// 什么时候离开的。null 表示没离开过：验证框消失、下拉通知栏回来的 resumed 不算回来。
  /// 没有这个区分的话，取消验证 → resumed → 又弹验证，用户永远退不出来。
  DateTime? _leftAt;
  var _ownActivity = false;
  var _unlocking = false;
  var _confirming = false;

  void settingsChanged(AppSettings settings) {
    final wasEnabled = _settings.appLockEnabled;
    _settings = settings;
    if (wasEnabled != settings.appLockEnabled) {
      unawaited(_applyProtectRecents());
    }
    if (!settings.appLockEnabled && state.obscured) {
      state = const AppLockState();
    }
  }

  Future<void> _applyProtectRecents() async {
    if (!Platform.isAndroid) return;
    try {
      await _auth.setProtectRecents(_settings.appLockEnabled);
    } on MissingPluginException {
      // 单测里没有平台通道。
    }
  }

  /// 原生 onPause。比 Flutter 的 paused 早（那时已经不出帧），这时候盖还来得及画一帧。
  ///
  /// 不用 Flutter 的 inactive：下拉通知栏、输入法弹窗抢焦点也是 inactive，终端会被盖住。
  void activityPaused(bool ownActivity) => _left(own: ownActivity);

  void lifecycleChanged(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        _returned();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // 正常离开已经由 onPause 记过了。这里接住画中画窗口被关掉：那时没有 onPause 消息。
        _left(own: false);
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _left({required bool own}) {
    // 解锁验证开着：系统 PIN 页把我们顶到后台不算离开，本来就锁着。
    if (!_settings.appLockEnabled || _unlocking) return;
    _leftAt ??= _now();
    _ownActivity = _ownActivity || own || _confirming;
    if (!state.covered) {
      state = AppLockState(
        locked: state.locked,
        covered: true,
        failure: state.failure,
      );
    }
  }

  void _returned() {
    final left = _leftAt;
    final own = _ownActivity;
    _leftAt = null;
    _ownActivity = false;
    if (_unlocking) return;
    if (!_settings.appLockEnabled) {
      if (state.obscured) state = const AppLockState();
      return;
    }
    if (left == null) {
      if (state.covered) {
        state = AppLockState(locked: state.locked, failure: state.failure);
      }
      return;
    }
    if (state.locked || _expired(left, own)) {
      state = const AppLockState(locked: true);
      unawaited(unlock());
    } else {
      state = const AppLockState();
    }
  }

  bool _expired(DateTime left, bool own) {
    if (_settings.appLockSkipWhileConnected && hasConnectedTerminal()) {
      return false;
    }
    final away = _now().difference(left);
    final grace = Duration(seconds: _settings.appLockGraceSeconds);
    // 手机时间被往回拨算过期：不然改一下时钟就能绕过。
    if (away.isNegative) return true;
    return away >=
        (own && grace < appLockOwnActivityGrace
            ? appLockOwnActivityGrace
            : grace);
  }

  /// 弹系统验证。没锁着或者已经在弹就什么也不做。
  Future<void> unlock() async {
    if (!state.locked || _unlocking || _confirming) return;
    _unlocking = true;
    state = const AppLockState(locked: true, authenticating: true);
    final outcome = await _authenticate(promptTitle());
    _unlocking = false;
    if (!mounted) return;
    _leftAt = null;
    _ownActivity = false;
    switch (outcome.result) {
      case DeviceAuthResult.success:
        state = const AppLockState();
      case DeviceAuthResult.unavailable:
        // 手机后来去掉了屏幕锁，系统验证不了。放行，不把人永远挡在外面：能去掉屏幕锁的人本来就过得了验证。
        state = const AppLockState();
      case DeviceAuthResult.canceled:
        state = const AppLockState(locked: true);
      case DeviceAuthResult.failed:
        state = AppLockState(locked: true, failure: outcome.message);
    }
  }

  /// App 开着时要再过一次系统验证（开关应用锁、sudo 键），都走这里，不要直接调 [DeviceAuth]。
  ///
  /// 系统 PIN 页会把 App 顶到后台。直接调的话，设成「立即」时回来又锁一次、再弹一次框。这里把那次离开算成
  /// 从自己拉起的页面回来：[appLockOwnActivityGrace] 内不锁，超过了照样锁（验证开着时按 HOME 走开的情况）。
  Future<DeviceAuthOutcome> confirm(String title, {String? description}) async {
    if (_unlocking || _confirming) {
      return const DeviceAuthOutcome(DeviceAuthResult.canceled);
    }
    _confirming = true;
    final outcome = await _authenticate(title, description: description);
    _confirming = false;
    if (mounted && outcome.result == DeviceAuthResult.success) {
      _leftAt = null;
      _ownActivity = false;
      state = const AppLockState();
    }
    return outcome;
  }

  Future<DeviceAuthOutcome> _authenticate(
    String title, {
    String? description,
  }) async {
    try {
      return await _auth.authenticate(
        title: title,
        description: description,
        pinOnly: _settings.appLockPinOnly,
        allowWeak: _settings.appLockAllowWeakBiometrics,
      );
    } on PlatformException catch (error) {
      return DeviceAuthOutcome(DeviceAuthResult.failed, error.message);
    } on MissingPluginException catch (error) {
      // 不接住的话 _unlocking 一直是真，这个 App 就再也解不开了。
      return DeviceAuthOutcome(DeviceAuthResult.failed, error.message);
    }
  }
}

final appLockControllerProvider =
    StateNotifierProvider<AppLockController, AppLockState>((ref) {
  final controller = AppLockController(
    auth: ref.watch(deviceAuthProvider),
    // 同步读：设置异步加载完再盖就露内容了，第一帧就要知道开没开。
    settings: ref.watch(vaultRepositoryProvider).loadSettingsPreview(),
    hasConnectedTerminal: () => ref
        .read(sessionControllerProvider)
        .sessions
        .any((session) => session.connected),
    promptTitle: () => localized('解锁 shun'),
  );
  ref.listen(settingsControllerProvider, (_, next) {
    controller.settingsChanged(next);
  });
  return controller;
});
