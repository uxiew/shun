import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/settings.dart';
import '../infrastructure/tailscale/catalog_cache.dart';
import '../infrastructure/tailscale/catalog_cache_repository.dart';
import '../infrastructure/tailscale/tailscale_api.dart';
import 'home_navigation.dart';
import 'settings_controller.dart';
import 'tailscale_catalog_provider.dart';
import 'tailscale_catalog_refresh.dart';

/// 进「连接」页、切回前台时马上读一次，但刚读过这么久以内不再读：来回切底栏不该连着撞 Tailscale。
const catalogEnterRefreshFloor = Duration(seconds: 10);

/// 上次读失败后，多久才自动再试。key 失效或没网时每分钟撞一次没有意义；用户点刷新不受这个限制。
const catalogAutoRefreshBackoff = Duration(minutes: 10);

/// 主机列表里一个目录来源那一组要的东西（R43）。
class CatalogSourceView {
  const CatalogSourceView({
    required this.cache,
    required this.hasSavedCredentials,
    this.refreshing = false,
  });

  final CatalogCache cache;

  /// 本机存了这个来源的 key，点「刷新」能直接读；没存就要到 Tailscale 设置里填。
  final bool hasSavedCredentials;

  /// 正在向 Tailscale 要新列表。
  final bool refreshing;

  String get catalogId => cache.catalogId;

  CatalogSourceView copyWith({bool? refreshing}) => CatalogSourceView(
        cache: cache,
        hasSavedCredentials: hasSavedCredentials,
        refreshing: refreshing ?? this.refreshing,
      );
}

/// 主机列表的 Tailscale 分节用的数据（R43）：本机每个目录来源的缓存，按名字排。
///
/// 在线状态要新（R67，所有者 11-01：以前只有点「刷新」才读，绿点可能是几天前的）：
/// 进这页马上读（[catalogEnterRefreshFloor]），停着时隔用户设的间隔读（[setSyncInterval]）。只能轮询：
/// Tailscale 的 webhook 要有公网服务器收，手机上的 Tailscale App 也不把状态给别的 App。
/// 后台不发请求；没存 key 的不发；读失败不弹框，定时读隔 [catalogAutoRefreshBackoff] 再试，
/// 429 按 Retry-After（Tailscale 自己说多久就等多久）。一次一个来源，正在刷的不会再发。
class CatalogOverviewController extends StateNotifier<List<CatalogSourceView>> {
  CatalogOverviewController({
    required CatalogCacheRepository repository,
    required TailscaleCatalogProvider catalog,
    DateTime Function()? now,
  })  : _repository = repository,
        _catalog = catalog,
        _now = now ?? DateTime.now,
        super(const []);

  final CatalogCacheRepository _repository;
  final TailscaleCatalogProvider _catalog;
  final DateTime Function() _now;
  var _generation = 0;
  Future<void> _latestReload = Future.value();

  var _foreground = true;
  var _visible = false;
  Timer? _timer;

  /// null：不定时读，只在进这页时读。
  Duration? _interval = const Duration(seconds: defaultTailscaleSyncSeconds);

  /// 每进入一次「该自动读」的状态加一：离开再回来时，上一轮等着的那些步骤看到号变了就不再往下走。
  var _autoRound = 0;

  /// 429 带 Retry-After 时，这个时间之前不自动读。放内存：重启后最多多撞一次。
  final _notBefore = <String, DateTime>{};

  bool get _autoActive => _foreground && _visible;

  /// App 切到前台、后台（只认 resumed 和进后台，通知栏下拉这种一闪而过的 inactive 不算）。
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _autoActiveChanged();
  }

  /// 底栏是不是停在「连接」页。别的页看不到状态，不为它们发请求。
  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    _autoActiveChanged();
  }

  /// 用户改了同步间隔。0 秒是不定时读。
  void setSyncInterval(int seconds) {
    final next = seconds <= 0 ? null : Duration(seconds: seconds);
    if (_interval == next) return;
    _interval = next;
    _timer?.cancel();
    _timer = null;
    if (_autoActive) _armTimer(_autoRound);
  }

  void _autoActiveChanged() {
    _timer?.cancel();
    _timer = null;
    final round = ++_autoRound;
    if (_autoActive) unawaited(_autoRefresh(round, entering: true));
  }

  Future<void> _autoRefresh(int round, {bool entering = false}) async {
    unawaited(reload());
    await _reloadsSettled();
    for (final view in state) {
      if (!mounted || round != _autoRound) return;
      if (entering ? _dueOnEnter(view) : _due(view)) {
        await _refreshQuietly(view.catalogId);
      }
    }
    if (!mounted || round != _autoRound) return;
    _armTimer(round);
  }

  /// 没有存 key 的来源就不留定时器：存 key 后 [reload] 会再来这里排。
  void _armTimer(int round) {
    final interval = _interval;
    _timer?.cancel();
    _timer = null;
    if (interval == null || !state.any((view) => view.hasSavedCredentials)) {
      return;
    }
    // 这一轮读完才排下一轮：按「读完的时间」算间隔，下一轮到点时一定已经满间隔，不会被 [_due] 跳过。
    _timer = Timer(interval, () => _autoRefresh(round));
  }

  bool _readable(CatalogSourceView view) {
    if (!view.hasSavedCredentials || view.refreshing) return false;
    final notBefore = _notBefore[view.catalogId];
    return notBefore == null || !_now().isBefore(notBefore);
  }

  /// 刚进来就是要看新的：上次读失败也试，只挡住几秒内重复进出。
  bool _dueOnEnter(CatalogSourceView view) {
    if (!_readable(view)) return false;
    final attempt = view.cache.lastAttempt;
    if (attempt == null) return true;
    final age = _now().difference(attempt.at);
    return age.isNegative || age >= catalogEnterRefreshFloor;
  }

  bool _due(CatalogSourceView view) {
    if (!_readable(view)) return false;
    final attempt = view.cache.lastAttempt;
    if (attempt == null) return true;
    final age = _now().difference(attempt.at);
    // 手机时钟被往回调过：负数当作该读了，不然要等时钟追上来才会再读。
    return age.isNegative ||
        age >=
            (attempt.ok
                ? _interval ?? catalogAutoRefreshBackoff
                : catalogAutoRefreshBackoff);
  }

  /// 打开单个来源的设备页时用：离上次读够久了就读一次，否则什么都不做。
  /// 读了返回结果；不用读或读不了返回 null，不弹任何提示。
  Future<CatalogRefreshOutcome?> refreshIfDue(String catalogId) async {
    await reload();
    final view = state.where((v) => v.catalogId == catalogId).firstOrNull;
    if (view == null || !_due(view)) return null;
    return _refreshQuietly(catalogId);
  }

  Future<CatalogRefreshOutcome?> _refreshQuietly(String catalogId) async {
    try {
      return await refresh(catalogId);
    } on Object {
      // 走不到 Tailscale 那一步（内置目录被停用之类）：同样隔一阵再试，别每分钟重来。
      _notBefore[catalogId] = _now().add(catalogAutoRefreshBackoff);
      return null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 等最新的那次 [reload] 读完。切回「连接」页时页面自己也 reload，先发的那次结果会被扔掉，
  /// 只等它的话 [state] 还是旧的：第一个来源刚加上时看到的是空列表，定时器排不上，要等下次切页才开始读。
  Future<void> _reloadsSettled() async {
    Future<void> latest;
    do {
      latest = _latestReload;
      await latest;
    } while (!identical(latest, _latestReload));
  }

  /// 重读本机缓存。读不了（没有目录、文件坏了、测试环境没有文件系统）就当没有来源：
  /// 只影响这一节显示，主机照常在普通列表里。
  Future<void> reload() => _latestReload = _reload();

  Future<void> _reload() async {
    final generation = ++_generation;
    // 一律复制成可改的列表再排序：仓库没有来源时返回 const 空列表，原地排序会抛 Unsupported operation。
    final caches = <CatalogCache>[];
    try {
      caches.addAll(await _repository.loadAll());
    } on Object {
      caches.clear();
    }
    caches.sort((a, b) => (a.label ?? a.catalogId)
        .toLowerCase()
        .compareTo((b.label ?? b.catalogId).toLowerCase()));
    final views = <CatalogSourceView>[];
    for (final cache in caches) {
      var saved = false;
      try {
        saved = await _catalog.hasSavedCredentials(cache.catalogId);
      } on Object {
        saved = false;
      }
      views.add(CatalogSourceView(cache: cache, hasSavedCredentials: saved));
    }
    // 读的时候又来了一次 reload：以后那次为准，这次的结果可能已经旧了。
    if (!mounted || generation != _generation) return;
    final refreshing = {
      for (final view in state)
        if (view.refreshing) view.catalogId,
    };
    state = [
      for (final view in views)
        refreshing.contains(view.catalogId)
            ? view.copyWith(refreshing: true)
            : view,
    ];
    // 这页开着时第一次存了 key：页面没换，没有别的时机来排定时器。
    if (_autoActive && _timer == null) _armTimer(_autoRound);
  }

  /// 用本机保存的凭据刷新一个来源。这个来源正在刷、或已经不在本机，返回 null，不发请求。
  /// 刷新本身的规矩在 [CatalogRefresher]：只改缓存和「地址仍跟随目录」的主机地址，
  /// 别名、用户名、端口、路线、指纹一概不碰。
  Future<CatalogRefreshOutcome?> refresh(String catalogId) async {
    final view = state.where((v) => v.catalogId == catalogId).firstOrNull;
    if (view == null || view.refreshing) return null;
    _mark(catalogId, true);
    try {
      final outcome = await _catalog.refreshSaved(catalogId);
      final error = outcome.error;
      final retryAfter =
          error is TailscaleRateLimited ? error.retryAfter : null;
      if (retryAfter == null) {
        _notBefore.remove(catalogId);
      } else {
        _notBefore[catalogId] = _now().add(retryAfter);
      }
      return outcome;
    } finally {
      _mark(catalogId, false);
      await reload();
    }
  }

  void _mark(String catalogId, bool refreshing) {
    if (!mounted) return;
    state = [
      for (final view in state)
        view.catalogId == catalogId
            ? view.copyWith(refreshing: refreshing)
            : view,
    ];
  }
}

final catalogOverviewProvider =
    StateNotifierProvider<CatalogOverviewController, List<CatalogSourceView>>(
        (ref) {
  final controller = CatalogOverviewController(
    repository: ref.watch(catalogCacheRepositoryProvider),
    catalog: ref.watch(tailscaleCatalogProvider),
  );
  unawaited(controller.reload());
  ref.listen(
    homeTabProvider,
    (_, tab) => controller.setVisible(tab == 0),
    fireImmediately: true,
  );
  ref.listen(
    settingsControllerProvider.select((value) => value.tailscaleSyncSeconds),
    (_, seconds) => controller.setSyncInterval(seconds),
    fireImmediately: true,
  );
  return controller;
});
