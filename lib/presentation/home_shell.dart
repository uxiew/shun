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
import 'ui/nav_glyphs.dart';
import 'widgets/custom_background.dart';
import 'widgets/session_overview.dart';
import 'widgets/two_finger_swipe.dart';

/// 内容自己滚到浮动底栏底下的页（连接、片段、设置）：它们从 [prism.BottomInsetScope] 拿到底栏的高度，
/// 在列表末尾留白。终端和文件整页停在底栏上方。
const _scrollsUnderDock = {0, 3, 4};

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
    // 键盘弹出时底栏收起（以前的底栏是被键盘盖住），页面也不再给它留位置。
    final dockShown =
        !hideNavigation && MediaQuery.viewInsetsOf(context).bottom == 0;
    final dockInset = dockShown ? prism.NavigationDock.insetOf(context) : 0.0;
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
              // 底栏放在 Scaffold 的底栏位、页面照旧铺到它底下：SnackBar 因此停在底栏上方，
              // 不再盖住底栏的入口（带「撤销」的通知不会自己消失）。
              extendBody: true,
              bottomNavigationBar: dockShown ? _navigationDock(index) : null,
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
                      child: _clearOfDock(
                        index,
                        dockInset,
                        IndexedStack(index: index, children: HomeShell._pages),
                      ),
                    ),
                  ),
                  if (overviewOpen) _overviewLayer(dockInset),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 总览压暗整屏，面板停在底栏上方：底栏浮在这一层上面，开着总览也能直接切页。
  Widget _overviewLayer(double dockInset) => AnimatedBuilder(
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
            Padding(
              padding: EdgeInsets.only(bottom: dockInset),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: FractionalTranslation(
                  translation: Offset(0, 1 - _overview.value),
                  child: child,
                ),
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

  /// 底栏占的高度怎么让：会滚动的页拿到 BottomInsetScope，自己在列表末尾留白，内容从底栏底下
  /// 滚过去；终端、文件整页垫高。两种页外面的部件层数相同，切页不会重建 IndexedStack。
  Widget _clearOfDock(int index, double inset, Widget pages) {
    final under = _scrollsUnderDock.contains(index);
    return Padding(
      padding: EdgeInsets.only(bottom: under ? 0 : inset),
      child: prism.BottomInsetScope(
        inset: under ? inset : 0,
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: inset > 0,
          child: pages,
        ),
      ),
    );
  }

  /// 底栏：Prism 的 NavigationDock，FlClash 手机界面的浮动底栏（所有者 2026-11-21 定，替掉 R85 的
  /// NavigationBar）。
  ///
  /// 浮起的一层不透明（没开 Liquid Glass）：全局自定义背景现在铺满整屏、从底栏四周露出来，底栏
  /// 上的字仍落在不透明的底上（R83 第 4 节记过透明底栏在浅色背景上看不清）。
  /// 入口只收 Glyph 和名字，挂不了 key：读屏的按钮、名字、选中状态由它自己给，测试按这些找入口。
  Widget _navigationDock(int selectedIndex) => prism.NavigationDock(
        key: const ValueKey('home-navigation-bar'),
        selectedIndex: selectedIndex,
        onSelected: (value) {
          ref.read(homeTabProvider.notifier).state = value;
          _closeOverview();
        },
        destinations: [
          for (final (index, label) in _navigationLabels().indexed)
            prism.NavigationDockDestination(
              glyph: ShunNavGlyphs.all[index],
              label: label,
            ),
        ],
      );

  List<String> _navigationLabels() => [
        // 以前叫「保险库」，所有者觉得不像放主机的地方（R26）。英文表里「连接」是按钮上的 Connect，
        // 底栏要的是页名，单独写。
        ShunLocalizations.isEnglish ? 'Hosts' : '连接',
        localized('终端'),
        localized('文件'),
        localized('片段'),
        localized('设置'),
      ];
}

/// 底栏五个入口的顺序，就是 [homeTabProvider] 的值；改顺序等于改所有「切到第 N 页」的地方。
const homeTabIds = ['hosts', 'terminal', 'files', 'snippets', 'settings'];

bool shouldHideHomeNavigation(int tabIndex, bool terminalFullscreen) =>
    tabIndex == 1 && terminalFullscreen;
