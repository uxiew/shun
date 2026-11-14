import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

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
              bottomNavigationBar:
                  hideNavigation ? null : _navigationBar(index),
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

  /// 底栏（R85）：Prism 的 NavigationBar，FlClash 手机界面用的就是它。
  ///
  /// 一直不透明（Prism 的浮起层颜色），全局自定义背景只铺到底栏上方。以前全局背景时底栏透明、
  /// 背景从底下透出来，浅色背景上底栏的字看不清（R83 第 4 节）。
  /// 图标用 Material 的：Prism 只带通用的界面符号，没有服务器、终端、文件夹这类图标。
  Widget _navigationBar(int selectedIndex) {
    const icons = [
      (Icons.dns_outlined, Icons.dns),
      (Icons.terminal_outlined, Icons.terminal),
      (Icons.folder_outlined, Icons.folder),
      (Icons.code_outlined, Icons.code),
      (Icons.settings_outlined, Icons.settings),
    ];
    final labels = [
      // 以前叫「保险库」，所有者觉得不像放主机的地方（R26）。英文表里「连接」是按钮上的 Connect，
      // 底栏要的是页名，单独写。
      ShunLocalizations.isEnglish ? 'Hosts' : '连接',
      localized('终端'),
      localized('文件'),
      localized('片段'),
      localized('设置'),
    ];
    return prism.NavigationBar(
      key: const ValueKey('home-navigation-bar'),
      selectedIndex: selectedIndex,
      onDestinationSelected: (value) {
        ref.read(homeTabProvider.notifier).state = value;
        _closeOverview();
      },
      destinations: [
        for (final (index, (outlined, filled)) in icons.indexed)
          prism.NavigationDestination(
            icon: KeyedSubtree(
              key: homeNavigationKey(index),
              child: Icon(index == selectedIndex ? filled : outlined),
            ),
            label: labels[index],
          ),
      ],
    );
  }
}

/// 底栏五个入口的 key（R85）：测试和设备脚本按它找入口，不按导航控件的类型找。
/// 顺序就是 [homeTabProvider] 的值；改顺序等于改所有「切到第 N 页」的地方。
const homeTabIds = ['hosts', 'terminal', 'files', 'snippets', 'settings'];

ValueKey<String> homeNavigationKey(int index) =>
    ValueKey('home-nav-${homeTabIds[index]}');

bool shouldHideHomeNavigation(int tabIndex, bool terminalFullscreen) =>
    tabIndex == 1 && terminalFullscreen;
