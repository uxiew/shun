import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/device_references.dart';
import 'catalog_cache.dart';

/// 缓存文件由更新版本的 App 写入（schemaVersion 更高）。回滚到旧版时会遇到：
/// 旧版不认识它，但也不能把它当坏文件改名或覆盖——升级回去还要用（BAS03：迁移可回滚）。
class CatalogCacheTooNew implements Exception {
  const CatalogCacheTooNew(this.catalogId, this.version);
  final String catalogId;
  final int version;
  @override
  String toString() => '这个目录来源的缓存由更新版本的 App 写入（格式 $version），当前版本不读也不改它';
}

/// 目录缓存的本机存储：App 私有目录下每个来源一个 JSON 文件（R12）。
///
/// 没有凭据（凭据在独立安全存储，R11），所以用普通文件；整个私有目录已被 R09 的
/// dataExtractionRules 排除在云备份和换机迁移之外。不进保险库：保险库会导出、会同步，
/// 目录快照不属于任何一台主机，也不需要跟着走。
class CatalogCacheRepository {
  CatalogCacheRepository(this._directory);

  final Future<Directory> Function() _directory;

  /// 超过就不读：一个来源的缓存不该比 API 响应上限（16 MiB）还大。
  static const _maxBytes = 16 * 1024 * 1024;

  Future<File> _file(String catalogId) async {
    if (!isValidCatalogId(catalogId)) {
      throw ArgumentError('catalogId 无效');
    }
    return File('${(await _directory()).path}/$catalogId.json');
  }

  /// 没有或读不懂都返回 null。读不懂的文件改名为 `.corrupt` 留着，
  /// 不让下一次保存悄悄覆盖掉（也不据此删除任何主机）。
  /// 更新版本写的抛 [CatalogCacheTooNew]，文件不动：调用方据此拒绝刷新，免得旧版覆盖新格式。
  Future<CatalogCache?> load(String catalogId) async {
    final file = await _file(catalogId);
    if (!await file.exists()) return null;
    CatalogCache? cache;
    try {
      if (await file.length() <= _maxBytes) {
        final json = jsonDecode(await file.readAsString());
        final version = json is Map ? json['schemaVersion'] : null;
        if (version is int && version > CatalogCache.schemaVersion) {
          throw CatalogCacheTooNew(catalogId, version);
        }
        cache = CatalogCache.fromJson(json);
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
      if (!isValidCatalogId(id)) continue;
      try {
        final cache = await load(id);
        if (cache != null) out.add(cache);
      } on CatalogCacheTooNew {
        continue; // 新版写的来源：列表里不出现，文件原样留着。
      }
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
