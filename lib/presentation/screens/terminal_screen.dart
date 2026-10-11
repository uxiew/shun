import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/connection_diagnosis.dart';
import '../../application/fork_features.dart';
import '../../application/session_controller.dart';
import '../../application/home_navigation.dart';
import '../../application/settings_controller.dart';
import '../../application/terminal_compose.dart';
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
import '../widgets/connection_prompts.dart';
import '../widgets/host_address_line.dart';
import '../widgets/host_system_icon.dart';
import '../widgets/port_forward_sheet.dart';
import '../widgets/route_legs_view.dart';
import '../widgets/server_monitor_sheet.dart';
import '../widgets/terminal_input_panel.dart';
import '../widgets/terminal_key_button.dart';
import '../widgets/terminal_paste_sheet.dart';
import '../widgets/terminal_special_keys.dart';
import '../widgets/system_management/system_management_sheet.dart';
import '../widgets/tailscale_check_card.dart';
import '../terminal/terminal_view.dart';

part 'terminal_screen_input.dart';
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

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with _TerminalInputHost {
  var _split = false;

  /// 分屏时用户点过、正拿着焦点的那一格。快捷键栏的键和修饰键发给它，不是固定发给当前标签；
  /// 不然在第二格打字、在快捷键栏按 Ctrl，Ctrl 会挂到第一格上（TER05「不将输入送往错误标签」）。
  String? _inputSessionId;
  StreamSubscription<bool>? _pictureInPictureSubscription;

  @override
  void initState() {
    super.initState();
    initInputHost();
    _pictureInPictureSubscription =
        TerminalPictureInPictureService.stateChanges.listen((active) {
      if (!mounted) return;
      ref.read(terminalPictureInPictureProvider.notifier).state = active;
    });
  }

  @override
  void dispose() {
    _pictureInPictureSubscription?.cancel();
    disposeInputHost();
    super.dispose();
  }

  /// 输入换了一格：上一格快捷键栏挂着的修饰键清掉，免得回去时第一个字成了控制键（TER04）。
  /// 切标签也走这里：新标签的终端一挂上就自动拿焦点。
  void _focusPane(String sessionId) {
    if (_inputSessionId == sessionId) return;
    _sessionById(_inputSessionId)?.terminal.input.clearModifiers();
    setState(() => _inputSessionId = sessionId);
  }

  /// 硬件键盘在某一格里按了粘贴快捷键：发给那一格，走和快捷键栏一样的预览（R19）。
  void _pasteInto(ActiveTerminalSession session) =>
      unawaited(pasteClipboardInto(context, ref, session));

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
    // 关掉的标签留下的大输入框草稿挪到一边，不跟着标签丢（R25）。
    ref.listen(sessionControllerProvider, (_, next) {
      _drafts.forgetClosedTabs(next.sessions.map((session) => session.id));
    });
    _visibleTerminals = [
      for (final session in state.sessions)
        if (paneIds.contains(session.id)) session.terminal,
    ];
    final mode = _inputModeOf(settings);
    final panelVisible = mode != terminalInputSystem &&
        _panelOpen &&
        inputSession != null &&
        !pictureInPicture;
    final terminalTab = ref.watch(homeTabProvider) == 1;
    return PopScope(
      // 面板开着时返回键先把面板收起来，和收系统键盘一样（只在终端这一页上管）。
      canPop: !(panelVisible && terminalTab),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && panelVisible && terminalTab) _hideInput();
      },
      child: SafeArea(
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
            inputMode: mode,
            panelVisible: panelVisible,
            layout: _measureInput(
              context,
              constraints,
              panelVisible: panelVisible,
              fullscreen: fullscreen,
            ),
          ),
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
    required String inputMode,
    required bool panelVisible,
    required _InputLayout layout,
  }) {
    final tight = layout.tight;
    // 用按键面板、大输入框时点终端不叫系统键盘；从面板换回系统键盘那一下让输入那一格叫出键盘。
    final softKeyboard = inputMode == terminalInputSystem;
    int keyboardRequestFor(ActiveTerminalSession session) =>
        _keyboardRequest?.sessionId == session.id
            ? _keyboardRequest!.serial
            : 0;
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
                                        // 插件主机的标签标出插件名（X12）：一眼看出这个标签由哪个插件承载。
                                        label: LText(
                                          '${duplicateCount > 1 ? '${session.host.label} #$occurrence' : session.host.label}'
                                          '${session.host.protocol == HostProtocol.plugin && session.plugin != null ? ' · ${session.plugin!.protocol}' : ''}'
                                          '${session.terminal.engine == terminalEngineName ? '' : ' · ${session.terminal.engine}'}',
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
              // 带 key：上面的标签条、下面的快捷键栏和面板会随布局出现、消失，同一帧里头尾都变时，
              // 不带 key 的子组件会被当成新的重建，终端视图重新挂上、自己拿焦点，把刚收起的键盘又叫出来
              //（模拟器横屏收键盘时撞上）。
              Expanded(
                key: const ValueKey('terminal-area'),
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
                                  fullscreenSwipe:
                                      settings.terminalFullscreenSwipe,
                                  softKeyboard: softKeyboard,
                                  keyboardRequest:
                                      keyboardRequestFor(state.active!),
                                  pictureInPicture: pictureInPicture,
                                  transparentBackground:
                                      customBackground && !pictureInPicture,
                                  onFocused: _focusPane,
                                  onPaste: _pasteInto,
                                  onTap: _onTerminalTap,
                                  banner: pictureInPicture
                                      ? null
                                      : _connectionBanner(state.active!, state),
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
                                    fullscreenSwipe:
                                        settings.terminalFullscreenSwipe,
                                    softKeyboard: softKeyboard,
                                    keyboardRequest:
                                        keyboardRequestFor(state.active!),
                                    pictureInPicture: false,
                                    transparentBackground: customBackground,
                                    onFocused: _focusPane,
                                    onPaste: _pasteInto,
                                    onTap: _onTerminalTap,
                                    inputTarget:
                                        inputSession?.id == state.active!.id,
                                    banner:
                                        _connectionBanner(state.active!, state),
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
                                    fullscreenSwipe:
                                        settings.terminalFullscreenSwipe,
                                    softKeyboard: softKeyboard,
                                    keyboardRequest: keyboardRequestFor(
                                        state.sessions[secondIndex]),
                                    pictureInPicture: false,
                                    transparentBackground: customBackground,
                                    onFocused: _focusPane,
                                    onPaste: _pasteInto,
                                    onTap: _onTerminalTap,
                                    inputTarget: inputSession?.id ==
                                        state.sessions[secondIndex].id,
                                    banner: _connectionBanner(
                                        state.sessions[secondIndex], state),
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
                  !pictureInPicture &&
                  !layout.hideQuickBar)
                TerminalSpecialKeys(
                  key: const ValueKey('terminal-quick-keys'),
                  order: settings.terminalQuickKeys,
                  customKeys: settings.terminalCustomKeys,
                  inputController: inputSession.input,
                  onSend: (text, {bool enter = false}) => ref
                      .read(sessionControllerProvider.notifier)
                      .typeInto(inputSession.id, enter ? '$text\r' : text),
                  onKey: (key) => ref
                      .read(sessionControllerProvider.notifier)
                      .pressKey(inputSession.id, key),
                  onPaste: () => pasteClipboardInto(context, ref, inputSession),
                  onCompose: () =>
                      showTerminalPasteSheet(context, target: inputSession),
                  compact: layout.compact,
                  inputPanel: panelVisible,
                  onInputPanel: () => _toggleInputPanel(inputSession),
                  onHideKeyboard: _hideInput,
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
              if (panelVisible && inputSession != null)
                SizedBox(
                  key: const ValueKey('terminal-input-panel-area'),
                  height: layout.panelHeight,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      minHeight: layout.panelLayoutHeight,
                      maxHeight: layout.panelLayoutHeight,
                      child: TerminalInputPanel(
                        session: inputSession,
                        mode: inputMode,
                        onModeChanged: _onPanelModeChanged,
                        keyActions: TerminalKeyActions(
                          input: inputSession.input,
                          onKey: (key) => ref
                              .read(sessionControllerProvider.notifier)
                              .pressKey(inputSession.id, key),
                          onText: (text) => ref
                              .read(sessionControllerProvider.notifier)
                              .typeInto(inputSession.id, text),
                        ),
                        customKeys: settings.terminalCustomKeys,
                        drafts: _drafts,
                        composeFocus: _composeFocus,
                        onSystemKeyboard: () =>
                            _useSystemKeyboard(inputSession),
                        secureKeyboard: settings.terminalSecureKeyboard,
                        dense: layout.dense,
                        showHeader: layout.showPanelHeader,
                        transparentBackground: customBackground,
                      ),
                    ),
                  ),
                ),
              SizedBox(
                key: const ValueKey('terminal-input-reserve'),
                height: layout.reserve,
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

  /// 这一格顶上要不要挂状态条、挂什么（R22）。连着而且没什么要提醒的就不挂。
  Widget? _connectionBanner(ActiveTerminalSession session, SessionState state) {
    if (session.closedByUser) return null;
    if (session.connected) {
      final problem = state.keepAliveProblem;
      if (problem == null || !identical(session, state.active)) return null;
      return _ConnectionBanner(
        key: const ValueKey('terminal-connection-banner'),
        message: problem,
        warning: true,
      );
    }
    final recovering = state.recovering.contains(session.id);
    final message = recovering
        ? state.networkAvailable
            ? '连接断了，正在自动恢复…'
            : '连接断了。手机现在没有网络，网络回来后自动恢复。'
        : session.restoreHold?.message ?? '连接已断开。';
    return _ConnectionBanner(
      key: const ValueKey('terminal-connection-banner'),
      message: message,
      recovering: recovering,
      onReconnect: () => unawaited(_reconnect(session)),
    );
  }

  Future<void> _reconnect(ActiveTerminalSession session) async {
    try {
      await ref.read(sessionControllerProvider.notifier).reconnect(
            session.id,
            verifyHostKey: hostKeyVerifier(context, ref),
            keyboardInteractive: keyboardInteractivePrompt(context),
          );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LText('重新连接失败：$error')),
      );
    }
  }

  void _openPerformanceMonitor(ActiveTerminalSession session) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => ServerMonitorSheet(session: session),
    );
  }

  /// 关插件标签前说清楚：本 App 只管自己这一端，插件那边连着的东西怎么收尾由插件决定。
  String _pluginCloseText(ActiveTerminalSession session) {
    final head = localized('将关闭插件会话：');
    final tail = localized('本 App 先关自己这一端，再请插件关，2 秒内等它确认；插件自己连着的东西怎么收尾由插件决定。');
    return '$head${session.host.label}（${session.plugin!.protocol}）。$tail';
  }

  Future<void> _confirmClose(
    int index,
    ActiveTerminalSession session,
  ) async {
    final close = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.warning_amber_outlined),
            title: LText(
              session.plugin == null
                  ? '关闭 SSH 标签页？'
                  : session.host.protocol == HostProtocol.plugin
                      ? '关闭插件标签页？'
                      : '关闭 Mosh 标签页？',
            ),
            // 不承诺普通 shell 里的程序还活着（TMX08）：断开时它们通常会收到挂断信号一起结束；
            // tmux 标签只是分离客户端，会话和里面的程序还在。
            // 已经断开的标签什么都不会再发：不能再说「会话留在远端」——恢复时可能已经查明它不在了。
            content: LText(
              switch ((session.tmux, session.connected)) {
                // 插件主机（X12）：本 App 只请插件关会话、2 秒内等它确认；插件那边连着什么、怎么收尾由插件决定。
                _
                    when session.host.protocol == HostProtocol.plugin &&
                        session.connected =>
                  _pluginCloseText(session),
                // Mosh：插件让 mosh-client 按协议通知服务器关闭，远端的 mosh-server 和 shell 随之退出。
                _ when session.plugin != null && session.connected =>
                  '将断开 ${session.host.label} 的 Mosh 会话：服务器上这次的 mosh-server 和里面的 shell 会一起退出，'
                      '没在 tmux 之类工具里运行的程序也会结束。',
                (final tmux?, true) => '只分离这个标签的 tmux 客户端：tmux 会话 '
                    '${tmux.target.displayName}（${tmux.target.sessionId}）和里面的程序留在远端，'
                    '不发送 Ctrl-C，也不结束会话。',
                (final tmux?, false) => '这个标签已经断开，关掉只是把它移走。tmux 会话 '
                    '${tmux.target.displayName}（${tmux.target.sessionId}）如果还在，不受影响。',
                (null, true) => '将断开 ${session.host.label} '
                    '(${session.host.username}@${session.host.hostname}) 的当前会话。'
                    '没在 tmux 之类工具里运行的程序，通常会随连接一起结束。',
                (null, false) => '这个标签已经断开，关掉只是把它移走。',
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
            // 只发给打开助手时的那条连接：期间断线恢复成了新 shell，命令就不发（R19，按粘贴发）。
            onCommand: (command, execute) async {
              ref.read(sessionControllerProvider.notifier).pasteInto(
                    session,
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
