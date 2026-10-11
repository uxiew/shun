import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/auto_sync_controller.dart';
import 'application/fork_features.dart';
import 'application/settings_controller.dart';
import 'application/session_controller.dart';
import 'infrastructure/ssh/connection_platform_service.dart';
import 'presentation/home_shell.dart';
import 'presentation/localization/localized_widgets.dart';
import 'presentation/theme.dart';

class ShunApp extends ConsumerStatefulWidget {
  const ShunApp({super.key});

  @override
  ConsumerState<ShunApp> createState() => _ShunAppState();
}

class _ShunAppState extends ConsumerState<ShunApp> with WidgetsBindingObserver {
  late final ProviderSubscription<bool> _autoSyncSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 会话控制器一启动就建：它要放回上次被系统结束前的标签、听通知上的「全部断开」和网络变化，
    // 保活服务也由它按会话状态开关（R22）。
    ref.read(sessionControllerProvider.notifier);
    _autoSyncSubscription = ref.listenManual<bool>(
      settingsControllerProvider.select((settings) => settings.autoSyncEnabled),
      (_, enabled) => ref
          .read(autoSyncControllerProvider.notifier)
          .setEnabled(enabled && ref.read(forkFeaturesProvider).cloudSync),
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _autoSyncSubscription.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final platform = ref.read(connectionPlatformProvider);
    if (state == AppLifecycleState.resumed) {
      unawaited(platform.endBackgroundGrace());
      ref.read(sessionControllerProvider.notifier).setBackgrounded(false);
      ref.read(autoSyncControllerProvider.notifier).onAppResumed();
    } else {
      unawaited(platform.beginBackgroundGrace());
      // detached：界面（Activity）走了、引擎还留着（有会话时，R22），会话在后台接着跑。
      if (state != AppLifecycleState.inactive) {
        ref.read(sessionControllerProvider.notifier).setBackgrounded(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    ShunLocalizations.use(settings.language);
    final mode = switch (settings.themeMode) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    return MaterialApp(
      // Android 最近任务列表显示的名字；与原版 Netcatty 同机并存时靠它区分。所有者 2026-10-11 定为 shun。
      title: 'shun',
      debugShowCheckedModeBanner: false,
      theme: ShunTheme.build(Brightness.light, settings.uiThemeId),
      darkTheme: ShunTheme.build(Brightness.dark, settings.uiThemeId),
      themeMode: mode,
      locale: settings.language == 'en'
          ? const Locale('en')
          : const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeShell(),
    );
  }
}
