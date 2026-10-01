import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../domain/models/host.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';
import '../../domain/vault_secrets.dart';
import 'background_image_service.dart';
import '../ai/ai_workspace.dart';

final vaultRepositoryProvider = Provider<VaultRepository>(
  (ref) => throw StateError('VaultRepository has not been initialized'),
);

enum VaultChangeOrigin { local, remote }

class VaultChange {
  const VaultChange(this.vault, this.origin);

  final VaultData vault;
  final VaultChangeOrigin origin;
}

/// 保险库凭据的安全存储。
const vaultSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    encryptedSharedPreferences: true,
    // 显式写出默认文件名，不能省。flutter_secure_storage 9.2.4 的 Android 端只在调用带了
    // 非空文件名时才切换文件、从不切回默认（FlutterSecureStorage.java ensureOptions）：
    // 同一次运行里先碰过 UU/RustDesk 或 Tailscale 目录那几份带名字的存储，之后保险库的密码就
    // 全写进了它们的文件，重启后保险库读自己的文件读不到，报「无法解密」（R14 模拟器上撞到）。
    // 'FlutterSecureStorage' 就是原来的默认文件名，已经存着的凭据照常读得到。
    sharedPreferencesName: 'FlutterSecureStorage',
  ),
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);

class VaultRepository {
  VaultRepository._(
    this._preferences,
    this._secureStorage,
    this._backgroundImageService,
  );

  static const _vaultKey = 'netcatty_mobile_vault_v1';
  static const _settingsKey = 'netcatty_mobile_settings_v1';
  static const _syncKey = 'netcatty_mobile_sync_v1';
  static const _syncVersionKey = 'netcatty_mobile_sync_version_v1';
  static const _syncReplicaKey = 'netcatty_mobile_pending_sync_v2';
  static const _masterPasswordKey = 'netcatty.mobile.sync.masterPassword';
  static const _aiApiKey = 'netcatty.mobile.ai.apiKey';
  static const _deviceIdKey = 'netcatty_mobile_device_id_v1';

  /// 哪些安全存储键存过非空凭据。只有键名（形如 `host.<id>.password`），没有值。
  static const _secretIndexKey = 'xwshun_secret_index_v1';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;
  final BackgroundImageService _backgroundImageService;
  final _changes = StreamController<VaultChange>.broadcast();
  late final aiWorkspace = AiWorkspace(
    read: (key) =>
        _secureStorage.read(key: 'netcatty.mobile.ai.workspace.$key'),
    write: (key, value) => value == null
        ? _secureStorage.delete(key: 'netcatty.mobile.ai.workspace.$key')
        : _secureStorage.write(
            key: 'netcatty.mobile.ai.workspace.$key', value: value),
  );
  VaultData? _cachedVault;
  Future<VaultData>? _vaultLoad;
  bool _vaultSecretsLoaded = false;

  static Future<VaultRepository> open({
    BackgroundImageService? backgroundImageService,
  }) async {
    final repository = VaultRepository._(
      await SharedPreferences.getInstance(),
      vaultSecureStorage,
      backgroundImageService ?? BackgroundImageService(),
    );
    repository.loadVaultPreview();
    return repository;
  }

  Stream<VaultData> get changes => _changes.stream.map((event) => event.vault);

  /// Emits only user-originated mutations. Cloud sync listens to this stream
  /// so applying a downloaded vault never schedules an upload loop.
  Stream<VaultData> get localChanges => _changes.stream
      .where((event) => event.origin == VaultChangeOrigin.local)
      .map((event) => event.vault);

  /// Returns the non-secret part of the vault directly from the in-memory
  /// preferences snapshot. This lets list-oriented screens render without
  /// waiting for platform keychain calls.
  VaultData? loadVaultPreview() {
    if (_cachedVault != null) return _cachedVault;
    try {
      return _cachedVault = _readStoredVault();
    } on Object {
      return null;
    }
  }

  Future<VaultData> loadVault() {
    if (_vaultSecretsLoaded && _cachedVault != null) {
      return Future.value(_cachedVault);
    }
    final active = _vaultLoad;
    if (active != null) return active;
    final operation = _loadVaultWithSecrets();
    _vaultLoad = operation;
    return operation.whenComplete(() {
      if (identical(_vaultLoad, operation)) _vaultLoad = null;
    });
  }

  VaultData _readStoredVault() {
    final raw = _preferences.getString(_vaultKey);
    if (raw == null) return VaultData.empty();
    return VaultData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<VaultData> _loadVaultWithSecrets() async {
    final vault = _cachedVault ?? _readStoredVault();
    _savedSecretKeys ??= _loadSecretIndex();
    final legacyInstall = _savedSecretKeys == null;
    final seen = <String>{};
    _onSecretRead = (key, value) {
      if (value != null && value.isNotEmpty) seen.add(key);
    };
    await Future.wait([
      ...vault.hosts.map(_loadHostSecrets),
      ...vault.keys.map(_loadKeySecrets),
      ...vault.proxyProfiles.map(_loadProxySecrets),
    ]);
    _onSecretRead = null;
    if (legacyInstall) {
      // 升级前的安装没有清单：按这次实际读到的补上，从此能认出「存过却读成空」。
      _savedSecretKeys = seen;
      await _persistSecretIndex();
    }
    // A metadata-only edit (for example a snippet mutation) may complete while
    // platform keychain reads are still in flight. Keep that newer snapshot;
    // its host/key objects already received the hydrated secrets above.
    final latest = _cachedVault;
    final result = latest != null && !identical(latest, vault) ? latest : vault;
    _cachedVault = result;
    _vaultSecretsLoaded = true;
    return result;
  }

  /// 读不出来（解密失败）的凭据在安全存储里的键。
  ///
  /// 设备密钥失效（系统恢复、锁屏被重置）或密文被改动时，这些条目解不开。以前任何一条解不开，
  /// 整个保险库都加载失败：所有主机都连不上也改不了，界面上没有任何提示（SEC06 模拟器实测）。
  /// 现在逐条读，解不开的记在这里、当作没有，其余照常；用到它们的连接在拨号前拒绝并说明原因。
  final _unreadableSecrets = <String>{};

  Set<String> get unreadableSecrets => Set.unmodifiable(_unreadableSecrets);

  /// 存过凭据的键。为什么要单独记：Keystore 主密钥失效时，flutter_secure_storage 9.2.4 初始化
  /// 加密存储失败后不报错，而是悄悄换成它的旧版加密方式重新开一份——以前存的凭据全部读成空、不抛异常。
  /// 模拟器上改坏密钥集实测就是这样：没有任何提示，连接时当成「没存密码」去试。
  /// 有了这份清单，「清单里有、却读出空」就能认出来，和抛异常一样算解不开。
  /// null 表示旧安装还没有清单（升级后第一次加载时按实际读到的补上）。
  Set<String>? _savedSecretKeys;
  void Function(String key, String? value)? _onSecretRead;

  Set<String>? _loadSecretIndex() {
    return _preferences.getStringList(_secretIndexKey)?.toSet();
  }

  Future<void> _persistSecretIndex() async {
    final keys = _savedSecretKeys;
    if (keys == null) return;
    await _preferences.setStringList(_secretIndexKey, keys.toList()..sort());
  }

  Future<String?> _readSecret(String key) async {
    try {
      final value = await _secureStorage.read(key: key);
      if ((value == null || value.isEmpty) &&
          (_savedSecretKeys?.contains(key) ?? false)) {
        _unreadableSecrets.add(key);
        return null;
      }
      _unreadableSecrets.remove(key);
      _onSecretRead?.call(key, value);
      return value;
    } on Object {
      // 不带原始异常：平台异常的文本里有解密细节，没有必要进日志。
      _unreadableSecrets.add(key);
      return null;
    }
  }

  Future<void> _loadHostSecrets(HostProfile host) async {
    final values = await Future.wait([
      _readSecret('host.${host.id}.password'),
      _readSecret('host.${host.id}.telnetPassword'),
      _readSecret('host.${host.id}.proxyPassword'),
    ]);
    final password = values[0];
    final telnet = values[1];
    final proxyPassword = values[2];
    if (password != null) host.data['password'] = password;
    if (telnet != null) host.data['telnetPassword'] = telnet;
    if (proxyPassword != null && host.data['proxyConfig'] is Map) {
      host.data['proxyConfig'] = {
        ...Map<String, dynamic>.from(host.data['proxyConfig'] as Map),
        'password': proxyPassword,
      };
    }
  }

  Future<void> _loadKeySecrets(SshKeyProfile key) async {
    final values = await Future.wait([
      _readSecret('key.${key.id}.private'),
      _readSecret('key.${key.id}.passphrase'),
    ]);
    final privateKey = values[0];
    final passphrase = values[1];
    if (privateKey != null) key.data['privateKey'] = privateKey;
    if (passphrase != null) key.data['passphrase'] = passphrase;
  }

  Future<void> _loadProxySecrets(ProxyProfile profile) async {
    final password = await _readSecret('proxy.${profile.id}.password');
    if (password != null && profile.data['config'] is Map) {
      profile.data['config'] = {
        ...Map<String, dynamic>.from(profile.data['config'] as Map),
        'password': password,
      };
    }
  }

  Future<void> saveVault(VaultData vault, {bool remote = false}) async {
    final activeLoad = _vaultLoad;
    if (activeLoad != null) await activeLoad;
    final previousRaw = _preferences.getString(_vaultKey);
    if (previousRaw != null) {
      final previous = VaultData.fromJson(
        jsonDecode(previousRaw) as Map<String, dynamic>,
      );
      final hostIds = vault.hosts.map((value) => value.id).toSet();
      final keyIds = vault.keys.map((value) => value.id).toSet();
      final proxyIds = vault.proxyProfiles.map((value) => value.id).toSet();
      for (final host in previous.hosts.where(
        (value) => !hostIds.contains(value.id),
      )) {
        await _deleteSecret('host.${host.id}.password');
        await _deleteSecret('host.${host.id}.telnetPassword');
        await _deleteSecret('host.${host.id}.proxyPassword');
      }
      for (final proxy in previous.proxyProfiles.where(
        (value) => !proxyIds.contains(value.id),
      )) {
        await _deleteSecret('proxy.${proxy.id}.password');
      }
      for (final key in previous.keys.where(
        (value) => !keyIds.contains(value.id),
      )) {
        await _deleteSecret('key.${key.id}.private');
        await _deleteSecret('key.${key.id}.passphrase');
      }
    }
    for (final host in vault.hosts) {
      await _writeSecret('host.${host.id}.password', host.password);
      await _writeSecret(
        'host.${host.id}.telnetPassword',
        host.data['telnetPassword']?.toString(),
      );
      final proxy = host.proxyConfig;
      await _writeSecret('host.${host.id}.proxyPassword', proxy?.password);
    }
    for (final key in vault.keys) {
      await _writeSecret('key.${key.id}.private', key.privateKey);
      await _writeSecret('key.${key.id}.passphrase', key.passphrase);
    }
    for (final profile in vault.proxyProfiles) {
      final config = profile.config;
      await _writeSecret('proxy.${profile.id}.password', config?.password);
    }
    await _persistSecretIndex();
    final sanitized = vaultWithoutSecrets(vault);
    await _preferences.setString(_vaultKey, jsonEncode(sanitized.toJson()));
    _cachedVault = vault;
    _vaultSecretsLoaded = true;
    _changes.add(VaultChange(
      vault,
      remote ? VaultChangeOrigin.remote : VaultChangeOrigin.local,
    ));
  }

  /// Persists fields that never contain credentials without touching the
  /// platform keychain. This is intentionally limited to controller paths that
  /// only change snippets or other known non-secret metadata.
  Future<void> saveVaultMetadata(VaultData vault) async {
    final previousCache = _cachedVault;
    _cachedVault = vault;
    try {
      final sanitized = vaultWithoutSecrets(vault);
      await _preferences.setString(_vaultKey, jsonEncode(sanitized.toJson()));
      _changes.add(VaultChange(vault, VaultChangeOrigin.local));
    } on Object {
      if (identical(_cachedVault, vault)) _cachedVault = previousCache;
      rethrow;
    }
  }

  Future<AppSettings> loadSettings() async {
    final raw = _preferences.getString(_settingsKey);
    if (raw == null) return const AppSettings();
    final settings = AppSettings.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    String resolvedPath;
    try {
      resolvedPath = await _backgroundImageService.resolveStoredPath(
        settings.customBackgroundPath,
      );
    } on Object {
      return settings;
    }
    final resolved = resolvedPath == settings.customBackgroundPath
        ? settings
        : settings.copyWith(customBackgroundPath: resolvedPath);
    var portablePath = settings.customBackgroundPath;
    if (!portablePath.startsWith(BackgroundImageService.managedPathPrefix)) {
      try {
        portablePath = await _backgroundImageService.toStoredPath(resolvedPath);
      } on Object {
        return resolved;
      }
    }
    if (portablePath != settings.customBackgroundPath) {
      await _preferences.setString(
        _settingsKey,
        jsonEncode(
          resolved.copyWith(customBackgroundPath: portablePath).toJson(),
        ),
      );
    }
    return resolved;
  }

  Future<void> saveSettings(AppSettings settings) async {
    var portablePath = settings.customBackgroundPath;
    try {
      portablePath = await _backgroundImageService.toStoredPath(portablePath);
    } on Object {
      // Keep settings writable if the platform storage API is unavailable.
    }
    final persisted = settings.copyWith(customBackgroundPath: portablePath);
    await _preferences.setString(_settingsKey, jsonEncode(persisted.toJson()));
  }

  Future<SyncConnection?> loadSyncConnection() async {
    final raw = _preferences.getString(_syncKey);
    if (raw == null) return null;
    final connection = SyncConnection.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    final secret = await _secureStorage.read(key: 'sync.provider.secret');
    final sessionToken =
        await _secureStorage.read(key: 'sync.provider.sessionToken');
    return connection.copyWith(secret: secret, sessionToken: sessionToken);
  }

  Future<void> saveSyncConnection(SyncConnection connection) async {
    await _preferences.setString(_syncKey, jsonEncode(connection.toJson()));
    await _writeSecret('sync.provider.secret', connection.secret);
    await _writeSecret(
      'sync.provider.sessionToken',
      connection.sessionToken,
    );
  }

  Future<SyncVersionCheckpoint?> loadSyncVersionCheckpoint() async {
    final raw = _preferences.getString(_syncVersionKey);
    if (raw == null) return null;
    try {
      final checkpoint = SyncVersionCheckpoint.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return checkpoint.target.isEmpty ||
              checkpoint.version < 0 ||
              checkpoint.vaultFingerprint.isEmpty
          ? null
          : checkpoint;
    } on Object {
      return null;
    }
  }

  Future<void> saveSyncVersionCheckpoint(
    SyncVersionCheckpoint checkpoint,
  ) =>
      _preferences.setString(
        _syncVersionKey,
        jsonEncode(checkpoint.toJson()),
      );

  Future<void> clearSyncVersionCheckpoint() =>
      _preferences.remove(_syncVersionKey);

  // Contains only an encrypted replica/baseline bundle, never plaintext secrets.
  Future<Map<String, dynamic>?> loadPendingSyncReplica() async {
    final raw = _preferences.getString(_syncReplicaKey);
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<void> savePendingSyncReplica(Map<String, dynamic> value) =>
      _preferences.setString(_syncReplicaKey, jsonEncode(value));

  Future<void> clearPendingSyncReplica() =>
      _preferences.remove(_syncReplicaKey);

  Future<String?> readMasterPassword() =>
      _secureStorage.read(key: _masterPasswordKey);
  Future<void> saveMasterPassword(String? value) =>
      _writeSecret(_masterPasswordKey, value);
  Future<String?> readAiApiKey() => _secureStorage.read(key: _aiApiKey);
  Future<void> saveAiApiKey(String? value) => _writeSecret(_aiApiKey, value);

  Future<String> readOrCreateDeviceId() async {
    final existing = _preferences.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = const Uuid().v4();
    await _preferences.setString(_deviceIdKey, created);
    return created;
  }

  /// 整台主机、私钥或代理配置被删除时用：连同解不开的那条一起删。
  Future<void> _deleteSecret(String key) async {
    await _secureStorage.delete(key: key);
    _unreadableSecrets.remove(key);
    _savedSecretKeys?.remove(key);
  }

  Future<void> _writeSecret(String key, String? value) async {
    if (value == null || value.isEmpty) {
      // 解不开的那条，用户没重新填就别删：可能只是暂时解不开，删了就真没了。
      // 整台主机、整把私钥被删除时，上面按 id 清理的循环会删掉它。
      if (_unreadableSecrets.contains(key)) return;
      await _secureStorage.delete(key: key);
      _savedSecretKeys?.remove(key);
    } else {
      await _secureStorage.write(key: key, value: value);
      _unreadableSecrets.remove(key);
      (_savedSecretKeys ??= <String>{}).add(key);
    }
  }
}
