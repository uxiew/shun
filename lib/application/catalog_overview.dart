import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../infrastructure/tailscale/catalog_cache.dart';
import '../infrastructure/tailscale/catalog_cache_repository.dart';
import 'tailscale_catalog_provider.dart';
import 'tailscale_catalog_refresh.dart';

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
/// 只有用户点「刷新」才向 Tailscale 发请求：打开列表、切回首页、下拉都只重读本机缓存文件。
/// 一次一个来源，正在刷的再点不会再发。这是 R11、R12 的规矩：没有后台轮询、不自动重试，
/// 不为了显示控制面状态去频繁要列表（Tailscale 会回 429）。
class CatalogOverviewController extends StateNotifier<List<CatalogSourceView>> {
  CatalogOverviewController({
    required CatalogCacheRepository repository,
    required TailscaleCatalogProvider catalog,
  })  : _repository = repository,
        _catalog = catalog,
        super(const []);

  final CatalogCacheRepository _repository;
  final TailscaleCatalogProvider _catalog;
  var _generation = 0;

  /// 重读本机缓存。读不了（没有目录、文件坏了、测试环境没有文件系统）就当没有来源：
  /// 只影响这一节显示，主机照常在普通列表里。
  Future<void> reload() async {
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
  }

  /// 用本机保存的凭据刷新一个来源。这个来源正在刷、或已经不在本机，返回 null，不发请求。
  /// 刷新本身的规矩在 [CatalogRefresher]：只改缓存和「地址仍跟随目录」的主机地址，
  /// 别名、用户名、端口、路线、指纹一概不碰。
  Future<CatalogRefreshOutcome?> refresh(String catalogId) async {
    final view = state.where((v) => v.catalogId == catalogId).firstOrNull;
    if (view == null || view.refreshing) return null;
    _mark(catalogId, true);
    try {
      return await _catalog.refreshSaved(catalogId);
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
  return controller;
});
