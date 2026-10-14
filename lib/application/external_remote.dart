import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:plugin_api/plugin_api.dart';

import '../domain/models/host.dart';
import 'tailscale_catalog_refresh.dart';

// 外部远控 App 的适配器（UU 远程 X06、RustDesk X07）共用的部分。
// 远控在外部 App 里进行，这边只看得到主机的 id、名字和 SSH 路线，各自的绑定存在各自的加密存储里。

/// 外部远控这边看得到的一台主机：id、名字、SSH 走什么路线。没有密码、私钥、代理口令——外部 App 用不着。
class RemoteControlHost {
  const RemoteControlHost({
    required this.id,
    required this.label,
    required this.sshRoute,
    this.catalogId,
    this.deviceId,
  });

  factory RemoteControlHost.of(HostProfile host) => RemoteControlHost(
        id: host.id,
        label: host.label,
        sshRoute: sshRouteOf(host),
        catalogId: CatalogBinding.of(host)?.catalogId,
        deviceId: CatalogBinding.of(host)?.deviceId,
      );

  final String id;
  final String label;
  final RequestedRoute sshRoute;
  final String? catalogId;
  final String? deviceId;
}

/// 主机的 SSH 路线归成插件契约里的几种。HTTP 代理也归到「经代理」：这里只关心是不是直连。
/// 格式不对的跳板配置算「经跳板」：宁可多问用户一句。
RequestedRoute sshRouteOf(HostProfile host) {
  final proxy = host.proxyProfileId?.isNotEmpty == true ||
      host.data['proxyConfig'] != null;
  final chain = host.data['hostChain'];
  final ids = chain is Map ? chain['hostIds'] : null;
  final jump = chain != null &&
      (chain is! Map || ids != null && (ids is! List || ids.isNotEmpty));
  return switch ((proxy, jump)) {
    (true, true) => RequestedRoute.socks5ProxyJump,
    (true, false) => RequestedRoute.socks5Connect,
    (false, true) => RequestedRoute.proxyJump,
    (false, false) => RequestedRoute.systemDefault,
  };
}

/// provider 自己的加密存储后端。抽出来只为测试能换成内存实现。
abstract interface class ProviderSecretBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 每个 provider 一份独立的加密存储，和保险库、别的 provider 都分开。
/// 已被 R09 的 dataExtractionRules 排除在云备份和换机迁移之外。
///
/// [prefsName]（Android 的加密偏好文件名）和 [keychainAccount]（iOS 钥匙串账户名）定了就不能改：
/// 改了等于换一份空存储，原来的绑定全部读不到。
class SecureProviderBackend implements ProviderSecretBackend {
  SecureProviderBackend({
    required String prefsName,
    required String keychainAccount,
  }) : _storage = FlutterSecureStorage(
          aOptions: AndroidOptions(
            encryptedSharedPreferences: true,
            sharedPreferencesName: prefsName,
          ),
          iOptions: IOSOptions(
            accountName: keychainAccount,
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
        );

  final FlutterSecureStorage _storage;

  /// 测试核对它用的文件名（见 test/secure_storage_file_names_test.dart）。
  @visibleForTesting
  FlutterSecureStorage get storage => _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
