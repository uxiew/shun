import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/home_navigation.dart';
import '../application/settings_controller.dart';
import '../infrastructure/ssh/terminal_picture_in_picture_service.dart';
import 'localization/localized_widgets.dart';
import 'screens/settings_screen.dart';
import 'screens/sftp_screen.dart';
import 'screens/snippets_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/uuremote_screen.dart';
import 'screens/vault_screen.dart';
import 'widgets/custom_background.dart';
import 'widgets/session_overview.dart';
import 'widgets/two_finger_swipe.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  static const _pages = [
    VaultScreen(),
    TerminalScreen(),
    SftpScreen(),
    SnippetsScreen(),
    SettingsScreen(),
  ];

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with SingleTickerProviderStateMixin {
  /// 会话总览（F35）弹出来多少：0 是没有，跟手指走，松手后自己弹到头或收回去。
  late final _overview = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addStatusListener((_) {
      if (mounted) setState(() {});
    });

  @override
  void dispose() {
    _overview.dispose();
    super.dispose();
  }

  /// 总览现在是矮的一层，手指走这么远正好完全拉出来。
  static const _overviewDragDistance = 300.0;

  void _dragOverview(double delta) {
    _overview.value -= delta / _overviewDragDistance;
  }

  /// 松手后总览去哪：甩得快看方向，慢慢拖看停在哪。
  ///
  /// 拉出来和往下收的线不同：拉出来过 35% 就开，往下收拖掉 25% 就收。共用一条的话，收的时候要拖过
  /// 面板的 65%，而从卡片起手拖到面板底只有 42%，手慢一点就弹回去，看着像滑不动。
  void _settleOverview(double velocity, {double keepOpenAbove = .35}) {
    if (velocity < -300 ||
        (velocity <= 300 && _overview.value > keepOpenAbove)) {
      unawaited(_overview.forward());
    } else {
      _closeOverview();
    }
  }

  void _closeOverview() => unawaited(_overview.reverse());

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(homeTabProvider);
    final terminalFullscreen = ref.watch(terminalFullscreenProvider);
    final terminalPictureInPicture =
        ref.watch(terminalPictureInPictureProvider);
    final settings = ref.watch(settingsControllerProvider);
    final customBackground = customBackgroundAppliesToTab(settings, index);
    final globalBackground = hasGlobalCustomBackground(settings);
    final hideNavigation = shouldHideHomeNavigation(
      index,
      terminalFullscreen || terminalPictureInPicture,
    );
    final overviewOpen = !_overview.isDismissed && !terminalPictureInPicture;
    ref.listen(
      sessionOverviewRequestProvider,
      (_, __) => unawaited(_overview.forward()),
    );
    // 总览只属于终端页：关掉最后一个标签会被带回连接页，不收的话一层空总览盖在连接页上。
    ref.listen(homeTabProvider, (_, tab) {
      if (tab != 1) _closeOverview();
    });
    // UU 远程的回调从 App 一启动就要接（冷启动带进来的也算），绑定回来要在任何页面都能弹确认框。
    return UuRemoteListener(
      child: PopScope(
        canPop: !hideNavigation && !overviewOpen,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (overviewOpen) {
            _closeOverview();
          } else if (hideNavigation) {
            if (terminalPictureInPicture) {
              ref.read(terminalPictureInPictureProvider.notifier).state = false;
              unawaited(TerminalPictureInPictureService.stop());
            } else {
              ref.read(terminalFullscreenProvider.notifier).state = false;
            }
          }
        },
        // 选中终端页时，两指在屏幕哪里上滑都能调出总览（所有者 11-01）。
        child: TwoFingerSwipeHandlers(
          onUpdate: _dragOverview,
          onEnd: _settleOverview,
          child: TwoFingerSwipeUp(
            eager: false,
            enabled: () =>
                ref.read(homeTabProvider) == 1 &&
                !ref.read(terminalPictureInPictureProvider) &&
                _overview.isDismissed,
            child: Scaffold(
              extendBody: globalBackground,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  if (customBackground)
                    CustomBackgroundImage(settings: settings),
                  Theme(
                    data: customBackground
                        ? Theme.of(context).copyWith(
                            scaffoldBackgroundColor: Colors.transparent,
                            appBarTheme: Theme.of(context).appBarTheme.copyWith(
                                  backgroundColor: Colors.transparent,
                                ),
                          )
                        : Theme.of(context),
                    // 总览开着时下面的页不能有焦点：键盘会盖住总览，打的字也不知道去了哪。从「更多」打开时
                    // 菜单一关焦点就还给终端，只 unfocus 一次拦不住。点卡片切过去也因此不弹键盘：先看整屏输出，
                    // 底栏也还在。
                    child: ExcludeFocus(
                      excluding: overviewOpen,
                      child: IndexedStack(
                          index: index, children: HomeShell._pages),
                    ),
                  ),
                  if (overviewOpen) _overviewLayer(),
                ],
              ),
              bottomNavigationBar: hideNavigation
                  ? null
                  : _navigationBar(
                      context,
                      index,
                      transparent: globalBackground,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _overviewLayer() => AnimatedBuilder(
        animation: _overview,
        builder: (context, child) => Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('session-overview-scrim'),
              onTap: _closeOverview,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: .5 * _overview.value),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: FractionalTranslation(
                translation: Offset(0, 1 - _overview.value),
                child: child,
              ),
            ),
          ],
        ),
        child: GestureDetector(
          onVerticalDragUpdate: (details) =>
              _dragOverview(details.primaryDelta ?? 0),
          onVerticalDragEnd: (details) => _settleOverview(
            details.primaryVelocity ?? 0,
            keepOpenAbove: .75,
          ),
          child: SessionOverview(onClose: _closeOverview),
        ),
      );

  Widget _navigationBar(
    BuildContext context,
    int selectedIndex, {
    required bool transparent,
  }) {
    final navigation = NavigationBar(
      key: const ValueKey('home-navigation-bar'),
      selectedIndex: selectedIndex,
      onDestinationSelected: (value) {
        ref.read(homeTabProvider.notifier).state = value;
        _closeOverview();
      },
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.dns_outlined),
          selectedIcon: const Icon(Icons.dns),
          // 以前叫「保险库」，所有者觉得不像放主机的地方（R26）。英文表里「连接」是按钮上的 Connect，
          // 底栏要的是页名，单独写。
          label: ShunLocalizations.isEnglish ? 'Hosts' : '连接',
        ),
        NavigationDestination(
          icon: const Icon(Icons.terminal_outlined),
          selectedIcon: const Icon(Icons.terminal),
          label: localized('终端'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.folder_outlined),
          selectedIcon: const Icon(Icons.folder),
          label: localized('文件'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.code_outlined),
          selectedIcon: const Icon(Icons.code),
          label: localized('片段'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: localized('设置'),
        ),
      ],
    );
    if (!transparent) return navigation;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        navigationBarTheme: theme.navigationBarTheme.copyWith(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      child: navigation,
    );
  }
}

bool shouldHideHomeNavigation(int tabIndex, bool terminalFullscreen) =>
    tabIndex == 1 && terminalFullscreen;
