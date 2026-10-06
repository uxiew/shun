import 'dart:async';

import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/connection_diagnosis.dart';
import '../../application/fork_features.dart';
import '../../application/session_controller.dart';
import '../../application/home_navigation.dart';
import '../../application/settings_controller.dart';
import '../../application/terminal_engine.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../domain/models/settings.dart';
import '../../domain/route_description.dart';
import '../../infrastructure/ai/ai_service.dart';
import '../widgets/ai_panel.dart';
import '../widgets/ai_providers_page.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../../infrastructure/ssh/terminal_picture_in_picture_service.dart';
import '../../infrastructure/terminal/terminal_session_adapter.dart';
import '../../infrastructure/terminal/terminal_text.dart';
import '../../infrastructure/storage/vault_repository.dart';
import '../widgets/empty_state.dart';
import '../widgets/custom_background.dart';
import '../widgets/ai_chat_sheet.dart';
import '../widgets/host_system_icon.dart';
import '../widgets/port_forward_sheet.dart';
import '../widgets/route_legs_view.dart';
import '../widgets/server_monitor_sheet.dart';
import '../widgets/terminal_special_keys.dart';
import '../widgets/system_management/system_management_sheet.dart';
import '../widgets/tailscale_check_card.dart';
import '../terminal/terminal_view.dart';

part 'terminal_screen_pane.dart';

final terminalFullscreenProvider = StateProvider<bool>((ref) => false);
final terminalPictureInPictureProvider = StateProvider<bool>((ref) => false);

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

/// 终端页的高度（键盘弹出后剩下的）低于这个就把快捷键栏收成一行（TER05、TER06）。
/// 竖屏弹着键盘的普通手机（914dp 高、键盘 336dp）剩 550dp，不收；横屏 411dp 高，收。
const _compactTerminalHeight = 480.0;

/// 低于这个连标签条也收起来，只留终端和一行快捷键：横屏弹键盘时只剩 120dp 左右，
/// 标签条 52dp 加两行快捷键会把终端挤成 0 行，远端还停在旧尺寸（R17 发现的问题 1）。
const _tightTerminalHeight = 260.0;

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  var _split = false;

  /// 分屏时用户点过、正拿着焦点的那一格。快捷键栏的键和修饰键发给它，不是固定发给当前标签；
  /// 不然在第二格打字、在快捷键栏按 Ctrl，Ctrl 会挂到第一格上（TER05「不将输入送往错误标签」）。
  String? _inputSessionId;
  StreamSubscription<bool>? _pictureInPictureSubscription;

  @override
  void initState() {
    super.initState();
    _pictureInPictureSubscription =
        TerminalPictureInPictureService.stateChanges.listen((active) {
      if (!mounted) return;
      ref.read(terminalPictureInPictureProvider.notifier).state = active;
    });
  }

  @override
  void dispose() {
    _pictureInPictureSubscription?.cancel();
    super.dispose();
  }

  /// 输入换了一格：上一格快捷键栏挂着的修饰键清掉，免得回去时第一个字成了控制键（TER04）。
  /// 切标签也走这里：新标签的终端一挂上就自动拿焦点。
  void _focusPane(String sessionId) {
    if (_inputSessionId == sessionId) return;
    _sessionById(_inputSessionId)?.terminal.input.clearModifiers();
    setState(() => _inputSessionId = sessionId);
  }

  ActiveTerminalSession? _sessionById(String? id) => id == null
      ? null
      : ref
          .read(sessionControllerProvider)
          .sessions
          .where((session) => session.id == id)
          .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionControllerProvider);
    final settings = ref.watch(settingsControllerProvider);
    final snippets =
        ref.watch(vaultControllerProvider).data?.snippets ?? const [];
    final selectedPending = state.selectedPending;
    final visibleSession = selectedPending == null ? state.active : null;
    final fullscreen = ref.watch(terminalFullscreenProvider);
    final pictureInPicture = ref.watch(terminalPictureInPictureProvider);
    final customBackground = hasCustomBackground(settings);
    if ((fullscreen || pictureInPicture) && visibleSession == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(terminalFullscreenProvider)) {
          ref.read(terminalFullscreenProvider.notifier).state = false;
        }
        if (ref.read(terminalPictureInPictureProvider)) {
          ref.read(terminalPictureInPictureProvider.notifier).state = false;
          unawaited(TerminalPictureInPictureService.stop());
        }
      });
    }
    final tabHosts = [
      ...state.sessions.map((value) => value.host),
      ...state.pendingConnections.map((value) => value.host),
    ];
    final splitShown =
        _split && !pictureInPicture && state.sessions.length >= 2;
    final paneIds = visibleSession == null
        ? const <String>{}
        : {
            visibleSession.id,
            if (splitShown)
              state
                  .sessions[(state.activeIndex + 1) % state.sessions.length].id,
          };
    final inputSession = visibleSession == null
        ? null
        : state.sessions
                .where(
                  (session) =>
                      session.id == _inputSessionId &&
                      paneIds.contains(session.id),
                )
                .firstOrNull ??
            visibleSession;
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => _buildPage(
          context,
          state: state,
          settings: settings,
          snippets: snippets,
          selectedPending: selectedPending,
          visibleSession: visibleSession,
          inputSession: inputSession,
          splitShown: splitShown,
          fullscreen: fullscreen,
          pictureInPicture: pictureInPicture,
          customBackground: customBackground,
          tabHosts: tabHosts,
          compact: constraints.maxHeight < _compactTerminalHeight,
          tight: constraints.maxHeight < _tightTerminalHeight,
        ),
      ),
    );
  }

  Widget _buildPage(
    BuildContext context, {
    required SessionState state,
    required AppSettings settings,
    required List<CommandSnippet> snippets,
    required PendingTerminalConnection? selectedPending,
    required ActiveTerminalSession? visibleSession,
    required ActiveTerminalSession? inputSession,
    required bool splitShown,
    required bool fullscreen,
    required bool pictureInPicture,
    required bool customBackground,
    required List<HostProfile> tabHosts,
    required bool compact,
    required bool tight,
  }) {
    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            children: [
              if (!fullscreen && !pictureInPicture && !tight)
                SizedBox(
                  key: const ValueKey('terminal-tab-strip'),
                  height: 52,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(
                        Icons.terminal,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: state.tabCount == 0
                            ? const LText('终端')
                            : ReorderableListView.builder(
                                scrollDirection: Axis.horizontal,
                                buildDefaultDragHandles: false,
                                itemCount: state.tabCount,
                                onReorderItem: ref
                                    .read(
                                      sessionControllerProvider.notifier,
                                    )
                                    .reorderSessionTab,
                                itemBuilder: (_, index) {
                                  final host = tabHosts[index];
                                  final occurrence = tabHosts
                                      .take(index + 1)
                                      .where((value) => value.id == host.id)
                                      .length;
                                  final duplicateCount = tabHosts
                                      .where((value) => value.id == host.id)
                                      .length;
                                  if (index >= state.sessions.length) {
                                    final pending = state.pendingConnections[
                                        index - state.sessions.length];
                                    final failed = pending.phase ==
                                        PendingConnectionPhase.failed;
                                    return Padding(
                                      key: ValueKey(
                                        'pending-terminal-tab-${pending.id}',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 2,
                                        horizontal: 2,
                                      ),
                                      child: InputChip(
                                        // 看着 38dp，能点的是 48dp（UX02）。
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.padded,
                                        selected:
                                            state.activePendingId == pending.id,
                                        showCheckmark: false,
                                        avatar: failed
                                            ? const Icon(
                                                Icons.error_outline,
                                                size: 17,
                                                color: Colors.redAccent,
                                              )
                                            : const SizedBox.square(
                                                dimension: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                ),
                                              ),
                                        label: LText(
                                          duplicateCount > 1
                                              ? '${host.label} #$occurrence'
                                              : host.label,
                                        ),
                                        onPressed: () => ref
                                            .read(
                                              sessionControllerProvider
                                                  .notifier,
                                            )
                                            .activate(index),
                                        onDeleted: failed
                                            ? () => ref
                                                .read(
                                                  sessionControllerProvider
                                                      .notifier,
                                                )
                                                .dismissPending(pending.id)
                                            : null,
                                      ),
                                    );
                                  }
                                  final session = state.sessions[index];
                                  return ReorderableDelayedDragStartListener(
                                    key: ValueKey(
                                      'terminal-tab-${session.id}',
                                    ),
                                    index: index,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 2,
                                        horizontal: 2,
                                      ),
                                      child: InputChip(
                                        // 看着 38dp，能点的是 48dp（UX02）。
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.padded,
                                        selected: state.activeIndex == index,
                                        showCheckmark: false,
                                        avatar: Icon(
                                          session.connected
                                              ? Icons.circle
                                              : Icons.error_outline,
                                          size: session.connected ? 10 : 16,
                                          color: session.connected
                                              ? Colors.greenAccent
                                              : Colors.orangeAccent,
                                        ),
                                        // 默认引擎不标；用设置里选的实验引擎开的标签标出来，
                                        // 改了设置以后哪个标签用的是哪个引擎一眼能看出来。
                                        label: LText(
                                          '${duplicateCount > 1 ? '${session.host.label} #$occurrence' : session.host.label}'
                                          '${session.terminal.engine == defaultTerminalEngineName ? '' : ' · ${session.terminal.engine}'}',
                                        ),
                                        onPressed: () => ref
                                            .read(
                                              sessionControllerProvider
                                                  .notifier,
                                            )
                                            .activate(index),
                                        onDeleted: () =>
                                            _confirmClose(index, session),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      if (visibleSession != null)
                        IconButton(
                          key: const ValueKey(
                            'terminal-performance-monitor',
                          ),
                          tooltip: localized('性能监控'),
                          onPressed: visibleSession.isSsh
                              ? () => _openPerformanceMonitor(visibleSession)
                              : null,
                          icon: const Icon(Icons.monitor_heart_outlined),
                        ),
                    ],
                  ),
                ),
              if (pictureInPicture && visibleSession != null)
                _TerminalPictureInPictureHeader(session: visibleSession),
              Expanded(
                child: selectedPending != null
                    ? _ConnectionStatusPane(
                        pending: selectedPending,
                        onReturn: state.sessions.isEmpty
                            ? null
                            : () => ref
                                .read(sessionControllerProvider.notifier)
                                .activate(state.activeIndex),
                        onClose: selectedPending.phase ==
                                PendingConnectionPhase.failed
                            ? () => ref
                                .read(sessionControllerProvider.notifier)
                                .dismissPending(selectedPending.id)
                            : null,
                        onCancel: selectedPending.phase ==
                                PendingConnectionPhase.connecting
                            ? () => ref
                                .read(sessionControllerProvider.notifier)
                                .cancelPendingConnection(selectedPending.id)
                            : null,
                      )
                    : state.sessions.isEmpty
                        ? const EmptyState(
                            icon: Icons.terminal_outlined,
                            title: '没有活动会话',
                            subtitle: '从“保险库”选择主机开始连接。',
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              if (pictureInPicture ||
                                  !_split ||
                                  state.sessions.length < 2) {
                                return _TerminalPane(
                                  key: ValueKey(state.active!.id),
                                  session: state.active!,
                                  fontSize: settings.terminalFontSize,
                                  secureKeyboard:
                                      settings.terminalSecureKeyboard,
                                  pictureInPicture: pictureInPicture,
                                  transparentBackground:
                                      customBackground && !pictureInPicture,
                                  onFocused: _focusPane,
                                );
                              }
                              final secondIndex = (state.activeIndex + 1) %
                                  state.sessions.length;
                              final children = [
                                Expanded(
                                  child: _TerminalPane(
                                    key: ValueKey(state.active!.id),
                                    session: state.active!,
                                    fontSize: settings.terminalFontSize,
                                    secureKeyboard:
                                        settings.terminalSecureKeyboard,
                                    pictureInPicture: false,
                                    transparentBackground: customBackground,
                                    onFocused: _focusPane,
                                    inputTarget:
                                        inputSession?.id == state.active!.id,
                                  ),
                                ),
                                const Divider(height: 1, thickness: 1),
                                Expanded(
                                  child: _TerminalPane(
                                    key: ValueKey(
                                        state.sessions[secondIndex].id),
                                    session: state.sessions[secondIndex],
                                    fontSize: settings.terminalFontSize,
                                    secureKeyboard:
                                        settings.terminalSecureKeyboard,
                                    pictureInPicture: false,
                                    transparentBackground: customBackground,
                                    onFocused: _focusPane,
                                    inputTarget: inputSession?.id ==
                                        state.sessions[secondIndex].id,
                                  ),
                                ),
                              ];
                              return constraints.maxWidth >
                                      constraints.maxHeight
                                  ? Row(children: children)
                                  : Column(children: children);
                            },
                          ),
              ),
              if (visibleSession != null &&
                  inputSession != null &&
                  !pictureInPicture)
                TerminalSpecialKeys(
                  order: settings.terminalQuickKeys,
                  customKeys: settings.terminalCustomKeys,
                  inputController: inputSession.input,
                  onSend: (text, {bool enter = false}) => ref
                      .read(sessionControllerProvider.notifier)
                      .typeInto(inputSession.id, enter ? '$text\r' : text),
                  onKey: (key) => ref
                      .read(sessionControllerProvider.notifier)
                      .pressKey(inputSession.id, key),
                  compact: compact,
                  onAi: ref.watch(forkFeaturesProvider).ai
                      ? () => _openAi(visibleSession)
                      : null,
                  onPortForward: visibleSession.isSsh
                      ? () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) =>
                                PortForwardSheet(session: visibleSession),
                          )
                      : null,
                  onSystemManagement: visibleSession.isSsh
                      ? () => showModalBottomSheet<void>(
                            context: context,
                            useSafeArea: true,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (_) => SystemManagementSheet(
                              session: visibleSession,
                              snippets: snippets,
                              onOpenTerminal: (label, command) =>
                                  _openManagedTerminal(
                                visibleSession,
                                label,
                                command,
                              ),
                              onOpenSftp: (filePath) {
                                ref
                                    .read(
                                        sftpNavigationRequestProvider.notifier)
                                    .state = SftpNavigationRequest(
                                  sessionId: visibleSession.id,
                                  filePath: filePath,
                                );
                                ref.read(homeTabProvider.notifier).state = 2;
                              },
                            ),
                          )
                      : null,
                  pictureInPicture: pictureInPicture,
                  onPictureInPicture: () =>
                      _togglePictureInPicture(visibleSession),
                  fullscreen: fullscreen,
                  onFullscreen: () => ref
                      .read(terminalFullscreenProvider.notifier)
                      .state = !fullscreen,
                  split: _split,
                  onSplit: state.sessions.length > 1
                      ? () => setState(() => _split = !_split)
                      : null,
                  transparentBackground: customBackground,
                ),
            ],
          ),
        ),
        if (fullscreen && !pictureInPicture && visibleSession != null)
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              key: const ValueKey('terminal-floating-performance'),
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: .82),
              elevation: 2,
              shape: const CircleBorder(),
              child: IconButton(
                key: const ValueKey('terminal-performance-monitor'),
                tooltip: localized('性能监控'),
                onPressed: visibleSession.isSsh
                    ? () => _openPerformanceMonitor(visibleSession)
                    : null,
                icon: const Icon(Icons.monitor_heart_outlined),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _togglePictureInPicture(
    ActiveTerminalSession session,
  ) async {
    if (ref.read(terminalPictureInPictureProvider)) {
      await TerminalPictureInPictureService.stop();
      return;
    }
    final supported = await TerminalPictureInPictureService.isSupported();
    if (!supported) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LText('当前设备或系统版本不支持终端画中画')),
      );
      return;
    }
    ref.read(terminalPictureInPictureProvider.notifier).state = true;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final entered = await TerminalPictureInPictureService.enter(
      title: session.host.label,
      text: terminalPictureInPictureText(session.terminal),
      connected: session.connected,
      backgroundColor: scheme.surface.toARGB32(),
      foregroundColor: scheme.onSurface.toARGB32(),
      accentColor: scheme.primary.toARGB32(),
    );
    if (entered || !mounted) return;
    ref.read(terminalPictureInPictureProvider.notifier).state = false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: LText('画中画初始化失败，请稍后重试')),
    );
  }

  void _openPerformanceMonitor(ActiveTerminalSession session) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => ServerMonitorSheet(session: session),
    );
  }

  Future<void> _confirmClose(
    int index,
    ActiveTerminalSession session,
  ) async {
    final close = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.warning_amber_outlined),
            title: const LText('关闭 SSH 标签页？'),
            // 不承诺普通 shell 里的程序还活着（TMX08）：断开时它们通常会收到挂断信号一起结束；
            // tmux 标签只是分离客户端，会话和里面的程序还在。
            content: LText(
              switch (session.tmux) {
                final tmux? => '只分离这个标签的 tmux 客户端：tmux 会话 '
                    '${tmux.target.displayName}（${tmux.target.sessionId}）和里面的程序留在远端，'
                    '不发送 Ctrl-C，也不结束会话。',
                null => '将断开 ${session.host.label} '
                    '(${session.host.username}@${session.host.hostname}) 的当前会话。'
                    '没在 tmux 之类工具里运行的程序，通常会随连接一起结束。',
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const LText('断开并关闭'),
              ),
            ],
          ),
        ) ??
        false;
    if (!close || !mounted) return;
    await ref.read(sessionControllerProvider.notifier).close(index);
  }

  Future<void> _openManagedTerminal(
    ActiveTerminalSession parent,
    String label,
    String command,
  ) async {
    try {
      await ref.read(sessionControllerProvider.notifier).openManagedTerminal(
            parent,
            label: label,
            command: command,
          );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LText('无法打开 $label：$error')),
      );
    }
  }

  bool _openingAi = false;

  Future<void> _openAi(ActiveTerminalSession session) async {
    if (_openingAi) return;
    _openingAi = true;
    // Chat needs its own idle/connect timeouts; the shared sync HTTP client
    // intentionally imposes a shorter header timeout.
    final service = AiService();
    try {
      final repository = ref.read(vaultRepositoryProvider);
      final settings = await repository.loadSettings();
      final apiKey = await repository.readAiApiKey() ?? '';
      final workspace = repository.aiWorkspace;
      if (!mounted || !await confirmAiRisk(context, workspace)) return;
      await workspace.migrateLegacyProvider(settings, apiKey);
      var profiles = await workspace.profiles();
      if (profiles.isEmpty) {
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => AiProvidersPage(workspace: workspace)));
        profiles = await workspace.profiles();
        if (profiles.isEmpty) return;
      }
      final savedProfile = await workspace.activeProfile();
      final activeProfile = profiles.any((p) => p.id == savedProfile)
          ? savedProfile
          : profiles.first.id;
      final preferredModel = activeProfile == null
          ? null
          : await workspace.preferredModel(activeProfile);
      final remember = await workspace.remembersHistory(session.host.id);
      final history = await workspace.conversation(session.host.id);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        enableDrag: false,
        builder: (context) => ResizableAiPanel(
          builder: (onResize) => AiChatSheet(
            onResize: onResize,
            handleKeyboardInsets: false,
            host: session.host,
            settings: settings,
            apiKey: apiKey,
            service: service,
            initialMessages: remember ? history.messages : const [],
            initialSummary: remember ? history.summary : '',
            workspace: workspace,
            profiles: profiles,
            initialProfileId: activeProfile,
            initialProfileModel: preferredModel,
            rememberHistory: remember,
            onMessagesChanged: (_) {},
            onTerminalContextChanged: (enabled) async {
              final current = await repository.loadSettings();
              await ref
                  .read(settingsControllerProvider.notifier)
                  .update(current.copyWith(aiIncludeTerminalContext: enabled));
            },
            terminalContext: () => terminalAiContextText(session.terminal),
            onModelChanged: (model) async {
              final current = await repository.loadSettings();
              await ref.read(settingsControllerProvider.notifier).update(
                    current.copyWith(aiModel: model),
                  );
            },
            onReasoningEffortChanged: (effort) async {
              final current = await repository.loadSettings();
              await ref.read(settingsControllerProvider.notifier).update(
                    current.copyWith(aiReasoningEffort: effort),
                  );
            },
            onCommand: (command, execute) async {
              ref.read(sessionControllerProvider.notifier).sendToSession(
                    session.id,
                    command,
                    enter: execute,
                  );
            },
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: LText('$error')));
      }
    } finally {
      service.close();
      _openingAi = false;
    }
  }
}
