import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';

import '../../application/plugin_discovery.dart';
import '../../application/plugin_registry.dart';
import '../localization/localized_widgets.dart';
import 'plugin_session_test_screen.dart';

String pluginStatusLabel(PluginStatus status) => switch (status) {
      PluginStatus.ready => '可用',
      PluginStatus.needsApproval => '待批准',
      PluginStatus.rejected => '已拒绝',
      PluginStatus.incompatible => '不兼容',
      PluginStatus.disabled => '已停用',
      PluginStatus.missing => '已卸载',
    };

String _deploymentLabel(Deployment deployment) => switch (deployment) {
      Deployment.bundled => '随 App 提供',
      Deployment.androidService => '独立安装的 App',
      Deployment.externalApp => '外部 App',
    };

String _capabilityLabel(Capability capability) => switch (capability) {
      Capability.deviceCatalog => '设备目录',
      Capability.terminalSession => '终端会话',
      Capability.remoteDesktopExternal => '打开外部远控 App',
      Capability.remoteDesktopSurface => '内嵌远控画面',
      Capability.route => '连接路线',
    };

String _routeLabel(RouteSupport route) => switch (route) {
      RouteSupport.systemDefault => '直连（系统网络）',
      RouteSupport.socks5Connect => 'SOCKS5 代理',
      RouteSupport.proxyJump => '跳板机',
      RouteSupport.socks5ProxyJump => '代理 + 跳板机',
      RouteSupport.providerManaged => '由插件自己管网络',
    };

String _permissionLabel(Permission permission) => switch (permission) {
      Permission.ownSessionEphemeralSecret => '本会话的临时凭据',
      Permission.ownSessionInputOutput => '本会话的输入输出',
      Permission.userInitiatedExternalLaunch => '由你点击后打开外部 App',
      Permission.ownProviderState => '插件自己的状态',
      Permission.deviceCatalogRead => '读设备目录',
    };

/// 译名后面跟协议里的原名：和插件作者的文档、描述符对得上。
String _named(String label, String wire) =>
    '${localized(label)}${_paren(wire)}';

/// 中文界面用全角括号，英文界面用半角加空格。
String _paren(Object? value) =>
    NetcattyLocalizations.isEnglish ? ' ($value)' : '（$value）';

/// 一个插件的全部信息和操作（X04）：来源、证书、版本、能力、路线、权限，
/// 批准 / 连接测试 / 停用 / 启用 / 撤销，以及插件自己的设置页入口。
///
/// 页面始终按注册表此刻的状态画：插件包在这期间被更新、换签或卸载，系统广播触发重新核验，
/// 这里随之变化；之前的连接测试结果作废，不沿用（PLG11）。
class PluginDetailScreen extends ConsumerStatefulWidget {
  const PluginDetailScreen({super.key, required this.packageName});

  final String packageName;

  @override
  ConsumerState<PluginDetailScreen> createState() => _PluginDetailScreenState();
}

class _PluginDetailScreenState extends ConsumerState<PluginDetailScreen> {
  PluginDiscovery? _discovery;
  String? _result;

  /// 做连接测试时这个包的样子。包变了（更新、换签）测试结果就不再作数。
  String? _testedAs;
  var _connected = false;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(pluginDiscoveryProvider.future).then((discovery) {
      if (mounted) setState(() => _discovery = discovery);
    }));
  }

  @override
  void dispose() {
    // 连接测试的连接只在这个页面开着时保持，离开就断开，不在后台留着。
    if (_connected) unawaited(_discovery?.disconnect(widget.packageName));
    super.dispose();
  }

  static String _fingerprint(PluginEntry entry) => [
        entry.status.name,
        entry.installedVersionCode,
        ...entry.signerDigests,
        entry.descriptor?.version,
      ].join('|');

  Future<void> _run(Future<void> Function(PluginDiscovery d) action) async {
    final discovery = _discovery;
    if (discovery == null || _busy) return;
    setState(() => _busy = true);
    try {
      await action(discovery);
    } on PluginApprovalRefused catch (e) {
      _message(e.message);
    } on Object catch (e) {
      _message('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 对用户这次点击的直接回应，马上显示：SnackBar 会排队，排在「检测到插件包更新」之类的提示后面，
  /// 用户点了批准却要等四秒才看到「没有批准」，中间会以为已经批准了。
  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: LText(value)));
  }

  @override
  Widget build(BuildContext context) {
    final entry = ref
        .watch(pluginRegistryProvider)
        .where((e) => e.packageName == widget.packageName)
        .firstOrNull;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    if (entry == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.packageName)),
        body: const Padding(
          padding: EdgeInsets.all(16),
          child: LText('这个插件不在列表里了'),
        ),
      );
    }
    final d = entry.descriptor;
    final stale = _testedAs != null && _testedAs != _fingerprint(entry);
    // 包变了之后发现流程已经断开了那条连接，这里不能再给「断开」，免得以为还连着。
    final connected = _connected && !stale;
    return Scaffold(
      appBar: AppBar(title: Text(d?.displayName ?? widget.packageName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Chip(
                key: const ValueKey('plugin-status'),
                label: LText(pluginStatusLabel(entry.status)),
              ),
              const SizedBox(width: 8),
              if (entry.reason != null)
                Expanded(child: LText(entry.reason!, style: small)),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          _section('这是谁'),
          if (d != null) ...[
            _line('来源：', localized(_deploymentLabel(d.deployment))),
            _line('插件 ID：', d.pluginId),
          ],
          _line('包名：', widget.packageName),
          if (d != null) _line('插件自称的版本：', d.version),
          if (entry.installedVersionName != null ||
              entry.installedVersionCode != null)
            _line(
              '安装包版本：',
              '${entry.installedVersionName ?? '?'}${_paren(entry.installedVersionCode ?? '?')}',
            ),
          if (d != null) _line('插件 API：', '${d.apiMajor}.${d.apiMinor}'),
          if (d?.license != null) _line('许可证：', d!.license!),
          if (d?.sourceUrl != null) _line('源码：', d!.sourceUrl!),
          const SizedBox(height: 8),
          const LText('签名证书 SHA-256（请与插件作者公布的核对）：'),
          SelectableText(
            entry.signerDigests.isEmpty ? '—' : entry.signerDigests.join('\n'),
            key: const ValueKey('plugin-signers'),
            style: small,
          ),
          if (entry.androidDebugSigned)
            LText('用 Android 调试证书签名：只有开发构建能用', style: small),
          if (d != null) ...[
            _section('它能做什么'),
            _line(
                '能力：',
                d.capabilities
                    .map((c) => _named(_capabilityLabel(c), c.wire))
                    .join('、')),
            _line(
                '支持的连接路线：',
                d.supportedRoutes
                    .map((r) => _named(_routeLabel(r), r.wire))
                    .join('、')),
            _line(
                '申请的权限：',
                d.permissions
                    .map((p) => _named(_permissionLabel(p), p.wire))
                    .join('、')),
            LText(
              '插件拿不到保险库、私钥、密码或其他主机；它是独立的 App，有自己的系统权限，本 App 管不住它自己联网。',
              style: small,
            ),
          ],
          _section('插件自己的设置页'),
          ..._settings(entry, small),
          _section('操作'),
          if (stale)
            LText('插件包刚变过（更新、换签或状态变化），之前的连接测试结果已作废。', style: small)
          else if (_result != null)
            LText(_result!, key: const ValueKey('plugin-check-result')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _actions(entry, connected: connected),
          ),
        ],
      ),
    );
  }

  List<Widget> _settings(PluginEntry entry, TextStyle? small) {
    if (entry.settingsActivity == null) {
      return [LText('这个插件没有声明设置页。', style: small)];
    }
    if (entry.status != PluginStatus.ready) {
      return [
        LText(
          entry.status == PluginStatus.disabled
              ? '启用后才能打开：停用的插件本 App 不会再启动它。'
              : '批准并启用后才能打开：批准之前不会启动插件的任何代码。',
          style: small,
        ),
      ];
    }
    return [
      LText('设置由插件自己保存，本 App 看不到，也不替它管理。', style: small),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('plugin-open-settings'),
          onPressed: _busy ? null : () => _run((d) => d.openSettings(entry)),
          icon: const Icon(Icons.open_in_new),
          label: const LText('打开插件的设置页'),
        ),
      ),
    ];
  }

  List<Widget> _actions(PluginEntry entry, {required bool connected}) {
    final ready = entry.status == PluginStatus.ready;
    return [
      if (entry.status == PluginStatus.needsApproval)
        FilledButton(
          key: const ValueKey('plugin-approve'),
          onPressed: _busy ? null : () => _approve(entry),
          child: const LText('批准'),
        ),
      if (ready)
        OutlinedButton(
          key: const ValueKey('plugin-check'),
          onPressed: _busy
              ? null
              : () => _run((d) async {
                    setState(() => _result = localized('正在连接…'));
                    final result = await d.check(entry);
                    if (!mounted) return;
                    setState(() {
                      _result = result;
                      _testedAs = _fingerprint(entry);
                      _connected = true;
                    });
                  }),
          child: const LText('连接测试'),
        ),
      // 会话测试（X12）：给插件作者核对终端会话的整个来回，只对声明了终端会话能力的插件。
      if (ready &&
          (entry.descriptor?.capabilities
                  .contains(Capability.terminalSession) ??
              false))
        OutlinedButton(
          key: const ValueKey('plugin-session-test'),
          onPressed: _busy
              ? null
              : () {
                  // 测试页会重新连接，这页之前的连接测试连接随之被替换，结果不再作数。
                  setState(() {
                    _connected = false;
                    _result = null;
                  });
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => PluginSessionTestScreen(
                        packageName: widget.packageName),
                  ));
                },
          child: const LText('会话测试'),
        ),
      if (connected && ready)
        TextButton(
          onPressed: _busy
              ? null
              : () => _run((d) async {
                    await d.disconnect(widget.packageName);
                    if (mounted) setState(() => _connected = false);
                  }),
          child: const LText('断开'),
        ),
      if (ready)
        OutlinedButton(
          key: const ValueKey('plugin-disable'),
          onPressed: _busy
              ? null
              : () => _run((d) async {
                    await d.disable(entry);
                    if (mounted) setState(() => _connected = false);
                    _message('已停用：它的会话已关闭，批准记录保留，重新启用不用再批准。');
                  }),
          child: const LText('停用'),
        ),
      if (entry.status == PluginStatus.disabled)
        FilledButton(
          key: const ValueKey('plugin-enable'),
          onPressed: _busy ? null : () => _run((d) => d.enable(entry)),
          child: const LText('启用'),
        ),
      // 换签被拒、已卸载时也要能撤销旧批准：作者正常换密钥后，用户得有路重新核对。
      if (entry.hasApproval || entry.status == PluginStatus.disabled)
        OutlinedButton(
          key: const ValueKey('plugin-revoke'),
          onPressed: _busy
              ? null
              : () => _run((d) async {
                    await d.revoke(entry);
                    if (mounted) setState(() => _connected = false);
                  }),
          child: const LText('撤销批准'),
        ),
    ];
  }

  Future<void> _approve(PluginEntry entry) async {
    final d = entry.descriptor!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('批准这个插件？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                  '${d.displayName}\n${d.pluginId}\n${entry.packageName}'),
              const SizedBox(height: 8),
              const LText('签名证书 SHA-256（请与插件作者公布的核对）：'),
              SelectableText(entry.signerDigests.join('\n')),
              if (entry.androidDebugSigned)
                const LText('这是 Android 调试证书：每台开发机都有一张，任何人都能用它签名。'),
              const SizedBox(height: 8),
              _line(
                  '能力：',
                  d.capabilities
                      .map((c) => _named(_capabilityLabel(c), c.wire))
                      .join('、')),
              const SizedBox(height: 8),
              const LText(
                '批准后它能收到自己会话里的数据，拿不到保险库、私钥、密码或其他主机。'
                '以后换了签名证书或申请新能力，会重新请你确认。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('取消'),
          ),
          FilledButton(
            key: const ValueKey('plugin-approve-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const LText('批准'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // 传给 approve 的是确认框里给你看的那份：包在确认期间变了会被拒绝，不会批准一个你没核对过的版本。
    await _run((discovery) => discovery.approve(entry));
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: LText(title, style: Theme.of(context).textTheme.titleSmall),
      );

  /// 「标签：值」。值是 ID、包名、版本这类原样显示的数据，长按可复制，方便和作者公布的核对。
  Widget _line(String label, String value) =>
      SelectableText('${localized(label)}$value');
}
