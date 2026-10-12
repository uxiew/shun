import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/connection_lifecycle.dart';
import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/ai_cli.dart';
import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/ssh/ai_cli_discovery.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../../infrastructure/storage/ai_cli_preferences.dart';
import '../localization/localized_widgets.dart';
import 'tailscale_check_card.dart';

typedef AiCliScan = Future<AiCliScanResult> Function(
    AiCliScanRequest request, AiCliProbeCancellation cancellation);

class AiCliToolsSheet extends ConsumerStatefulWidget {
  const AiCliToolsSheet(
      {super.key,
      required this.host,
      this.session,
      this.verifyHostKey,
      this.keyboardInteractive,
      this.service = const AiCliDiscoveryService(),
      this.preferences = const SecureAiCliPreferences(),
      this.scan});
  final HostProfile host;
  final ActiveTerminalSession? session;
  final HostKeyVerifier? verifyHostKey;
  final KeyboardInteractiveHandler? keyboardInteractive;
  final AiCliDiscoveryService service;
  final AiCliPreferencesStore preferences;
  final AiCliScan? scan;
  @override
  ConsumerState<AiCliToolsSheet> createState() => _AiCliToolsSheetState();
}

class _AiCliToolsSheetState extends ConsumerState<AiCliToolsSheet> {
  AiCliScanRequest _request = AiCliScanRequest();
  AiCliScanResult? _result;
  AiCliProbeCancellation? _cancellation;
  ConnectionAttempt? _attempt;
  String? _error;
  bool _loading = false, _settingsReady = false;
  String get _scope => aiCliHostScope(widget.host);
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _cancel() {
    _cancellation?.cancel();
    _attempt?.cancel();
  }

  Future<void> _load() async {
    try {
      final request = await widget.preferences.load(_scope);
      if (!mounted) return;
      setState(() {
        _request = request;
        _settingsReady = true;
      });
      await _refresh();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '无法读取检测设置，请重新设置检测范围';
        });
      }
    }
  }

  Future<AiCliScanResult> _scan(AiCliProbeCancellation cancellation) async {
    if (widget.scan != null) return widget.scan!(_request, cancellation);
    final parent = widget.session;
    if (parent != null) {
      return widget.service.discover(parent, _request, cancellation);
    }
    final vault = await ref.read(vaultControllerProvider.notifier).ready();
    if (!mounted || cancellation.cancelled) {
      throw const AiCliDiscoveryException('检测已取消');
    }
    final host = vault.hosts.where((h) => h.id == widget.host.id).firstOrNull;
    if (host == null || aiCliHostScope(host) != _scope) {
      throw const AiCliDiscoveryException('主机已删除或身份已修改，请重新打开工具列表');
    }
    final plan = resolveRoutePlan(host,
        hosts: vault.hosts,
        keys: vault.keys,
        proxyProfiles: vault.proxyProfiles);
    final live = ref
        .read(sessionControllerProvider)
        .sessions
        .where((s) =>
            s.connected &&
            s.isSsh &&
            !s.closedByUser &&
            sourceHostIdOf(s.host) == host.id &&
            s.routePlan?.shape == plan.shape)
        .firstOrNull;
    if (live != null) {
      return widget.service.discover(live, _request, cancellation);
    }
    final verifier = widget.verifyHostKey;
    if (verifier == null) throw const AiCliDiscoveryException('请先连接这台 SSH 主机');
    final attempt = ConnectionAttempt(onStage: (_) {
      if (mounted) setState(() {});
    }, onCheckPrompt: (_) {
      if (mounted) setState(() {});
    });
    _attempt = attempt;
    return ref.read(sshServiceProvider).withVerifiedClient(
          routePlan: plan,
          verifyHostKey: verifier,
          keyboardInteractive: widget.keyboardInteractive,
          attempt: attempt,
          query: (client) =>
              widget.service.discoverClient(client, _request, cancellation),
        );
  }

  Future<void> _refresh() async {
    if (_loading || !_settingsReady) return;
    final token = AiCliProbeCancellation();
    _cancellation = token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await Future.any<AiCliScanResult>([
        _scan(token),
        token.done.then((_) => throw const AiCliDiscoveryException('检测已取消')),
      ]);
      if (!mounted || !identical(token, _cancellation) || token.cancelled) {
        return;
      }
      setState(() {
        _result = result;
      });
    } catch (error) {
      if (mounted && identical(token, _cancellation)) {
        setState(() {
          _error = token.cancelled
              ? '检测已取消'
              : switch (error) {
                  AiCliDiscoveryException(:final message) => message,
                  _ => '检测未完成，请检查主机连接或检测范围',
                };
        });
      }
    } finally {
      token.cancel();
      _attempt?.cancel();
      _attempt = null;
      if (mounted && identical(token, _cancellation)) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _settings() async {
    final request = await showDialog<AiCliScanRequest>(
        context: context,
        builder: (_) => _DiscoverySettings(initial: _request));
    if (request == null || !mounted) return;
    try {
      await widget.preferences.save(_scope, request);
      if (!mounted) return;
      setState(() {
        _request = request;
        _result = null;
        _settingsReady = true;
      });
      await _refresh();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '检测设置未能保存，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final check = _attempt?.checkPrompt;
    final status = localized(_loading || _error != null ? '上次检测' : '检测完成');
    return SafeArea(
        child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(children: [
              const Icon(Icons.terminal),
              const SizedBox(width: 8),
              const Expanded(
                  child: LText('AI 命令行工具', style: TextStyle(fontSize: 20))),
              IconButton(
                  tooltip: localized('关闭'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close)),
            ])),
        Expanded(
            child: ListView(padding: const EdgeInsets.all(16), children: [
          LText(
              '${widget.host.label} · ${widget.host.username}@${widget.host.hostname}:${widget.host.port}'),
          const SizedBox(height: 8),
          const LText(
              '检测范围：当前 SSH 用户的非交互 PATH、常见安装目录，以及你补充的位置。别名、shell 函数、其他用户和容器内的工具可能无法发现。'),
          const SizedBox(height: 8),
          const LText('找到工具不代表已登录。仅检查可执行文件和安装包标注的版本；不会运行工具、安装软件或调用模型。'),
          Wrap(spacing: 8, children: [
            TextButton.icon(
                key: const ValueKey('ai-cli-refresh'),
                onPressed: _loading || !_settingsReady ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const LText('重新检测')),
            TextButton.icon(
                key: const ValueKey('ai-cli-settings'),
                onPressed: _loading ? null : _settings,
                icon: const Icon(Icons.tune),
                label: const LText('补充目录和工具')),
            if (_loading)
              TextButton(
                  key: const ValueKey('ai-cli-cancel'),
                  onPressed: _cancel,
                  child: const LText('取消检测')),
          ]),
          if (_loading) ...[
            const LinearProgressIndicator(),
            if (_attempt?.stage != null) LText(_attempt!.stage!.describe()),
            if (check != null) TailscaleCheckCard(prompt: check),
          ],
          if (_error != null)
            LText(_error!,
                key: const ValueKey('ai-cli-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (result != null) ...[
            const SizedBox(height: 12),
            LText(
                '$status · ${result.unixUser} (uid ${result.uid}) · ${result.scannedAt.toLocal().toString().substring(0, 19)}'),
            if (result.limited) const LText('已达到检测数量上限，结果只覆盖部分范围。可缩小范围后重试。'),
            for (final kind
                in AiCliKind.values.where((k) => k != AiCliKind.custom))
              _toolGroup(kind.label,
                  result.installations.where((x) => x.kind == kind).toList()),
            if (_request.customTools.isNotEmpty)
              for (final tool in _request.customTools)
                _toolGroup(
                    tool.name,
                    result.installations
                        .where((x) =>
                            x.kind == AiCliKind.custom && x.name == tool.name)
                        .toList()),
            const SizedBox(height: 8),
            const LText('启动和原生继续能力尚未核验。可以在终端手动使用上述工具路径。'),
          ],
        ])),
      ]),
    ));
  }

  String _sourceLabel(String source) {
    if (source == 'common') {
      return localized('常见目录');
    }
    if (source == 'added') {
      return localized('补充目录');
    }
    if (source == 'custom') {
      return localized('自定义路径');
    }
    return 'PATH';
  }

  Widget _toolGroup(String name, List<AiCliInstallation> items) => Card(
          child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LText(name, style: const TextStyle(fontWeight: FontWeight.bold)),
          if (items.isEmpty) const LText('此范围未发现 · 可补充目录或工具路径'),
          for (final item in items) ...[
            const SizedBox(height: 8),
            SelectableText(item.path),
            LText(item.packageVersion == null
                ? '版本未核验'
                : '安装包标注版本：${item.packageVersion}（未运行工具核验）'),
            LText('来源：${_sourceLabel(item.source)} · 已发现可执行文件'),
          ],
        ]),
      ));
}

class _DiscoverySettings extends StatefulWidget {
  const _DiscoverySettings({required this.initial});
  final AiCliScanRequest initial;
  @override
  State<_DiscoverySettings> createState() => _DiscoverySettingsState();
}

class _DiscoverySettingsState extends State<_DiscoverySettings> {
  late final _directories =
      TextEditingController(text: widget.initial.directories.join('\n'));
  late final _custom = TextEditingController(
      text: widget.initial.customTools
          .map((t) => '${t.name} | ${t.path}')
          .join('\n'));
  String? _error;
  @override
  void dispose() {
    _directories.dispose();
    _custom.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final dirs =
          _directories.text.split('\n').where((s) => s.isNotEmpty).toList();
      final tools = <AiCliCustomTool>[];
      for (final line in _custom.text.split('\n').where((s) => s.isNotEmpty)) {
        final index = line.indexOf('\t');
        // Permit a visible separator in touch keyboards that have no Tab key.
        final split = index >= 0 ? index : line.indexOf(' | ');
        if (split < 0) throw const FormatException('自定义工具格式：名称 | /绝对路径');
        tools.add(AiCliCustomTool(
            name: line.substring(0, split),
            path: line.substring(split + (index >= 0 ? 1 : 3))));
      }
      Navigator.pop(
          context, AiCliScanRequest(directories: dirs, customTools: tools));
    } on FormatException catch (e) {
      setState(() {
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const LText('补充检测范围'),
        content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              const LText('设置只保存在本机，按主机和 SSH 用户分开。每项最多 16 条；保存空白可清除补充项。'),
              TextField(
                  key: const ValueKey('ai-cli-directories'),
                  controller: _directories,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                      labelText: '补充目录（每行一个）',
                      hintText: '~/.nvm/versions/node/v22/bin')),
              TextField(
                  key: const ValueKey('ai-cli-custom'),
                  controller: _custom,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                      labelText: '自定义工具（名称 | 路径）',
                      hintText: 'Aider | ~/.local/bin/aider')),
              if (_error != null)
                LText(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
            ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const LText('取消')),
          FilledButton(
              key: const ValueKey('ai-cli-save-settings'),
              onPressed: _save,
              child: const LText('保存并检测'))
        ],
      );
}
