import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/app_lock.dart';
import '../../application/settings_controller.dart';
import '../../domain/models/settings.dart';
import '../../infrastructure/device_auth.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';

/// 离开多久后锁的选项，单位秒。
const appLockGraceChoices = <int, String>{
  0: '立即',
  60: '1 分钟',
  300: '5 分钟',
  900: '15 分钟',
  3600: '1 小时',
};

String appLockGraceLabel(int seconds) =>
    appLockGraceChoices[seconds] ?? appLockGraceChoices[60]!;

class AppLockSettingsScreen extends ConsumerStatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  ConsumerState<AppLockSettingsScreen> createState() =>
      _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends ConsumerState<AppLockSettingsScreen> {
  var _busy = false;

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: LText(text)),
    );
  }

  /// 开关都要先过一次验证：开的时候顺便证明这台手机验得过，不会锁上了打不开；
  /// 关的时候，捡到解锁着的 App 的人不能顺手把锁拆了。
  Future<void> _toggle(bool enabled) async {
    setState(() => _busy = true);
    try {
      if (enabled && !await ref.read(deviceAuthProvider).isDeviceSecure()) {
        _message('手机没设屏幕锁，先到系统设置里设一个。');
        return;
      }
      final outcome = await ref
          .read(appLockControllerProvider.notifier)
          .confirm(localized(enabled ? '打开应用锁' : '关闭应用锁'));
      final passed = outcome.result == DeviceAuthResult.success ||
          // 屏幕锁已经去掉了：锁本来就不起作用，允许关。
          (!enabled && outcome.result == DeviceAuthResult.unavailable);
      if (!passed) {
        final message = outcome.message;
        if (message != null) _message(message);
        return;
      }
      await ref
          .read(settingsControllerProvider.notifier)
          .edit((s) => s.copyWith(appLockEnabled: enabled));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _edit(AppSettings Function(AppSettings persisted) change) {
    unawaited(ref.read(settingsControllerProvider.notifier).edit(change));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const LText('应用锁')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          ShunSection(
            children: [
              ShunSwitchRow(
                key: const ValueKey('app-lock-enabled'),
                title: '应用锁',
                hint: '打开 App 要过指纹、面容或手机的 PIN。只挡住打开 App 的人，登录服务器、安全密钥签名照样各问各的。',
                value: settings.appLockEnabled,
                onChanged: _busy ? null : _toggle,
              ),
              if (settings.appLockEnabled) ...[
                ShunOptionsRow<int>(
                  key: const ValueKey('app-lock-grace'),
                  title: '离开多久后锁',
                  value: appLockGraceChoices.containsKey(
                    settings.appLockGraceSeconds,
                  )
                      ? settings.appLockGraceSeconds
                      : 60,
                  options: [
                    for (final entry in appLockGraceChoices.entries)
                      (entry.key, entry.value),
                  ],
                  onChanged: (value) =>
                      _edit((s) => s.copyWith(appLockGraceSeconds: value)),
                ),
                ShunSwitchRow(
                  key: const ValueKey('app-lock-skip-connected'),
                  title: '终端连着时不锁',
                  hint: '有连着的终端时，回来不用解锁。手机被人拿走又没锁屏时，对方能直接看到终端。',
                  value: settings.appLockSkipWhileConnected,
                  onChanged: (value) => _edit(
                      (s) => s.copyWith(appLockSkipWhileConnected: value)),
                ),
                ShunSwitchRow(
                  key: const ValueKey('app-lock-pin-only'),
                  title: '直接用 PIN',
                  hint: '不弹指纹、面容，直接用手机的 PIN 或图案。传感器坏了、手指湿的时候用。',
                  value: settings.appLockPinOnly,
                  onChanged: (value) =>
                      _edit((s) => s.copyWith(appLockPinOnly: value)),
                ),
                ShunSwitchRow(
                  key: const ValueKey('app-lock-weak'),
                  title: '允许弱生物识别',
                  hint: '有些手机的面容解锁系统算弱的，可能被照片骗过。不开就只认指纹这类强的和 PIN。Android 11 起才有效。',
                  value: settings.appLockAllowWeakBiometrics,
                  onChanged: (value) => _edit(
                      (s) => s.copyWith(appLockAllowWeakBiometrics: value)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
