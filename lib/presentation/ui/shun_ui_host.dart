import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../localization/localized_widgets.dart';
import '../terminal/ghostty_terminal_view.dart';
import '../widgets/app_lock_gate.dart';
import 'material_compat.dart';
import 'prism_localizations.dart';
import 'prism_theme.dart';

/// One application and one root navigator, with every visual layer inside the
/// existing app lock. A PrismApp/MaterialApp pair would create two route trees.
///
/// [theme]/[darkTheme] are the one semantic theme per brightness (R83); the
/// Prism and the Material representation below both come from it. Switching
/// swaps them in place in a single frame: no ThemeCrossFade/AnimatedTheme,
/// which would screenshot or lerp the live terminals.
class ShunUiHost extends StatefulWidget {
  const ShunUiHost({
    super.key,
    required this.navigatorKey,
    required this.theme,
    required this.darkTheme,
    this.themeMode = ThemeMode.system,
    required this.locale,
    required this.home,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final ShunUiTheme theme;
  final ShunUiTheme darkTheme;
  final ThemeMode themeMode;
  final Locale locale;
  final Widget home;

  @override
  State<ShunUiHost> createState() => _ShunUiHostState();
}

class _ShunUiHostState extends State<ShunUiHost> {
  late final _heroController = HeroController(
    createRectTween: (begin, end) =>
        MaterialRectArcTween(begin: begin, end: end),
  );

  @override
  void dispose() {
    _heroController.dispose();
    super.dispose();
  }

  ShunUiTheme _themeOf(BuildContext context) {
    final dark = switch (widget.themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
    return dark ? widget.darkTheme : widget.theme;
  }

  Widget _buildLayers(BuildContext context, Widget? navigator) {
    final ui = _themeOf(context);
    final theme = materialThemeFor(
      ui,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
    return Theme(
      data: theme,
      child: DefaultTextStyle(
        style: theme.textTheme.bodyMedium!,
        child: prism.Theme(
          data: ui.prismTheme,
          child: Builder(
            builder: (context) {
              final scaler = MediaQuery.textScalerOf(context);
              // Prism's Measure currently accepts a linear factor. Use the
              // body-size ratio only for its metrics; do not replace the
              // platform's (possibly nonlinear) MediaQuery text scaler.
              final measure = prism.Measure.of(
                context,
                scaler.scale(16) / 16,
              );
              return prism.MeasureScope(
                measure: measure,
                child: prism.ViewScope(
                  size: MediaQuery.sizeOf(context),
                  isMobile: ui.platform == TargetPlatform.android ||
                      ui.platform == TargetPlatform.iOS,
                  child: GhosttyDetachedThemeSync(
                    child: AppLockGate(
                      child: ScaffoldMessenger(
                        child: DefaultSelectionStyle(
                          selectionColor: theme
                                  .textSelectionTheme.selectionColor ??
                              theme.colorScheme.primary.withValues(alpha: 0.4),
                          cursorColor: theme.textSelectionTheme.cursorColor ??
                              theme.colorScheme.primary,
                          child: ScrollConfiguration(
                            behavior: const MaterialScrollBehavior(),
                            child: prism.BannerHost(
                              stacked: false,
                              topInset: 0,
                              child: prism.RemoteFocusAdapter(
                                enabled: false,
                                child: Overlay.wrap(
                                  child: navigator ?? const SizedBox.shrink(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ShunLocalizations.use(widget.locale.languageCode);
    return HeroControllerScope(
      controller: _heroController,
      child: WidgetsApp(
        navigatorKey: widget.navigatorKey,
        title: 'shun',
        color: widget.theme.colorScheme.primary,
        debugShowCheckedModeBanner: false,
        locale: widget.locale,
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: const [
          ShunPrismLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // HomeShell owns live terminal views. Do not use CardRouteMixin here:
        // its private screenshot path is independent of allowSnapshotting.
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          allowSnapshotting: false,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
        ),
        builder: _buildLayers,
        home: widget.home,
      ),
    );
  }
}
