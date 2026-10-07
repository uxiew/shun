import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/terminal_engine.dart';
import '../localization/localized_widgets.dart';

/// 设置页里的「终端引擎」：只读，照实写这次运行里引擎怎样（TER12）。
///
/// R20 起只有 Ghostty，没有可选项。原生库起不来时这里写原话，连接也如实失败——
/// 不会悄悄换成别的引擎，用户以为在用 Ghostty、出了问题却查不到（docs/06）。
class TerminalEngineStatusTile extends ConsumerWidget {
  const TerminalEngineStatusTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(terminalEngineStatusProvider);
    final small = Theme.of(context).textTheme.bodySmall;
    final failure = status.failure;
    final version = status.nativeVersion;
    // 一句一个变量：本地化覆盖测试按「引号里有中文」逐行找原文，字符串里再套 localized('…') 会把它搞糊涂。
    final failedPrefix = localized('无法启动：');
    final noFallback = localized('这个版本只带 Ghostty，没有别的引擎可换：连接会直接失败，不会悄悄换成别的引擎。');
    final workingPrefix = localized('正常，这次运行建过的终端：');
    return Column(
      key: const ValueKey('terminal-engine-status'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Expanded(child: LText('终端引擎')),
          Text(version == null
              ? status.requested
              : '${status.requested} $version'),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: failure != null
                ? Text(
                    '$failedPrefix$failure\n$noFallback',
                    key: const ValueKey('terminal-engine-failure'),
                    style: small?.copyWith(
                        color: Theme.of(context).colorScheme.error),
                  )
                : status.effective != null
                    ? Text(
                        '$workingPrefix${status.started}',
                        style: small,
                      )
                    : LText('这次运行还没开过终端', style: small),
          ),
          TextButton(
            key: const ValueKey('terminal-engine-check'),
            onPressed: () =>
                ref.read(terminalEngineStatusProvider.notifier).check(),
            child: const LText('检查'),
          ),
        ]),
      ],
    );
  }
}
