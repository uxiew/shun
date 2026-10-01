import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/device_references.dart';
import 'tailscale_api.dart';

/// 目录凭据的存储后端。抽出来只为测试能换成内存实现并数写入次数。
abstract interface class CatalogSecretBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 和保险库分开的独立安全存储：Android 上是另一个加密偏好文件，iOS 上是另一个钥匙串账户。
///
/// 为什么要分开：保险库的导出、云同步、「删除全部凭据」都按保险库自己的键走；
/// 目录的控制面凭据不属于任何主机，放在一起迟早被某条导出或同步路径顺手带走（TSC09）。
/// 两边都已被 R09 的 dataExtractionRules 排除在云备份和换机迁移之外。
class FlutterSecureCatalogBackend implements CatalogSecretBackend {
  const FlutterSecureCatalogBackend();

  @visibleForTesting
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      sharedPreferencesName: 'xwshun_tailscale_catalog',
    ),
    iOptions: IOSOptions(
      accountName: 'xwshun.tailscale.catalog',
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

/// 用户显式开启「持续刷新」后，保存他自己的 OAuth client。只存这两项，不存 access token。
///
/// 从这里删除只是删掉本机副本，**不等于在 Tailscale 那边撤销**；泄露时要去 Tailscale 后台撤销原 client（docs/05）。
class TailscaleCatalogSecretStore {
  const TailscaleCatalogSecretStore(this._backend);

  final CatalogSecretBackend _backend;

  /// 每个来源一组键，键里只有来源 ID：刷新来源 A 只会读到 A 的 client（X05「只访问本来源控制面凭据」）。
  static String _key(String catalogId, String field) {
    if (!isValidCatalogId(catalogId)) {
      throw ArgumentError('catalogId 无效');
    }
    return 'tailscale.catalog.$catalogId.oauth.$field';
  }

  Future<void> saveOAuthClient(
    String catalogId,
    OAuthClientCredential client,
  ) async {
    await _backend.write(_key(catalogId, 'clientId'), client.clientId.trim());
    await _backend.write(
      _key(catalogId, 'clientSecret'),
      client.clientSecret.trim(),
    );
  }

  /// 两项都在才算有；只剩一项（写到一半被杀）当作没有，不拿半份凭据去试。
  Future<OAuthClientCredential?> readOAuthClient(String catalogId) async {
    final id = await _backend.read(_key(catalogId, 'clientId'));
    final secret = await _backend.read(_key(catalogId, 'clientSecret'));
    if (id == null || id.isEmpty || secret == null || secret.isEmpty) {
      return null;
    }
    return OAuthClientCredential(clientId: id, clientSecret: secret);
  }

  Future<void> forget(String catalogId) async {
    await _backend.delete(_key(catalogId, 'clientId'));
    await _backend.delete(_key(catalogId, 'clientSecret'));
  }
}
