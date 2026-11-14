import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:url_launcher/url_launcher.dart';

import '../../application/fork_features.dart';
import '../../application/settings_controller.dart';
import '../../application/vault_controller.dart';
import '../../application/vault_import.dart';
import '../../domain/models/settings.dart';
import '../../infrastructure/storage/background_image_service.dart';
import '../../infrastructure/storage/picked_files.dart';
import '../../infrastructure/storage/encrypted_vault_file.dart';
import '../../infrastructure/storage/vault_repository.dart';
import '../../infrastructure/storage/vault_export_service.dart';
import '../../infrastructure/http_client_provider.dart';
import '../../infrastructure/update_check_service.dart';
import '../theme.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import '../widgets/choice_segments.dart';
import '../widgets/form_gap.dart';
import '../widgets/keychain_sheet.dart';
import '../widgets/proxy_profiles_page.dart';
import '../widgets/terminal_engine_status.dart';
import '../widgets/custom_background.dart';
import '../widgets/ai_providers_page.dart';
import '../widgets/vault_import_dialog.dart';
import '../widgets/vault_passphrase_dialog.dart';
import '../widgets/terminal_key_feel_tiles.dart';
import 'app_lock_settings_screen.dart';
import 'app_log_screen.dart';
import 'cloud_backup_screen.dart';
import 'hidden_hosts_screen.dart';
import 'known_hosts_screen.dart';
import 'lan_transfer_screen.dart';
import 'plugins_screen.dart';
import 'rustdesk_screen.dart';
import 'tailscale_catalog_screen.dart';
import 'uuremote_screen.dart';

part 'settings_screen_dialogs.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final Future<PackageInfo> _packageInfo;
  UpdateCheckService? _updateCheckService;
  final _backgroundImageService = BackgroundImageService();
  late Future<UpdateCheckResult> _updateCheck;
  SyncConnection? _backup;
  var themeMode = 'dark';
  var uiThemeId = 'tokyo-night';
  var terminalFontSize = 14.0;
  var sftpSyntaxHighlight = true;
  var terminalSecureKeyboard = false;
  var customBackgroundEnabled = false;
  var customBackgroundPath = '';
  var customBackgroundOpacity = 0.35;
  var customBackgroundAlignment = 'center';
  var customBackgroundScope = 'global';
  var _persistedBackgroundPath = '';
  var _savingTerminalSecureKeyboard = false;
  var terminalFullscreenSwipe = false;
  var _savingTerminalFullscreenSwipe = false;
  var allowSensitiveScreenshots = false;
  var _savingAllowSensitiveScreenshots = false;
  var language = 'zh-CN';
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _packageInfo = PackageInfo.fromPlatform();
    // 设置页在 HomeShell 的 IndexedStack 里，App 冷启动就会走到这里；
    // 开关关着时不创建服务，从根上保证没有请求。
    if (ref.read(forkFeaturesProvider).updateCheck) {
      _updateCheckService = UpdateCheckService(
        client: ref.read(httpClientProvider),
      );
      _updateCheck = _checkForUpdates();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  @override
  void dispose() {
    _updateCheckService?.close();
    super.dispose();
  }

  Future<void> _load() async {
    final repository = ref.read(vaultRepositoryProvider);
    final settings = await repository.loadSettings();
    terminalSecureKeyboard = settings.terminalSecureKeyboard;
    terminalFullscreenSwipe = settings.terminalFullscreenSwipe;
    allowSensitiveScreenshots = settings.allowSensitiveScreenshots;
    _showSaved(settings);
    await _loadBackup();
  }

  Future<void> _loadBackup() async {
    final backup = await ref.read(vaultRepositoryProvider).loadSyncConnection();
    if (mounted) setState(() => _backup = backup);
  }

  /// 数据分组里「云端备份」那一行的状态。
  String _backupStatus(AppSettings settings) {
    final backup = _backup;
    final name = switch (backup?.type) {
      SyncProviderType.webdav when backup!.endpoint.isNotEmpty => 'WebDAV',
      SyncProviderType.s3 when backup!.bucket?.isNotEmpty == true => 'S3',
      // 这个版本没有 GitHub 那一项时，存着的配置不作数（SYN03）。
      SyncProviderType.githubGist
          when ref.read(forkFeaturesProvider).githubSync &&
              backup!.secret?.isNotEmpty == true =>
        'GitHub',
      _ => null,
    };
    if (name == null) return localized('未设置');
    return settings.autoSyncEnabled ? '$name · ${localized('自动')}' : name;
  }

  @override
  Widget build(BuildContext context) => _buildSettings(
        context,
        ref.watch(forkFeaturesProvider),
        ref.watch(settingsControllerProvider),
      );

  /// 设置页（R86 校准页）：FlClash 设置页的样子，分组小标题 + 连在一起的分组卡片，
  /// 行用 ui/components.dart 的公共行。项、分组、顺序、key 和保存时机照旧（UIM07 逐项对过）。
  Widget _buildSettings(
    BuildContext context,
    ForkFeatures features,
    AppSettings lockSettings,
  ) =>
      SafeArea(
        child: Scaffold(
          appBar: AppBar(title: const LText('设置')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              ShunSection(
                title: '通用',
                children: [
                  ShunSectionItem(
                    child: ChoiceSegments<String>(
                      key: const ValueKey('settings-theme-mode'),
                      segments: const [
                        ChoiceSegment('dark', '深色'),
                        ChoiceSegment('light', '浅色'),
                        ChoiceSegment('system', '系统'),
                      ],
                      selected: themeMode,
                      onTap: (value) {
                        if (value == themeMode) return;
                        setState(() => themeMode = value);
                        _saveSetting((s) => s.copyWith(themeMode: value));
                      },
                    ),
                  ),
                  Builder(
                    builder: (context) {
                      final brightness = themeMode == 'light'
                          ? Brightness.light
                          : themeMode == 'dark'
                              ? Brightness.dark
                              : MediaQuery.platformBrightnessOf(context);
                      final selected = ShunTheme.resolve(brightness, uiThemeId);
                      return ShunListRow(
                        key: const ValueKey('settings-ui-theme'),
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: selected.background,
                          child: Icon(
                            Icons.palette_outlined,
                            size: 18,
                            color: selected.primary,
                          ),
                        ),
                        title: '界面主题',
                        subtitle:
                            '${selected.name} · ${ShunTheme.presets(brightness).length} 种可选',
                        chevron: true,
                        onTap: () => _selectTheme(brightness),
                      );
                    },
                  ),
                  ShunSwitchRow(
                    key: const ValueKey('custom-background-switch'),
                    title: '自定义背景',
                    value: customBackgroundEnabled,
                    onChanged: (value) async {
                      if (value && customBackgroundPath.isEmpty) {
                        await _pickBackgroundImage();
                        return;
                      }
                      if (!mounted) return;
                      setState(() => customBackgroundEnabled = value);
                      await _saveSetting(
                        (s) => s.copyWith(customBackgroundEnabled: value),
                      );
                    },
                  ),
                  if (customBackgroundEnabled)
                    ShunSectionItem(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ChoiceSegments<String>(
                            key: const ValueKey('custom-background-scope'),
                            segments: const [
                              ChoiceSegment('global', '全局背景'),
                              ChoiceSegment('terminal', '仅终端'),
                            ],
                            selected: customBackgroundScope,
                            onTap: (value) {
                              if (value == customBackgroundScope) return;
                              setState(() => customBackgroundScope = value);
                              _saveSetting(
                                (s) => s.copyWith(customBackgroundScope: value),
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          _backgroundPreview(),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: ShunButton(
                                  key: const ValueKey(
                                      'custom-background-picker'),
                                  kind: ShunButtonKind.outlined,
                                  icon: Icons.image_outlined,
                                  label: customBackgroundPath.isEmpty
                                      ? '选择背景图片'
                                      : '更换背景图片',
                                  onPressed: _pickBackgroundImage,
                                ),
                              ),
                              if (customBackgroundPath.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                IconButton.outlined(
                                  key: const ValueKey(
                                      'custom-background-remove'),
                                  tooltip: localized('移除背景图片'),
                                  onPressed: _removeBackgroundImage,
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const LText('背景不透明度'),
                              const SizedBox(width: 12),
                              Expanded(
                                child: prism.Slider(
                                  key: const ValueKey(
                                      'custom-background-opacity'),
                                  value: customBackgroundOpacity,
                                  min: 0.05,
                                  max: 1,
                                  divisions: 19,
                                  label:
                                      '${(customBackgroundOpacity * 100).round()}%',
                                  onChanged: (value) => setState(
                                    () => customBackgroundOpacity = value,
                                  ),
                                  // 拖动中只改预览，松手才存：拖一下会触发几十次 onChanged。
                                  onChangeEnd: (value) => _saveSetting(
                                    (s) => s.copyWith(
                                      customBackgroundOpacity: value,
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 48,
                                child: LText(
                                  '${(customBackgroundOpacity * 100).round()}%',
                                  textAlign: TextAlign.end,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (customBackgroundEnabled)
                    ShunOptionsRow<String>(
                      key: const ValueKey('custom-background-alignment'),
                      title: '背景对齐方式',
                      value: customBackgroundAlignment,
                      options: [
                        for (final value in supportedCustomBackgroundAlignments)
                          (value, _backgroundAlignmentLabel(value)),
                      ],
                      onChanged: (value) {
                        setState(() => customBackgroundAlignment = value);
                        _saveSetting(
                          (s) => s.copyWith(customBackgroundAlignment: value),
                        );
                      },
                    ),
                  ShunSectionItem(
                    child: Row(
                      children: [
                        const LText('界面语言'),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ChoiceSegments<String>(
                            key: const ValueKey('settings-language'),
                            segments: const [
                              ChoiceSegment('zh-CN', '中文'),
                              ChoiceSegment('en', '英文'),
                            ],
                            selected: language,
                            onTap: (value) {
                              if (value == language) return;
                              setState(() => language = value);
                              _saveSetting((s) => s.copyWith(language: value));
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  ShunSwitchRow(
                    key: const ValueKey('settings-sftp-highlight'),
                    title: 'SFTP 代码高亮',
                    value: sftpSyntaxHighlight,
                    onChanged: (value) {
                      setState(() => sftpSyntaxHighlight = value);
                      _saveSetting(
                        (s) => s.copyWith(sftpSyntaxHighlight: value),
                      );
                    },
                  ),
                ],
              ),
              if (features.ai)
                ShunSection(
                  title: 'shu Agent',
                  // 标题没有中文：和提示写在同一行，本地化覆盖测试会把两段当成一句。
                  hint: '用 OpenAI 兼容接口对话。它要执行的命令，每条都先问你。',
                  children: [
                    ShunListRow(
                      leading: const Icon(Icons.dns_outlined),
                      title: '管理多个 AI 服务商',
                      chevron: true,
                      onTap: _openAiProviders,
                    ),
                  ],
                ),
              if (features.updateCheck)
                ShunSection(children: [_updateCheckTile()]),
              ShunSection(
                title: '终端',
                children: [
                  ShunSectionItem(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const LText('终端字号'),
                            const SizedBox(width: 12),
                            Expanded(
                              child: prism.Slider(
                                key: const ValueKey(
                                    'settings-terminal-font-size'),
                                value: terminalFontSize,
                                min: minTerminalFontSize,
                                max: maxTerminalFontSize,
                                divisions: 18,
                                label: terminalFontSize.toStringAsFixed(0),
                                onChanged: (value) =>
                                    setState(() => terminalFontSize = value),
                                // 松手才存：每存一次开着的终端都要按新字号重排、给服务器发一次尺寸变化。
                                onChangeEnd: (value) => _saveSetting(
                                  (s) => s.copyWith(terminalFontSize: value),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 32,
                              child: LText(
                                terminalFontSize.toStringAsFixed(0),
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // 用终端的等宽字体和字号示意一行，拖动时跟着变，不用切到终端页看。
                        // 只是示意：读屏不念。
                        ExcludeSemantics(
                          child: Container(
                            key: const ValueKey(
                                'settings-terminal-font-preview'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'user@server:~\$ ls -la',
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              softWrap: false,
                              // 终端里的字不跟系统字体大小变（使用手册第 8 节），示意也不变，不然看着比实际大。
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: terminalFontSize,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ShunSwitchRow(
                    key: const ValueKey('terminal-secure-keyboard'),
                    title: '系统安全键盘',
                    hint: '用系统的密码键盘打字，输入法不联想、不记词。快捷键栏照样能发 Ctrl 组合键。',
                    value: terminalSecureKeyboard,
                    onChanged: _savingTerminalSecureKeyboard
                        ? null
                        : _setTerminalSecureKeyboard,
                  ),
                  ShunSwitchRow(
                    key: const ValueKey('terminal-fullscreen-swipe'),
                    title: '全屏程序里滑动翻页',
                    // 只留会出事的那一句：没开 mouse 的 tmux 也算全屏程序，滑一下就翻出历史命令。
                    // 一整句一个字面量：本地化按整句查译文，拆成几段拼起来就查不到了。
                    hint:
                        '在 less、man、vim 里上下滑会发方向键。没开 mouse 的 tmux 也算全屏程序：滑动会翻出上一条历史命令，再按回车就执行了。',
                    value: terminalFullscreenSwipe,
                    onChanged: _savingTerminalFullscreenSwipe
                        ? null
                        : _setTerminalFullscreenSwipe,
                  ),
                  ...terminalKeyFeelRows(),
                  const ShunSectionItem(child: TerminalEngineStatusTile()),
                ],
              ),
              ShunSection(
                title: '连接',
                children: [
                  ShunListRow(
                    key: const ValueKey('settings-proxy-profiles'),
                    leading: const Icon(Icons.public),
                    title: '代理管理',
                    chevron: true,
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ProxyProfilesPage())),
                  ),
                  ShunListRow(
                    key: const ValueKey('settings-credentials'),
                    leading: const Icon(Icons.key_outlined),
                    title: '凭据',
                    subtitle: '账号密码、SSH 密钥、安全密钥',
                    chevron: true,
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      builder: (_) => const KeychainSheet(),
                    ),
                  ),
                  ShunListRow(
                    key: const ValueKey('settings-tailscale-catalog'),
                    leading: const Icon(Icons.lan_outlined),
                    title: 'Tailscale',
                    chevron: true,
                    onTap: () => openTailscale(context, ref),
                  ),
                  ShunListRow(
                    key: const ValueKey('settings-app-log'),
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: '日志',
                    chevron: true,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AppLogScreen(),
                      ),
                    ),
                  ),
                ],
              ),
              // 存储和指纹两条以前各占一行卡片，点了没反应，只是在说明；收进分组的 ⓘ。
              if (Platform.isAndroid)
                ShunSection(
                  title: '插件',
                  hint:
                      '远程桌面交给手机上装的 UU 远程或 RustDesk，它们用自己的网络。插件是单独安装的 App，每个都要你批准后才会用。',
                  children: [
                    ShunListRow(
                      key: const ValueKey('settings-uuremote'),
                      leading: const Icon(Icons.desktop_windows_outlined),
                      title: 'UU 远程',
                      chevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const UuRemoteSettingsScreen(),
                        ),
                      ),
                    ),
                    ShunListRow(
                      key: const ValueKey('settings-rustdesk'),
                      leading: const Icon(Icons.connected_tv_outlined),
                      title: 'RustDesk',
                      chevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const RustDeskSettingsScreen(),
                        ),
                      ),
                    ),
                    ShunListRow(
                      key: const ValueKey('settings-plugins'),
                      leading: const Icon(Icons.extension_outlined),
                      title: '插件（实验）',
                      chevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const PluginsScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
              ShunSection(
                title: '安全',
                hint: '密码和私钥只存在系统的安全存储里。第一次连一台服务器要你核对指纹；以后指纹变了直接拦下，不发登录信息。',
                children: [
                  ShunSwitchRow(
                    key: const ValueKey('settings-allow-sensitive-screenshots'),
                    leading: const Icon(Icons.screenshot_outlined),
                    title: '敏感页面允许截屏',
                    hint:
                        '关着时，编辑连接、编辑代理和输密码的对话框截屏、录屏都是黑的，最近任务里也看不到。终端页不受影响。只对 Android 有效。',
                    value: allowSensitiveScreenshots,
                    onChanged: _savingAllowSensitiveScreenshots
                        ? null
                        : _setAllowSensitiveScreenshots,
                  ),
                  if (Platform.isAndroid)
                    ShunListRow(
                      key: const ValueKey('settings-app-lock'),
                      leading: const Icon(Icons.lock_outline),
                      title: '应用锁',
                      subtitle: lockSettings.appLockEnabled
                          ? appLockGraceLabel(lockSettings.appLockGraceSeconds)
                          : '关',
                      chevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AppLockSettingsScreen(),
                        ),
                      ),
                    ),
                  ShunListRow(
                    key: const ValueKey('settings-hidden-hosts'),
                    leading: const Icon(Icons.visibility_off_outlined),
                    title: '隐藏的主机',
                    chevron: true,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const HiddenHostsScreen(),
                      ),
                    ),
                  ),
                  ShunListRow(
                    key: const ValueKey('settings-known-hosts'),
                    leading: const Icon(Icons.verified_user_outlined),
                    title: '可信主机密钥',
                    chevron: true,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const KnownHostsScreen(),
                      ),
                    ),
                  ),
                ],
              ),
              ShunSection(
                title: '数据',
                hint:
                    '备份里有密码和私钥，全程加密，靠你定的密码保护。换手机用备份恢复，两台手机在同一个 Wi-Fi 也可以扫码互传。',
                children: [
                  if (features.cloudSync)
                    ShunListRow(
                      key: const ValueKey('settings-cloud-backup'),
                      leading: const Icon(Icons.cloud_outlined),
                      title: '云端备份',
                      subtitle: _backupStatus(lockSettings),
                      chevron: true,
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const CloudBackupScreen(),
                          ),
                        );
                        await _loadBackup();
                      },
                    ),
                  ShunListRow(
                    key: const ValueKey('export-encrypted-backup'),
                    leading: const Icon(Icons.enhanced_encryption_outlined),
                    title: '备份到文件',
                    onTap: _exportEncrypted,
                  ),
                  ShunListRow(
                    key: const ValueKey('restore-from-file'),
                    leading: const Icon(Icons.settings_backup_restore),
                    title: '从文件恢复',
                    onTap: _import,
                  ),
                  if (Platform.isAndroid) ...[
                    ShunListRow(
                      key: const ValueKey('lan-send'),
                      leading: const Icon(Icons.qr_code_2),
                      title: '发到另一台手机',
                      chevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const LanSendScreen(),
                        ),
                      ),
                    ),
                    ShunListRow(
                      key: const ValueKey('lan-receive'),
                      leading: const Icon(Icons.qr_code_scanner),
                      title: '从另一台手机接收',
                      chevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const LanReceiveScreen(),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 24),
              Center(
                child: FutureBuilder<PackageInfo>(
                  future: _packageInfo,
                  builder: (context, snapshot) => LText(
                    snapshot.hasData
                        ? 'shun ${snapshot.data!.version} · GPL-3.0-or-later'
                        : 'shun · GPL-3.0-or-later',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              // GPL 要求修改版写明出处；原作者署名在 NOTICE.md。
              Center(
                child: LText(
                  '基于 Netcatty Mobile 修改',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _updateCheckTile() => FutureBuilder<UpdateCheckResult>(
        future: _updateCheck,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const ShunListRow(
              leading: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              title: '正在检查更新',
              subtitle: '正在查询 GitHub 最新 Release',
            );
          }
          if (snapshot.hasError) {
            return ShunListRow(
              leading: Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: '检查更新失败',
              subtitle: '${snapshot.error}\n点按重试',
              trailing: const ExcludeSemantics(child: Icon(Icons.refresh)),
              onTap: _retryUpdateCheck,
            );
          }

          final result = snapshot.requireData;
          final title = result.updateAvailable
              ? '发现新版本 ${result.latestVersion}'
              : result.isLatest
                  ? '已是最新版本'
                  : '当前为开发版本';
          final subtitle = result.updateAvailable
              ? '当前版本 ${result.currentVersion} · 点按前往下载'
              : result.isLatest
                  ? '当前版本 ${result.currentVersion} · 点按查看最新 Release'
                  : '当前 ${result.currentVersion} · 最新正式版 ${result.latestVersion}';
          final icon = result.updateAvailable
              ? Icons.system_update_alt
              : result.isLatest
                  ? Icons.check_circle_outline
                  : Icons.science_outlined;
          return ShunListRow(
            leading: Icon(
              icon,
              color: result.updateAvailable
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: title,
            subtitle: subtitle,
            trailing: const ExcludeSemantics(child: Icon(Icons.open_in_new)),
            onTap: () => _openLatestRelease(result.releaseUri),
          );
        },
      );

  Future<UpdateCheckResult> _checkForUpdates() async {
    final info = await _packageInfo;
    return _updateCheckService!.check(info.version);
  }

  void _retryUpdateCheck() {
    setState(() => _updateCheck = _checkForUpdates());
  }

  Future<void> _openLatestRelease(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) _message('无法打开 GitHub Release 页面');
    } on Object {
      _message('无法打开 GitHub Release 页面');
    }
  }

  Future<void> _openAiProviders() async {
    try {
      final repository = ref.read(vaultRepositoryProvider);
      await repository.aiWorkspace.migrateLegacyProvider(
          await repository.loadSettings(),
          await repository.readAiApiKey() ?? '');
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => AiProvidersPage(workspace: repository.aiWorkspace)));
    } catch (error) {
      if (mounted) _message('$error');
    }
  }

  Widget _backgroundPreview() {
    if (customBackgroundPath.isEmpty) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(
        aspectRatio: 16 / 7,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Opacity(
            opacity: customBackgroundOpacity,
            child: Image.file(
              File(customBackgroundPath),
              key: ValueKey('custom-background-preview-$customBackgroundPath'),
              fit: BoxFit.cover,
              alignment: resolveCustomBackgroundAlignment(
                customBackgroundAlignment,
              ),
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const Center(
                child: LText('背景图片无法读取，请重新选择'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 外观、终端字号、SFTP 高亮这几项照存盘的 [settings] 显示。
  void _showSaved(AppSettings settings) {
    themeMode = settings.themeMode;
    uiThemeId = settings.uiThemeId;
    terminalFontSize = settings.terminalFontSize;
    sftpSyntaxHighlight = settings.sftpSyntaxHighlight;
    customBackgroundEnabled = settings.customBackgroundEnabled;
    customBackgroundPath = settings.customBackgroundPath;
    customBackgroundOpacity = settings.customBackgroundOpacity;
    customBackgroundAlignment = settings.customBackgroundAlignment;
    customBackgroundScope = settings.customBackgroundScope;
    _persistedBackgroundPath = settings.customBackgroundPath;
    language = settings.language;
  }

  /// 设置一改就存（R25 起没有「保存外观设置」按钮：以前主题、字号要点它才生效，同一张卡里的
  /// 安全键盘、滑动翻页却是一拨就存，改完主题不点按钮就白改）。没存上时界面退回存盘的样子、
  /// 说一声，返回 false。
  Future<bool> _saveSetting(AppSettings Function(AppSettings) change) async {
    try {
      await ref.read(settingsControllerProvider.notifier).edit(change);
      return true;
    } catch (error) {
      if (!mounted) return false;
      final saved = await ref.read(vaultRepositoryProvider).loadSettings();
      if (!mounted) return false;
      setState(() => _showSaved(saved));
      _message('设置没存上：$error');
      return false;
    }
  }

  Future<void> _pickBackgroundImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: false,
        withReadStream: true,
      );
      if (result == null || result.files.isEmpty) return;
      final selected = result.files.single;
      final String stored;
      try {
        stored = await _backgroundImageService.persist(
          sourcePath: selected.path,
          bytes: selected.bytes,
          stream: selected.readStream,
          extension: selected.extension,
        );
      } finally {
        // 已经另存了一份，选择器留在缓存里的那份没用了。
        await discardPickedCopy(selected);
      }
      if (!mounted) {
        await _backgroundImageService.remove(stored);
        return;
      }
      final previous = _persistedBackgroundPath;
      setState(() {
        customBackgroundPath = stored;
        customBackgroundEnabled = true;
      });
      final saved = await _saveSetting((s) => s.copyWith(
            customBackgroundPath: stored,
            customBackgroundEnabled: true,
          ));
      if (!saved) {
        await _backgroundImageService.remove(stored);
        return;
      }
      _persistedBackgroundPath = stored;
      // 新图存上了再删旧图：先删的话存失败时设置里还指着一个没了的文件。
      if (previous.isNotEmpty && previous != stored) {
        await _backgroundImageService.remove(previous);
      }
    } catch (error) {
      _message('选择背景图片失败：$error');
    }
  }

  Future<void> _removeBackgroundImage() async {
    final previous = _persistedBackgroundPath;
    setState(() {
      customBackgroundPath = '';
      customBackgroundEnabled = false;
    });
    final saved = await _saveSetting((s) => s.copyWith(
          customBackgroundPath: '',
          customBackgroundEnabled: false,
        ));
    if (!saved) return;
    _persistedBackgroundPath = '';
    if (previous.isNotEmpty) await _backgroundImageService.remove(previous);
  }

  String _backgroundAlignmentLabel(String value) => switch (value) {
        'topLeft' => '左上',
        'topCenter' => '顶部居中',
        'topRight' => '右上',
        'centerLeft' => '左侧居中',
        'centerRight' => '右侧居中',
        'bottomLeft' => '左下',
        'bottomCenter' => '底部居中',
        'bottomRight' => '右下',
        _ => '居中',
      };

  Future<void> _setTerminalSecureKeyboard(bool value) async {
    final previous = terminalSecureKeyboard;
    setState(() {
      terminalSecureKeyboard = value;
      _savingTerminalSecureKeyboard = true;
    });
    try {
      await ref
          .read(settingsControllerProvider.notifier)
          .updateTerminalSecureKeyboard(value);
    } catch (error) {
      if (!mounted) return;
      setState(() => terminalSecureKeyboard = previous);
      _message('安全键盘设置保存失败：$error');
    } finally {
      if (mounted) {
        setState(() => _savingTerminalSecureKeyboard = false);
      }
    }
  }

  Future<void> _setAllowSensitiveScreenshots(bool value) async {
    final previous = allowSensitiveScreenshots;
    setState(() {
      allowSensitiveScreenshots = value;
      _savingAllowSensitiveScreenshots = true;
    });
    try {
      await ref
          .read(settingsControllerProvider.notifier)
          .updateAllowSensitiveScreenshots(value);
    } catch (error) {
      if (!mounted) return;
      setState(() => allowSensitiveScreenshots = previous);
      _message('防截屏设置保存失败：$error');
    } finally {
      if (mounted) {
        setState(() => _savingAllowSensitiveScreenshots = false);
      }
    }
  }

  Future<void> _setTerminalFullscreenSwipe(bool value) async {
    final previous = terminalFullscreenSwipe;
    setState(() {
      terminalFullscreenSwipe = value;
      _savingTerminalFullscreenSwipe = true;
    });
    try {
      await ref
          .read(settingsControllerProvider.notifier)
          .updateTerminalFullscreenSwipe(value);
    } catch (error) {
      if (!mounted) return;
      setState(() => terminalFullscreenSwipe = previous);
      _message('滑动翻页设置保存失败：$error');
    } finally {
      if (mounted) {
        setState(() => _savingTerminalFullscreenSwipe = false);
      }
    }
  }

  Future<void> _selectTheme(Brightness brightness) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _ThemePicker(
        brightness: brightness,
        selectedId: uiThemeId,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => uiThemeId = selected);
    await _saveSetting((s) => s.copyWith(uiThemeId: selected));
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null) return;
    try {
      final file = result.files.single;
      final List<int> bytes;
      try {
        bytes = file.bytes ?? await File(file.path!).readAsBytes();
      } finally {
        // 选择器在缓存里留了一份，读完就删。
        await discardPickedCopy(file);
      }
      final backup = EncryptedVaultFile.tryParse(bytes);
      if (backup == null) {
        throw const FormatException(EncryptedVaultFile.notABackup);
      }
      if (!mounted) return;
      final imported = await askAndDecodeBackup(context, backup);
      if (imported == null) return;
      final controller = ref.read(vaultControllerProvider.notifier);
      // 先让用户看清会新增、更新、删除什么再写。以前直接整库替换，文件里没有的主机连同凭据被删。
      final shown = planVaultImport(imported, await controller.ready());
      if (!mounted) return;
      final mode = await confirmVaultImport(context, shown);
      if (mode == null) return;
      final plan = await controller.importVault(shown, mode);
      _message(vaultImportSummary(plan, mode));
    } on FormatException catch (error) {
      _message('恢复失败：${error.message}');
    } catch (error) {
      _message('恢复失败：$error');
    }
  }

  Future<void> _exportEncrypted() async {
    try {
      final controller = ref.read(vaultControllerProvider.notifier);
      final vault = await controller.ready();
      final version = (await PackageInfo.fromPlatform()).version;
      if (!mounted) return;
      final bytes = await askAndEncodeBackup(context, vault, version);
      if (bytes == null) return;
      final result = await VaultExportService().exportEncrypted(bytes);
      if (result != VaultExportResult.saved) return;
      // 解不开的凭据没法放进备份。不说的话，用户换完手机才发现少了密码。
      final missing = controller.repository.unreadableSecrets.length;
      _message(missing == 0 ? '备份已保存' : '备份已保存，但有 $missing 条凭据解不开，没有带上');
    } catch (error) {
      _message('备份失败：$error');
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: LText(value)));
    }
  }
}
