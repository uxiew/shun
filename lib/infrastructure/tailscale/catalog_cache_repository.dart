import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'catalog_cache.dart';

/// 目录缓存的本机存储：App 私有目录下每个来源一个 JSON 文件（R12）。
///
/// 没有凭据（凭据在独立安全存储，R11），所以用普通文件；整个私有目录已被 R09 的
/// dataExtractionRules 排除在云备份和换机迁移之外。不进保险库：保险库会导出、会同步，
/// 目录快照不属于任何一台主机，也不需要跟着走。
class CatalogCacheRepository {
  CatalogCacheRepository(this._directory);

  final Future<Directory> Function() _directory;

  static final _catalogId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  /// 超过就不读：一个来源的缓存不该比 API 响应上限（16 MiB）还大。
  static const _maxBytes = 16 * 1024 * 1024;

  Future<File> _file(String catalogId) async {
    if (!_catalogId.hasMatch(catalogId)) {
      throw ArgumentError('catalogId 无效');
    }
    return File('${(await _directory()).path}/$catalogId.json');
  }

  /// 没有或读不懂都返回 null。读不懂的文件改名为 `.corrupt` 留着，
  /// 不让下一次保存悄悄覆盖掉（也不据此删除任何主机）。
  Future<CatalogCache?> load(String catalogId) async {
    final file = await _file(catalogId);
    if (!await file.exists()) return null;
    CatalogCache? cache;
    try {
      if (await file.length() <= _maxBytes) {
        cache = CatalogCache.fromJson(jsonDecode(await file.readAsString()));
      }
    } on FormatException {
      cache = null;
    }
    if (cache == null || cache.catalogId != catalogId) {
      await file.rename('${file.path}.corrupt');
      return null;
    }
    return cache;
  }

  Future<List<CatalogCache>> loadAll() async {
    final dir = await _directory();
    if (!await dir.exists()) return const [];
    final out = <CatalogCache>[];
    await for (final entity in dir.list()) {
      final name = entity.uri.pathSegments.last;
      if (entity is! File || !name.endsWith('.json')) continue;
      final id = name.substring(0, name.length - '.json'.length);
      if (!_catalogId.hasMatch(id)) continue;
      final cache = await load(id);
      if (cache != null) out.add(cache);
    }
    return out;
  }

  /// 先写临时文件再改名：写到一半被杀，旧缓存还在，不会留下半个文件。
  Future<void> save(CatalogCache cache) async {
    final file = await _file(cache.catalogId);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(cache.toJson()), flush: true);
    await temp.rename(file.path);
  }

  /// 只删这个来源的缓存。主机、主机上的绑定、别的来源都不动。
  Future<void> delete(String catalogId) async {
    final file = await _file(catalogId);
    if (await file.exists()) await file.delete();
  }
}

final catalogCacheRepositoryProvider = Provider<CatalogCacheRepository>(
  (ref) => CatalogCacheRepository(() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/tailscale_catalog');
  }),
);
