import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/app_lock.dart';
import '../localization/localized_widgets.dart';

/// 盖在整个导航器上面（MaterialApp.builder），弹框、底部菜单也在它下面。
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

  void _lockChanged(bool? _, bool locked) {
    if (locked) {
      // 这时 ExcludeFocus 还没生效，焦点还在原处。
      _focusBeforeLock = FocusManager.instance.primaryFocus;
      return;
    }
    final node = _focusBeforeLock;
    _focusBeforeLock = null;
    // 不还回去的话，解锁后终端没焦点，用户要再点一下才能打字。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (node?.context != null) node!.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      appLockControllerProvider.select((lock) => lock.locked),
      _lockChanged,
    );
    final lock = ref.watch(appLockControllerProvider);
    final hidden = lock.obscured;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: hidden,
          // 只有真锁着才拿走焦点。只是离开时盖一下（covered）App 收不到按键，拿走了回来终端就丢了焦点。
          child: ExcludeFocus(
            excluding: lock.locked,
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
