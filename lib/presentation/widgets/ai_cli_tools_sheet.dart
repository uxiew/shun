import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/connection_lifecycle.dart';
import '../../application/home_navigation.dart';
import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/ai_cli.dart';
import '../../domain/ai_cli_launch.dart';
import '../../domain/ai_cli_work.dart';
import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/tmux/ai_cli_tmux_run.dart';
import '../../domain/tmux/tmux_target.dart';
import '../../infrastructure/ssh/ai_cli_discovery.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../../infrastructure/storage/ai_cli_preferences.dart';
import '../../infrastructure/storage/ai_cli_recent_work.dart';
import '../../infrastructure/tmux/ai_cli_tmux_service.dart';
import '../../infrastructure/tmux/tmux_protocol.dart';
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
      this.recentWork = const SecureAiCliRecentWork(),
      this.sessionState,
      this.scan});
  final HostProfile host;
  final ActiveTerminalSession? session;
  final HostKeyVerifier? verifyHostKey;
  final KeyboardInteractiveHandler? keyboardInteractive;
  final AiCliDiscoveryService service;
  final AiCliPreferencesStore preferences;
  final AiCliRecentWorkStore recentWork;
  final SessionState? sessionState;
  final AiCliScan? scan;
  @override
  ConsumerState<AiCliToolsSheet> createState() => _AiCliToolsSheetState();
}

class _AiCliToolsSheetState extends ConsumerState<AiCliToolsSheet> {
  AiCliScanRequest _request = AiCliScanRequest();
  AiCliScanResult? _result;
  List<AiCliWorkItem> _recent = const [];
  final _tmuxGoneIds = <String>{};
  RoutePlan? _candidatePlan, _scannedPlan;
  AiCliProbeCancellation? _cancellation;
  ConnectionAttempt? _attempt;
  ConnectionAttempt? _launchAttempt;
  AiCliProbeCancellation? _launchProbe;
  String? _error;
  bool _loading = false, _settingsReady = false, _launching = false;
  String get _scope => aiCliHostScope(widget.host);
  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadRecent());
  }

  Future<void> _loadRecent() async {
    try {
      final items = await widget.recentWork.load(_scope);
      if (mounted) setState(() => _recent = items);
    } on Object {
      if (mounted) setState(() => _error = '无法读取最近工作记录');
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _cancel() {
    _cancellation?.cancel();
    _attempt?.cancel();
    _launchProbe?.cancel();
    _launchAttempt?.cancel();
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
    if (widget.scan != null) {
      _candidatePlan = widget.session?.routePlan;
      return widget.scan!(_request, cancellation);
    }
    final parent = widget.session;
    if (parent != null) {
      _candidatePlan = parent.routePlan;
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
    _candidatePlan = plan;
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
    if (_loading || _launching || !_settingsReady) return;
    _candidatePlan = null;
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
        _scannedPlan = _candidatePlan;
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
        _scannedPlan = null;
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

  Future<void> _launch(AiCliInstallation installation) async {
    if (_scannedPlan == null || _launching || _result == null) return;
    var directory = '~/';
    var useTmux = false;
    final chosen = await showDialog<({String directory, bool useTmux})>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, updateDialog) => AlertDialog(
                title: const LText('新建 AI 工具终端'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  LText('${installation.name} · ${installation.path}'),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('ai-cli-project-directory'),
                    initialValue: directory,
                    onChanged: (value) => directory = value,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '项目目录',
                      hintText: '~/project 或 /绝对路径',
                    ),
                  ),
                  const LText('会在新终端启动；普通 SSH 连接断开时工具可能结束。不会把命令发到现有终端。'),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: useTmux,
                    onChanged: (value) =>
                        updateDialog(() => useTmux = value ?? false),
                    title: const LText('保留在专属 tmux 会话'),
                    subtitle: const LText('远端需有 tmux；断线后可核对原窗格再返回'),
                  ),
                ])),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const LText('取消'),
                  ),
                  FilledButton(
                    key: const ValueKey('ai-cli-confirm-launch'),
                    onPressed: () => Navigator.pop(context,
                        (directory: directory.trim(), useTmux: useTmux)),
                    child: const LText('新建终端'),
                  ),
                ],
              )),
    );
    if (chosen == null || !mounted) return;
    final nativeId =
        installation.kind == AiCliKind.claude ? const Uuid().v4() : null;
    try {
      await _executeLaunch(
        AiCliLaunchSpec(
          executable: installation.path,
          projectDirectory: chosen.directory,
          arguments: nativeId == null ? const [] : ['--session-id', nativeId],
        ),
        name: installation.name,
        kind: installation.kind,
        nativeId: nativeId,
        record: true,
        useTmux: chosen.useTmux,
      );
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _resume(AiCliWorkItem item) async {
    final spec = item.exactResume() ?? item.historyPicker();
    if (spec == null) return;
    await _executeLaunch(
      spec,
      name: item.name,
      kind: item.tool,
      nativeId: item.claudeSessionId,
      record: true,
    );
  }

  Future<void> _launchFromRecent(AiCliWorkItem item) async {
    final nativeId = item.tool == AiCliKind.claude ? const Uuid().v4() : null;
    await _executeLaunch(
      AiCliLaunchSpec(
        executable: item.executable,
        projectDirectory: item.projectDirectory,
        arguments: nativeId == null ? const [] : ['--session-id', nativeId],
      ),
      name: item.name,
      kind: item.tool,
      nativeId: nativeId,
      record: true,
      useTmux: item.tmuxRun != null,
    );
  }

  Future<void> _returnTmux(AiCliWorkItem item) async {
    final run = item.tmuxRun;
    if (run == null || _launching) return;
    setState(() {
      _launching = true;
      _error = null;
    });
    try {
      final sessions = ref.read(sessionControllerProvider).sessions;
      final old = sessions
          .where((session) =>
              session.id == item.id &&
              session.connected &&
              session.aiTmuxRun?.sameAs(run) == true)
          .firstOrNull;
      if (old != null && old.sshClient != null && !old.sshClient!.isClosed) {
        final client = old.sshClient!;
        await const AiCliTmuxService().verify(client, run);
        if (!mounted) return;
        final index = ref.read(sessionControllerProvider).sessions.indexWhere(
            (session) =>
                identical(session, old) &&
                session.connected &&
                identical(session.sshClient, client));
        if (index >= 0) {
          await _rememberReturn(item);
          if (!mounted) return;
          ref.read(sessionControllerProvider.notifier).activate(index);
          ref.read(homeTabProvider.notifier).state = 1;
          Navigator.pop(context);
          return;
        }
      }
      final scanned = _scannedPlan;
      if (scanned == null) {
        throw const AiCliDiscoveryException('请先完成当前主机的工具检测');
      }
      final vault = await ref.read(vaultControllerProvider.notifier).ready();
      if (!mounted) return;
      final sourceId = sourceHostIdOf(widget.host);
      final current = vault.hosts.where((h) => h.id == sourceId).firstOrNull;
      if (current == null || aiCliHostScope(current) != _scope) {
        throw const AiCliDiscoveryException('主机身份已改变，请重新打开工具列表');
      }
      final now = resolveRoutePlan(current,
          hosts: vault.hosts,
          keys: vault.keys,
          proxyProfiles: vault.proxyProfiles);
      if (now.shape != scanned.shape ||
          run.target.hostKey != scanned.target.endpoint.authority) {
        throw const AiCliDiscoveryException('连接路线已改变，请重新检测工具');
      }
      final route = scanned.secretsForgotten
          ? rehydrateRoutePlan(scanned,
              sourceHostId: sourceId,
              hosts: vault.hosts,
              proxyProfiles: vault.proxyProfiles,
              keys: vault.keys)
          : scanned;
      final verifier = widget.verifyHostKey ??
          widget.session?.verifyHostKey ??
          ((_, __, ___) async => false);
      final attempt = ConnectionAttempt();
      _launchAttempt = attempt;
      await ref.read(sshServiceProvider).withVerifiedClient(
          routePlan: route,
          verifyHostKey: verifier,
          keyboardInteractive:
              widget.keyboardInteractive ?? widget.session?.keyboardInteractive,
          attempt: attempt,
          query: (client) => const AiCliTmuxService().verify(client, run));
      if (!mounted) return;
      String? openedTabId;
      final opened =
          await ref.read(sessionControllerProvider.notifier).openAiTmuxTerminal(
                requestId: const Uuid().v4(),
                host: current,
                routePlan: route,
                run: run,
                verifyHostKey: verifier,
                keyboardInteractive: widget.keyboardInteractive ??
                    widget.session?.keyboardInteractive,
                onOpened: (session) => openedTabId = session.id,
              );
      if (!mounted) return;
      if (opened && openedTabId != null) {
        final updated = AiCliWorkItem(
          id: openedTabId!,
          tool: item.tool,
          name: item.name,
          executable: item.executable,
          projectDirectory: item.projectDirectory,
          openedAt: DateTime.now(),
          claudeSessionId: item.claudeSessionId,
          tmuxRun: run,
        );
        await widget.recentWork.record(_scope, updated);
        if (!mounted) return;
        ref.read(homeTabProvider.notifier).state = 1;
        Navigator.pop(context);
      }
    } on TmuxTargetGoneException catch (error) {
      if (mounted) {
        setState(() {
          _tmuxGoneIds.add(item.id);
          _error = error.message;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = switch (error) {
              AiCliDiscoveryException(:final message) => message,
              TmuxCommandException(:final message) => message,
              _ => '无法返回原 AI tmux 窗格，请检查终端状态',
            });
      }
    } finally {
      _launchAttempt = null;
      if (mounted) setState(() => _launching = false);
    }
  }

  Future<void> _clearRecent() async {
    try {
      await widget.recentWork.clear(_scope);
      if (mounted) setState(() => _recent = const []);
    } on Object {
      if (mounted) setState(() => _error = '无法清除最近工作记录');
    }
  }

  Future<void> _rememberReturn(AiCliWorkItem item) async {
    try {
      await widget.recentWork.record(
        _scope,
        AiCliWorkItem(
          id: item.id,
          tool: item.tool,
          name: item.name,
          executable: item.executable,
          projectDirectory: item.projectDirectory,
          openedAt: DateTime.now(),
          claudeSessionId: item.claudeSessionId,
          tmuxRun: item.tmuxRun,
        ),
      );
    } on Object {
      // Returning to a verified live terminal still works if local storage is
      // unavailable; the previous pointer remains intact.
    }
  }

  Future<void> _returnLive(AiCliWorkItem item) async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      final index = ref.read(sessionControllerProvider).sessions.indexWhere(
          (session) =>
              session.id == item.id &&
              session.connected &&
              session.aiTerminalOriginal);
      if (index < 0) return;
      await _rememberReturn(item);
      if (!mounted) return;
      final stillLive = ref.read(sessionControllerProvider).sessions.indexWhere(
          (session) =>
              session.id == item.id &&
              session.connected &&
              session.aiTerminalOriginal);
      if (stillLive < 0) return;
      ref.read(sessionControllerProvider.notifier).activate(stillLive);
      ref.read(homeTabProvider.notifier).state = 1;
      Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  Widget _recentCard(AiCliWorkItem item) {
    final state = widget.sessionState ??
        ref.watch(sessionControllerProvider) ??
        const SessionState();
    final liveIndex = state.sessions.indexWhere((session) =>
        session.id == item.id &&
        session.connected &&
        session.aiTerminalOriginal);
    final tmux = item.tmuxRun != null && !_tmuxGoneIds.contains(item.id);
    final liveTmux = state.sessions.any((session) =>
        session.id == item.id &&
        session.connected &&
        item.tmuxRun != null &&
        session.aiTmuxRun?.sameAs(item.tmuxRun!) == true);
    final exact = item.exactResume() != null;
    final picker = item.historyPicker() != null;
    final label = liveIndex >= 0
        ? '返回原终端'
        : tmux
            ? '核对并返回 tmux'
            : exact
                ? '按会话 ID 继续'
                : picker
                    ? '选择 Codex 历史'
                    : '仅可重新新建';
    return Card(
      child: ListTile(
        title: LText('${item.name} · ${item.projectDirectory}'),
        subtitle: LText(liveIndex >= 0
            ? '原终端仍连接；工具状态请在终端确认'
            : tmux
                ? '将核对原 session、窗口、窗格和进程，再返回终端'
                : exact
                    ? 'Claude 会话 ID 已记录；远端会话存在性待工具核验'
                    : picker
                        ? 'Codex 未取得确切会话 ID，需在工具中选择'
                        : '没有可核验的继续目标'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              key: ValueKey('ai-cli-recent-${item.id}'),
              onPressed: _launching
                  ? null
                  : liveIndex >= 0
                      ? () => _returnLive(item)
                      : tmux && (_scannedPlan != null || liveTmux)
                          ? () => _returnTmux(item)
                          : _scannedPlan != null && (exact || picker)
                              ? () => _resume(item)
                              : null,
              child: LText(label),
            ),
            IconButton(
              key: ValueKey('ai-cli-new-from-recent-${item.id}'),
              tooltip: localized('同项目新建'),
              onPressed: _launching || _scannedPlan == null
                  ? null
                  : () => _launchFromRecent(item),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _executeLaunch(
    AiCliLaunchSpec launch, {
    required String name,
    required AiCliKind kind,
    required String? nativeId,
    required bool record,
    bool useTmux = false,
  }) async {
    final scanned = _scannedPlan;
    if (scanned == null || _launching) return;
    final requestId = const Uuid().v4();
    var tmuxCreateAttempted = false;
    setState(() {
      _launching = true;
      _error = null;
    });
    try {
      final vault = await ref.read(vaultControllerProvider.notifier).ready();
      if (!mounted) return;
      final sourceId = sourceHostIdOf(widget.host);
      final current = vault.hosts.where((h) => h.id == sourceId).firstOrNull;
      if (current == null || aiCliHostScope(current) != _scope) {
        throw const AiCliDiscoveryException('主机身份已改变，请重新打开工具列表');
      }
      final now = resolveRoutePlan(current,
          hosts: vault.hosts,
          keys: vault.keys,
          proxyProfiles: vault.proxyProfiles);
      if (now.shape != scanned.shape) {
        throw const AiCliDiscoveryException('连接路线已改变，请重新检测工具');
      }
      final route = scanned.secretsForgotten
          ? rehydrateRoutePlan(scanned,
              sourceHostId: sourceId,
              hosts: vault.hosts,
              proxyProfiles: vault.proxyProfiles,
              keys: vault.keys)
          : scanned;
      final verifier = widget.verifyHostKey ??
          widget.session?.verifyHostKey ??
          ((_, __, ___) async => false);
      final attempt = ConnectionAttempt();
      final probe = AiCliProbeCancellation();
      _launchAttempt = attempt;
      _launchProbe = probe;
      final actualProject =
          await ref.read(sshServiceProvider).withVerifiedClient(
                routePlan: route,
                verifyHostKey: verifier,
                keyboardInteractive: widget.keyboardInteractive ??
                    widget.session?.keyboardInteractive,
                attempt: attempt,
                query: (client) =>
                    widget.service.canonicalProject(client, launch, probe),
              );
      if (!mounted) return;
      final checkedLaunch = AiCliLaunchSpec(
          executable: launch.executable,
          projectDirectory: actualProject,
          arguments: launch.arguments);
      String? openedTabId;
      AiCliTmuxRun? run;
      if (useTmux) {
        final createAttempt = ConnectionAttempt();
        _launchAttempt = createAttempt;
        run = await ref.read(sshServiceProvider).withVerifiedClientForAiTmux(
              routePlan: route,
              verifyHostKey: verifier,
              keyboardInteractive: widget.keyboardInteractive ??
                  widget.session?.keyboardInteractive,
              attempt: createAttempt,
              action: (client) => const AiCliTmuxService().start(
                client,
                hostKey: route.target.endpoint.authority,
                socket: const TmuxSocketSpec.standard(),
                requestId: requestId,
                launch: checkedLaunch,
                onCreateAttempted: () => tmuxCreateAttempted = true,
              ),
            );
        if (!mounted) return;
      }
      final opened = useTmux
          ? await ref
              .read(sessionControllerProvider.notifier)
              .openAiTmuxTerminal(
                requestId: requestId,
                host: current,
                routePlan: route,
                run: run!,
                onOpened: (session) => openedTabId = session.id,
                verifyHostKey: verifier,
                keyboardInteractive: widget.keyboardInteractive ??
                    widget.session?.keyboardInteractive,
              )
          : await ref
              .read(sessionControllerProvider.notifier)
              .openAiCliTerminal(
                requestId: requestId,
                host: current,
                routePlan: route,
                label: '$name · $actualProject',
                launch: checkedLaunch,
                onOpened: (session) => openedTabId = session.id,
                verifyHostKey: verifier,
                keyboardInteractive: widget.keyboardInteractive ??
                    widget.session?.keyboardInteractive,
              );
      if (!mounted) return;
      if (opened) {
        if (record && openedTabId != null) {
          final item = AiCliWorkItem(
            id: openedTabId!,
            tool: kind,
            name: name,
            executable: checkedLaunch.executable,
            projectDirectory: actualProject,
            openedAt: DateTime.now(),
            claudeSessionId: nativeId,
            tmuxRun: run,
          );
          try {
            await widget.recentWork.record(_scope, item);
            if (mounted) setState(() => _recent = [item, ..._recent]);
          } on Object {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: LText('终端已打开，但最近工作未能保存')));
            }
          }
        }
        if (!mounted) return;
        ref.read(homeTabProvider.notifier).state = 1;
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        final tmuxUnknown = localized('tmux 创建或启动结果未知。请先核查远端会话名，再决定是否新建。');
        setState(() {
          _error = tmuxCreateAttempted
              ? [tmuxUnknown, 'shun-ai-$requestId'].join('\n')
              : switch (error) {
                  AiCliLaunchUnknownException() => error.toString(),
                  AiCliDiscoveryException(:final message) => message,
                  TmuxCommandException(:final message) => message,
                  FormatException(:final message) => message,
                  _ => '启动未完成，请检查终端页的连接状态',
                };
        });
      }
    } finally {
      _launchAttempt = null;
      _launchProbe = null;
      if (mounted) setState(() => _launching = false);
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
          if (_recent.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(children: [
              const Expanded(
                  child: LText('最近工作（仅本机）',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              TextButton(
                  onPressed: _launching ? null : _clearRecent,
                  child: const LText('清除最近工作')),
            ]),
            for (final item in _recent.take(5)) _recentCard(item),
          ],
          Wrap(spacing: 8, children: [
            TextButton.icon(
                key: const ValueKey('ai-cli-refresh'),
                onPressed:
                    _loading || _launching || !_settingsReady ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const LText('重新检测')),
            TextButton.icon(
                key: const ValueKey('ai-cli-settings'),
                onPressed: _loading || _launching ? null : _settings,
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
          if (_launching) const LinearProgressIndicator(),
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
            const LText(
                '可在新终端启动，或选择专属 tmux 保留远端进程；Claude 支持按记录的 ID 尝试继续，Codex 可选择历史。实际登录和继续结果以工具显示为准。'),
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
            if (_scannedPlan != null)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  key: ValueKey('ai-cli-launch-${item.path}'),
                  onPressed:
                      _launching || _loading ? null : () => _launch(item),
                  child: const LText('新建终端'),
                ),
              ),
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
