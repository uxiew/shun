import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/auto_sync_controller.dart';
import '../../application/fork_features.dart';
import '../../application/settings_controller.dart';
import '../../application/vault_controller.dart';
import '../../application/vault_import.dart';
import '../../domain/models/settings.dart';
import '../../infrastructure/http_client_provider.dart';
import '../../infrastructure/storage/encrypted_vault_file.dart';
import '../../infrastructure/storage/vault_repository.dart';
import '../../infrastructure/sync/cloud_sync_service.dart';
import '../../infrastructure/sync/github_auth_service.dart';
import '../../infrastructure/sync/sync_safety.dart';
import '../localization/localized_widgets.dart';
import '../widgets/form_gap.dart';
import '../widgets/github_manual_config.dart';
import '../widgets/hint.dart';
import '../widgets/secret_content.dart';
import '../widgets/vault_import_dialog.dart';

/// 云端备份（R61，所有者 10-31 从设置页搬出来）：填 WebDAV 或 S3，备份、恢复都在这页。
///
/// 没填好就不外连。代码里叫 sync 是因为底下还是那套合并逻辑：备份时先和云端那份合并再传，
/// 恢复是另一条路，只读云端那份，走和文件恢复同一个确认框，不写云端。
class CloudBackupScreen extends ConsumerStatefulWidget {
  const CloudBackupScreen({super.key});

  @override
  ConsumerState<CloudBackupScreen> createState() => _CloudBackupScreenState();
}

class _CloudBackupScreenState extends ConsumerState<CloudBackupScreen> {
  final endpoint = TextEditingController();
  final username = TextEditingController();
  final providerSecret = TextEditingController();
  final resourceId = TextEditingController();
  final s3Region = TextEditingController(text: 'us-east-1');
  final s3Bucket = TextEditingController();
  final s3AccessKeyId = TextEditingController();
  final s3SessionToken = TextEditingController();
  final s3Prefix = TextEditingController();
  final masterPassword = TextEditingController();
  var provider = SyncProviderType.webdav;
  var s3ForcePathStyle = true;
  var s3AllowInsecure = false;
  var autoSyncEnabled = false;
  var _savingAutoSync = false;
  var _busy = false;
  var _checkingSyncVersions = false;
  var _loaded = false;
  var _leaving = false;
  List<Object?> _savedForm = const [];
  String? _githubUser;
  CloudSyncVersions? _syncVersions;
  Object? _syncVersionsError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    endpoint.dispose();
    username.dispose();
    providerSecret.dispose();
    resourceId.dispose();
    s3Region.dispose();
    s3Bucket.dispose();
    s3AccessKeyId.dispose();
    s3SessionToken.dispose();
    s3Prefix.dispose();
    masterPassword.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repository = ref.read(vaultRepositoryProvider);
    final sync = await repository.loadSyncConnection();
    final settings = await repository.loadSettings();
    final password = await repository.readMasterPassword() ?? '';
    if (!mounted) return;
    final features = ref.read(forkFeaturesProvider);
    final github = sync?.type == SyncProviderType.githubGist;
    setState(() {
      endpoint.text = sync?.endpoint ?? '';
      username.text = sync?.username ?? '';
      providerSecret.text = sync?.secret ?? '';
      resourceId.text = sync?.resourceId ?? '';
      s3Region.text =
          sync?.region?.isNotEmpty == true ? sync!.region! : 'us-east-1';
      s3Bucket.text = sync?.bucket ?? '';
      s3AccessKeyId.text = sync?.accessKeyId ?? '';
      s3SessionToken.text = sync?.sessionToken ?? '';
      s3Prefix.text = sync?.prefix ?? '';
      s3ForcePathStyle = sync?.forcePathStyle ?? true;
      s3AllowInsecure = sync?.allowInsecure ?? false;
      masterPassword.text = password;
      autoSyncEnabled = settings.autoSyncEnabled;
      _githubUser = github ? sync?.username : null;
      // 存着 GitHub 配置但这个版本没有那一项：选中一个不存在的分段会触发断言。
      provider = github && !features.githubSync
          ? SyncProviderType.webdav
          : sync?.type ?? SyncProviderType.webdav;
      _savedForm = _formValues();
      _loaded = true;
    });
    if (((github && features.githubSync) ||
            sync?.type == SyncProviderType.s3) &&
        sync?.secret?.isNotEmpty == true &&
        password.isNotEmpty) {
      unawaited(_refreshSyncVersions());
    }
  }

  @override
  Widget build(BuildContext context) {
    final autoSyncState = ref.watch(autoSyncControllerProvider);
    final features = ref.watch(forkFeaturesProvider);
    final status = _autoSyncStatus(autoSyncState);
    // 整页防截屏（R44）：有 WebDAV/S3/GitHub 的口令和主密码。
    return SecretContent(
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_leave());
        },
        child: Scaffold(
          appBar: AppBar(
            title: const LText('云端备份'),
            actions: const [
              HintButton(
                title: '云端备份',
                message: '填好才会外连。密码和私钥加密后才传上去，靠主密码保护，忘了就解不开。备份时会先和云端那份合并。',
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<SyncProviderType>(
                expandedInsets: EdgeInsets.zero,
                segments: [
                  const ButtonSegment(
                    value: SyncProviderType.webdav,
                    label: _AdaptiveSyncProviderLabel('WebDAV'),
                    icon: Icon(Icons.cloud_outlined),
                  ),
                  if (features.githubSync)
                    const ButtonSegment(
                      value: SyncProviderType.githubGist,
                      label: _AdaptiveSyncProviderLabel('GitHub'),
                      icon: Icon(Icons.code),
                    ),
                  const ButtonSegment(
                    value: SyncProviderType.s3,
                    label: _AdaptiveSyncProviderLabel('S3'),
                    icon: Icon(Icons.storage_outlined),
                  ),
                ],
                selected: {provider},
                onSelectionChanged: (value) => setState(() {
                  provider = value.first;
                  _syncVersions = null;
                  _syncVersionsError = null;
                }),
              ),
              const SizedBox(height: 14),
              if (provider == SyncProviderType.webdav) ...[
                TextField(
                  controller: endpoint,
                  keyboardType: TextInputType.url,
                  decoration: LInputDecoration(
                    labelText: 'WebDAV 地址',
                    hintText: 'https://dav.example.com/shun',
                  ),
                ),
                const FormGap(),
                TextField(
                  controller: username,
                  decoration: LInputDecoration(labelText: '用户名'),
                ),
                const FormGap(),
                TextField(
                  controller: providerSecret,
                  obscureText: true,
                  enableIMEPersonalizedLearning: false,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: LInputDecoration(labelText: '密码 / 应用密码'),
                ),
              ] else if (provider == SyncProviderType.s3) ...[
                TextField(
                  controller: endpoint,
                  keyboardType: TextInputType.url,
                  decoration: LInputDecoration(
                    labelText: 'S3 Endpoint',
                    hintText: 'https://s3.example.com',
                  ),
                ),
                const FormGap(),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: s3Region,
                        decoration: LInputDecoration(
                          labelText: 'Region',
                          hintText: 'us-east-1',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: s3Bucket,
                        decoration: LInputDecoration(
                          labelText: 'Bucket',
                        ),
                      ),
                    ),
                  ],
                ),
                const FormGap(),
                TextField(
                  controller: s3AccessKeyId,
                  decoration: LInputDecoration(
                    labelText: 'Access Key ID',
                  ),
                ),
                const FormGap(),
                TextField(
                  controller: providerSecret,
                  obscureText: true,
                  enableIMEPersonalizedLearning: false,
                  enableSuggestions: false,
                  autocorrect: false,
                  onChanged: (_) => setState(() {}),
                  decoration: LInputDecoration(
                    labelText: 'Secret Access Key',
                  ),
                ),
                const FormGap(),
                TextField(
                  controller: s3SessionToken,
                  obscureText: true,
                  enableIMEPersonalizedLearning: false,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: LInputDecoration(
                    labelText: 'Session Token（可选）',
                  ),
                ),
                const FormGap(),
                TextField(
                  controller: s3Prefix,
                  decoration: LInputDecoration(
                    labelText: '对象前缀（可选）',
                    hintText: 'shun',
                  ),
                ),
                HintSwitchTile(
                  contentPadding: EdgeInsets.zero,
                  title: '使用路径式访问',
                  hint: 'MinIO 这类自建 S3 要开着。默认开。',
                  value: s3ForcePathStyle,
                  onChanged: (value) =>
                      setState(() => s3ForcePathStyle = value),
                ),
                HintSwitchTile(
                  contentPadding: EdgeInsets.zero,
                  title: '允许不安全连接',
                  hint: '只给 HTTP 或自签名 HTTPS 的服务用。开着时任何证书都接受，被中间人截走也发现不了。',
                  value: s3AllowInsecure,
                  onChanged: (value) => setState(() => s3AllowInsecure = value),
                ),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _testS3Connection,
                    icon: const Icon(Icons.wifi_tethering_outlined),
                    label: const LText('测试 S3 连接'),
                  ),
                ),
                const SizedBox(height: 10),
                _syncVersionsCard(),
              ] else ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    child: Icon(
                      providerSecret.text.isEmpty ? Icons.login : Icons.check,
                    ),
                  ),
                  title: LText(
                    providerSecret.text.isEmpty ? '尚未登录 GitHub' : '已连接 GitHub',
                  ),
                  subtitle: LText(
                    _githubUser == null
                        ? '登录后自动查找或创建 Gist'
                        : '@$_githubUser · 自动同步私有 Gist',
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: providerSecret.text.isEmpty
                      ? FilledButton.icon(
                          onPressed: _busy ? null : _connectGitHub,
                          icon: const Icon(Icons.login),
                          label: const LText('登录 GitHub'),
                        )
                      : OutlinedButton.icon(
                          onPressed: _busy ? null : _logoutGitHub,
                          icon: const Icon(Icons.logout),
                          label: const LText('退出 GitHub'),
                        ),
                ),
                const SizedBox(height: 10),
                _syncVersionsCard(),
                GitHubManualConfig(
                    resourceId: resourceId,
                    secret: providerSecret,
                    onSecretChanged: (_) => setState(() {})),
              ],
              const FormGap(),
              TextField(
                controller: masterPassword,
                obscureText: true,
                enableIMEPersonalizedLearning: false,
                enableSuggestions: false,
                autocorrect: false,
                decoration: LInputDecoration(
                  labelText: '主密码',
                ),
              ),
              const SizedBox(height: 6),
              HintSwitchTile(
                key: const ValueKey('cloud-auto-sync'),
                contentPadding: EdgeInsets.zero,
                secondary: autoSyncState.syncing
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Icon(Icons.sync_outlined),
                title: '自动备份',
                hint: '数据变了约 10 秒后备份，启动、回到前台和每 5 分钟也查一次云端。',
                subtitle: status,
                value: autoSyncEnabled,
                onChanged: _busy || _savingAutoSync ? null : _setAutoSync,
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const ValueKey('cloud-sync-now'),
                onPressed: _busy ? null : _sync,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const LText('立即备份'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('cloud-restore'),
                onPressed: _busy ? null : _restore,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const LText('从云端恢复'),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Object?> _formValues() => [
        provider,
        endpoint.text,
        username.text,
        providerSecret.text,
        resourceId.text,
        s3Region.text,
        s3Bucket.text,
        s3AccessKeyId.text,
        s3SessionToken.text,
        s3Prefix.text,
        s3ForcePathStyle,
        s3AllowInsecure,
        masterPassword.text,
      ];

  /// 先存完再关页面，设置页回来时读到的才是新的。连按两次返回只算一次，不然会把首页也关掉。
  /// 还没读完配置不存：不然打开马上返回，会拿空表单把配置盖掉。
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    try {
      if (_loaded && !listEquals(_formValues(), _savedForm)) await _saveEdits();
    } on Object catch (error) {
      _message('$error');
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// 这页一关输入框就没了：填了没点按钮也存下来，不然返回一次就白填。
  ///
  /// 存着一份配置时，只是切到另一个分段再返回不算要换：两边共用地址和密码框，存了的话
  /// 原来的用户名、bucket 就没了，开着自动备份时还会连错地方。要换就点按钮。
  /// 主密码不到 12 位不存：开着自动备份时，存了下一轮就拿它加密上传。
  Future<void> _saveEdits() async {
    final hadConfig = _savedForm[1] != '' || _savedForm[3] != '';
    if (hadConfig && _savedForm.first != provider) {
      _message('存储方式没换，点「立即备份」才算');
      return;
    }
    final password = masterPassword.text;
    final savePassword = password.isEmpty ||
        password.length >= EncryptedVaultFile.minPassphraseLength;
    await _saveSync(savePassword: savePassword);
    if (!savePassword) _message('主密码不到 12 位，没有保存');
  }

  Future<void> _saveSync({bool savePassword = true}) async {
    final connection = SyncConnection(
      type: provider,
      endpoint: endpoint.text.trim(),
      // GitHub 用户名仅用于展示，不参与 API 认证。
      username: provider == SyncProviderType.githubGist
          ? _githubUser
          : provider == SyncProviderType.webdav
              ? username.text.trim()
              : null,
      secret: providerSecret.text,
      resourceId: provider == SyncProviderType.githubGist
          ? resourceId.text.trim()
          : null,
      region: provider == SyncProviderType.s3 ? s3Region.text.trim() : null,
      bucket: provider == SyncProviderType.s3 ? s3Bucket.text.trim() : null,
      accessKeyId:
          provider == SyncProviderType.s3 ? s3AccessKeyId.text.trim() : null,
      sessionToken:
          provider == SyncProviderType.s3 ? s3SessionToken.text.trim() : null,
      prefix: provider == SyncProviderType.s3 ? s3Prefix.text.trim() : null,
      forcePathStyle: s3ForcePathStyle,
      allowInsecure: s3AllowInsecure,
    );
    final repository = ref.read(vaultRepositoryProvider);
    await repository.saveSyncConnection(connection);
    if (savePassword) await repository.saveMasterPassword(masterPassword.text);
    _savedForm = _formValues();
  }

  /// 只写状态：做什么、什么时候做写在 ⓘ 里。关着和没备份过就不写。
  String? _autoSyncStatus(AutoSyncState syncState) {
    if (!syncState.enabled) return null;
    if (syncState.syncing) return '正在备份…';
    if (syncState.lastError != null) {
      if (ShunLocalizations.isEnglish) {
        return 'Last backup failed, will retry: ${syncState.lastError}';
      }
      return '上次失败，会自动重试：${syncState.lastError}';
    }
    final syncedAt = syncState.lastSyncedAt;
    if (syncedAt == null) return null;
    final local = syncedAt.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    if (ShunLocalizations.isEnglish) return 'Last backup $hour:$minute';
    return '最近备份 $hour:$minute';
  }

  /// 云端那份文件泄露后能被离线猜口令，和加密备份一个道理。没到 12 位就不往外传。
  bool _masterPasswordStrongEnough() {
    if (masterPassword.text.length >= EncryptedVaultFile.minPassphraseLength) {
      return true;
    }
    _message('主密码至少 12 位');
    return false;
  }

  Future<void> _setAutoSync(bool enabled) async {
    if (enabled && !_masterPasswordStrongEnough()) return;
    setState(() => _savingAutoSync = true);
    try {
      if (enabled) await _saveSync();
      final repository = ref.read(vaultRepositoryProvider);
      final current = await repository.loadSettings();
      await ref.read(settingsControllerProvider.notifier).update(
            current.copyWith(autoSyncEnabled: enabled),
          );
      if (mounted) setState(() => autoSyncEnabled = enabled);
      _message(enabled ? '自动备份已开启' : '自动备份已关闭');
    } on Object catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _savingAutoSync = false);
    }
  }

  Future<void> _refreshSyncVersions({
    bool saveConfiguration = false,
  }) async {
    if ((provider != SyncProviderType.githubGist &&
            provider != SyncProviderType.s3) ||
        providerSecret.text.isEmpty) {
      return;
    }
    if (mounted) {
      setState(() {
        _checkingSyncVersions = true;
        _syncVersionsError = null;
      });
    }
    try {
      if (saveConfiguration) await _saveSync();
      final repository = ref.read(vaultRepositoryProvider);
      final service = CloudSyncService(
        repository,
        client: ref.read(httpClientProvider),
      );
      final vault = await ref.read(vaultControllerProvider.notifier).ready();
      final versions = await service.inspectVersions(vault);
      final updatedConnection = await repository.loadSyncConnection();
      if (mounted) {
        setState(() {
          _syncVersions = versions;
          resourceId.text = updatedConnection?.resourceId ?? resourceId.text;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _syncVersionsError = error);
    } finally {
      if (mounted) setState(() => _checkingSyncVersions = false);
    }
  }

  Future<void> _testS3Connection() async {
    setState(() => _busy = true);
    try {
      await _saveSync();
      final repository = ref.read(vaultRepositoryProvider);
      final connection = await repository.loadSyncConnection();
      if (connection == null) throw StateError('S3 配置未保存');
      final service = CloudSyncService(
        repository,
        client: ref.read(httpClientProvider),
      );
      await service.testS3Connection(connection);
      _message('S3 连接成功');
      await _refreshSyncVersions();
    } catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectGitHub() async {
    setState(() => _busy = true);
    try {
      final auth = GitHubAuthService(client: ref.read(httpClientProvider));
      final authorization = await auth.start();
      if (!mounted) return;
      final token = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _GitHubDeviceFlowDialog(
          authorization: authorization,
          auth: auth,
        ),
      );
      if (token == null || !mounted) return;
      providerSecret.text = token;
      resourceId.clear();
      await _saveSync();
      try {
        final user = await auth.currentUser(token);
        _githubUser = user['login']?.toString();
      } on GitHubAuthNetworkException {
        _githubUser = null;
      }
      await _saveSync();
      if (mounted) setState(() {});
      await _refreshSyncVersions();
      _message('GitHub 登录成功，将自动查找 Gist');
    } catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logoutGitHub() async {
    providerSecret.clear();
    resourceId.clear();
    _githubUser = null;
    await _saveSync();
    if (mounted) {
      setState(() {
        _syncVersions = null;
        _syncVersionsError = null;
      });
    }
    _message('已退出 GitHub');
  }

  Future<void> _sync({bool confirmShrink = false}) async {
    if (!_masterPasswordStrongEnough()) return;
    setState(() => _busy = true);
    try {
      await _saveSync();
      final result = await ref
          .read(autoSyncControllerProvider.notifier)
          .synchronizeNow(confirmShrink: confirmShrink);
      _syncVersions = result.versions;
      final updatedConnection =
          await ref.read(vaultRepositoryProvider).loadSyncConnection();
      resourceId.text = updatedConnection?.resourceId ?? resourceId.text;
      if (mounted) setState(() {});
      _message(result.message);
    } on SyncShrinkException catch (error) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认大量删除'),
          content: Text('$error\n\n仅当你确认这些删除是本人操作时才继续。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认删除并备份')),
          ],
        ),
      );
      if (confirmed == true && mounted) await _sync(confirmShrink: true);
    } catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _syncVersionsCard() {
    final colors = Theme.of(context).colorScheme;
    final versions = _syncVersions;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _syncVersionMetric(
                  icon: Icons.smartphone_outlined,
                  label: '本地版本',
                  version: versions?.localVersion,
                  pending: versions?.hasLocalChanges == true,
                ),
              ),
              Container(
                width: 1,
                height: 42,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                color: colors.outlineVariant,
              ),
              Expanded(
                child: _syncVersionMetric(
                  icon: Icons.cloud_outlined,
                  label: '云端版本',
                  version: versions?.cloudVersion,
                ),
              ),
              IconButton(
                tooltip: localized('刷新版本'),
                onPressed: _busy ||
                        _checkingSyncVersions ||
                        providerSecret.text.isEmpty
                    ? null
                    : () => _refreshSyncVersions(saveConfiguration: true),
                icon: _checkingSyncVersions
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LText(
            _syncVersionStatus(),
            style: TextStyle(
              color: _syncVersionsError == null
                  ? colors.onSurfaceVariant
                  : colors.error,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _syncVersionMetric({
    required IconData icon,
    required String label,
    required int? version,
    bool pending = false,
  }) =>
      Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LText(label, style: const TextStyle(fontSize: 12)),
                Row(
                  children: [
                    Text(
                      version == null ? '—' : 'v$version',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (pending) ...[
                      const SizedBox(width: 5),
                      const LText('待备份', style: TextStyle(fontSize: 11)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      );

  String _syncVersionStatus() {
    if (providerSecret.text.isEmpty) {
      return provider == SyncProviderType.s3
          ? '填写 S3 凭据后查看版本'
          : '登录 GitHub 后查看版本';
    }
    if (_checkingSyncVersions) return '正在读取本地与云端版本…';
    if (_syncVersionsError != null) {
      return '版本信息读取失败：$_syncVersionsError';
    }
    final versions = _syncVersions;
    if (versions == null) return '点按刷新确认版本';
    final base = versions.baseVersion;
    if (base == null) {
      if (versions.cloudVersion > 0 && versions.hasLocalChanges) {
        return '本地与云端尚无共同版本，请立即备份';
      }
      if (versions.cloudVersion > 0) return '云端已有版本，建议立即备份';
      if (versions.hasLocalChanges) return '本地数据等待备份';
      return '尚未备份过';
    }
    final cloudChanged = versions.cloudVersion != base;
    if (cloudChanged && versions.hasLocalChanges) {
      return '本地和云端均有更新，请立即备份';
    }
    if (versions.hasLocalChanges) return '本地有待备份的更改';
    if (versions.cloudVersion > base) return '云端有新版本，建议立即备份';
    if (versions.cloudVersion < base) {
      return '云端版本与上次记录不一致，请立即备份';
    }
    return '本地与云端版本一致';
  }

  /// 只读云端那份，不合并、不写云端；写不写本机由确认框决定，和从文件恢复同一个框。
  Future<void> _restore() async {
    if (!_masterPasswordStrongEnough()) return;
    setState(() => _busy = true);
    try {
      await _saveSync();
      final service = CloudSyncService(
        ref.read(vaultRepositoryProvider),
        client: ref.read(httpClientProvider),
        githubEnabled: ref.read(forkFeaturesProvider).githubSync,
      );
      final imported = await service.downloadBackup();
      final controller = ref.read(vaultControllerProvider.notifier);
      final shown = planVaultImport(imported, await controller.ready());
      if (!mounted) return;
      final mode = await confirmVaultImport(context, shown);
      if (mode == null) return;
      final plan = await controller.importVault(shown, mode);
      _message(vaultImportSummary(plan, mode));
    } on FormatException catch (error) {
      _message(error.message);
    } on Object catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LText(value)));
    }
  }
}

class _AdaptiveSyncProviderLabel extends StatelessWidget {
  const _AdaptiveSyncProviderLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 48,
        height: 24,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: LText(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
          ),
        ),
      );
}

class _GitHubDeviceFlowDialog extends StatefulWidget {
  const _GitHubDeviceFlowDialog({
    required this.authorization,
    required this.auth,
  });

  final GitHubDeviceAuthorization authorization;
  final GitHubAuthService auth;

  @override
  State<_GitHubDeviceFlowDialog> createState() =>
      _GitHubDeviceFlowDialogState();
}

class _GitHubDeviceFlowDialogState extends State<_GitHubDeviceFlowDialog> {
  Object? error;
  GitHubAuthPollState state = GitHubAuthPollState.waitingForAuthorization;
  bool cancelled = false;

  @override
  void initState() {
    super.initState();
    unawaited(Clipboard.setData(
      ClipboardData(text: widget.authorization.userCode),
    ));
    unawaited(_openGitHub());
    unawaited(_poll());
  }

  @override
  void dispose() {
    cancelled = true;
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final token = await widget.auth.poll(
        widget.authorization,
        isCancelled: () => cancelled,
        onStateChanged: (value) {
          if (mounted) setState(() => state = value);
        },
      );
      if (mounted) Navigator.pop(context, token);
    } on GitHubAuthCancelledException {
      // Closing the dialog intentionally stops the pending device flow.
    } on Object catch (value) {
      if (mounted) setState(() => error = value);
    }
  }

  Future<void> _openGitHub() => launchUrl(
        widget.authorization.verificationUri,
        mode: LaunchMode.externalApplication,
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.code, size: 34),
        title: const LText('登录 GitHub'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LText('验证码已复制。请在浏览器中登录 GitHub 并确认授权。'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: LSelectableText(
                widget.authorization.userCode,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      letterSpacing: 3,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            const SizedBox(height: 16),
            if (error == null) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              LText(
                state == GitHubAuthPollState.retryingNetwork
                    ? '网络连接发生变化，正在自动重试…'
                    : '正在等待 GitHub 授权…',
                textAlign: TextAlign.center,
              ),
            ] else
              LText(
                '$error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          OutlinedButton.icon(
            onPressed: _openGitHub,
            icon: const Icon(Icons.open_in_browser),
            label: const LText('打开 GitHub'),
          ),
        ],
      );
}
