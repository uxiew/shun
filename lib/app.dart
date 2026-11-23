import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/app_lock.dart';
import 'application/auto_sync_controller.dart';
import 'application/catalog_overview.dart';
import 'application/connection_events.dart';
import 'application/fork_features.dart';
import 'application/sensitive_screen.dart';
import 'application/settings_controller.dart';
import 'application/session_controller.dart';
import 'infrastructure/ssh/connection_platform_service.dart';
import 'presentation/home_shell.dart';
import 'presentation/ui/prism_theme.dart';
import 'presentation/ui/shun_ui_host.dart';
import 'presentation/widgets/security_key_prompt.dart';

class ShunApp extends ConsumerStatefulWidget {
  const ShunApp({super.key});

  @override
  ConsumerState<ShunApp> createState() => _ShunAppState();
}

class _ShunAppState extends ConsumerState<ShunApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final ProviderSubscription<bool> _autoSyncSubscription;
  late final ProviderSubscription<bool> _screenshotSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 会话控制器一启动就建：它要放回上次被系统结束前的标签、听通知上的「全部断开」和网络变化，
    // 保活服务也由它按会话状态开关（R22）。
    ref.read(sessionControllerProvider.notifier);
    // 连接记录（R25）一启动就读盘：主机菜单按已经读到的判断「有没有记录」，不在点开菜单时等读盘。
    ref.read(connectionEventLogProvider.notifier);
    // 连接在哪都可能走到要碰钥匙（新开标签、重连、测试连接），弹框不依赖发起连接的页面还在不在。
    ref.read(sshServiceProvider).securityKeySigner =
        (request) => signWithSecurityKey(
              _navigatorKey.currentContext,
              ref.read(securityKeyChannelProvider),
              request,
            );
    _autoSyncSubscription = ref.listenManual<bool>(
      settingsControllerProvider.select((settings) => settings.autoSyncEnabled),
      (_, enabled) => ref
          .read(autoSyncControllerProvider.notifier)
          .setEnabled(enabled && ref.read(forkFeaturesProvider).cloudSync),
      fireImmediately: true,
    );
    // 「敏感页面允许截屏」拨了马上生效，开着的密码页也跟着变（R44）。
    _screenshotSubscription = ref.listenManual<bool>(
      settingsControllerProvider
          .select((settings) => settings.allowSensitiveScreenshots),
      (_, allowed) => SensitiveScreenGuard.instance.allowScreenshots = allowed,
      fireImmediately: true,
    );
    // 应用锁第一帧就要盖上（AppLockGate 会读它）；已经在前台的话，第一帧画完就弹验证。
    // 不在前台（比如还在后台恢复）就等 resumed，那时才有 Activity 能弹。
    final lock = ref.read(appLockControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        lock.lifecycleChanged(AppLifecycleState.resumed);
      }
    });
  }

  @override
  void dispose() {
    _screenshotSubscription.close();
    _autoSyncSubscription.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(appLockControllerProvider.notifier).lifecycleChanged(state);
    final platform = ref.read(connectionPlatformProvider);
    if (state == AppLifecycleState.resumed) {
      unawaited(platform.endBackgroundGrace());
      ref.read(sessionControllerProvider.notifier).setBackgrounded(false);
      ref.read(autoSyncControllerProvider.notifier).onAppResumed();
      ref.read(catalogOverviewProvider.notifier).setForeground(true);
    } else {
      unawaited(platform.beginBackgroundGrace());
      // detached：界面（Activity）走了、引擎还留着（有会话时，R22），会话在后台接着跑。
      if (state != AppLifecycleState.inactive) {
        ref.read(sessionControllerProvider.notifier).setBackgrounded(true);
        ref.read(catalogOverviewProvider.notifier).setForeground(false);
      }
    }
  }

  /// 锁着时返回键退到桌面，不让它把盖子底下的页面弹掉。
  /// 这里先于 ShunUiHost 的导航器收到：观察者按注册顺序问，这个类比宿主先建。
  @override
  Future<bool> didPopRoute() async {
    if (!ref.read(appLockControllerProvider).obscured) return false;
    await SystemNavigator.pop();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final mode = switch (settings.themeMode) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    return ShunUiHost(
      navigatorKey: _navigatorKey,
      theme: ShunUiTheme.resolve(Brightness.light, settings.uiThemeId),
      darkTheme: ShunUiTheme.resolve(Brightness.dark, settings.uiThemeId),
      themeMode: mode,
      locale: settings.language == 'en'
          ? const Locale('en')
          : const Locale('zh', 'CN'),
      home: const HomeShell(),
    );
  }
}
