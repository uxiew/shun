import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/app_lock.dart';
import '../localization/localized_widgets.dart';

/// 位于 ShunUiHost 的全局视觉层外，提示、导航器、弹框和底部菜单都在它下面。
///
/// 底下的页面不拆：终端继续收数据，大输入框的草稿、编辑到一半的表单都留着。但锁着时它们对手指、读屏、
/// 硬件键盘都不存在：只盖一层不透明的话，TalkBack 会照念主机列表，连着的键盘会照样打进终端。
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> {
  FocusNode? _focusBeforeLock;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleObscuredKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleObscuredKey);
    super.dispose();
  }

  KeyEventResult _handleObscuredKey(KeyEvent event) {
    if (!ref.read(appLockControllerProvider).obscured) {
      return KeyEventResult.ignored;
    }
    // The provider changes before ExcludeFocus can rebuild. Protect that
    // interval too, while allowing the cover's own unlock button to work.
    final onCover = FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<_AppLockCover>() !=
        null;
    return onCover ? KeyEventResult.ignored : KeyEventResult.handled;
  }

  void _obscuredChanged(bool? _, bool obscured) {
    if (obscured) {
      final focus = FocusManager.instance.primaryFocus;
      // Retain the original node if another cover arrives before a pending
      // restore. covered -> locked must not replace it with the lock button.
      _focusBeforeLock ??= focus;
      focus?.unfocus();
      return;
    }
    final node = _focusBeforeLock;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(appLockControllerProvider).obscured) return;
      if (node?.context != null && node!.canRequestFocus) node.requestFocus();
      if (identical(_focusBeforeLock, node)) _focusBeforeLock = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      appLockControllerProvider.select((lock) => lock.obscured),
      _obscuredChanged,
    );
    final lock = ref.watch(appLockControllerProvider);
    final hidden = lock.obscured;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: hidden,
          // 遮挡期间也断开输入法连接；回来后恢复同一个节点和草稿。
          child: ExcludeFocus(
            excluding: hidden,
            child: IgnorePointer(ignoring: hidden, child: widget.child),
          ),
        ),
        if (hidden) _AppLockCover(lock: lock),
      ],
    );
  }
}

class _AppLockCover extends ConsumerWidget {
  const _AppLockCover({required this.lock});

  final AppLockState lock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failure = lock.failure;
    return Material(
      key: const ValueKey('app-lock-cover'),
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 48),
                const SizedBox(height: 12),
                const Text('shun'),
                if (failure != null) ...[
                  const SizedBox(height: 12),
                  Text(failure, textAlign: TextAlign.center),
                ],
                if (lock.locked && !lock.authenticating) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('app-lock-unlock'),
                    autofocus: true,
                    onPressed: () =>
                        ref.read(appLockControllerProvider.notifier).unlock(),
                    child: const LText('解锁'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
