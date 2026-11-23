import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../domain/terminal_link.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'tailscale_check_card.dart' show externalLinkLauncherProvider;

/// 在选字菜单里点了「打开链接」（R19，SEC08、TER08；10-07 起点一下终端只叫键盘）：只弹这个框，不直接打开。
///
/// 先把实际要去的域名放大写出来，再给完整地址；能交给浏览器的只有 http/https，
/// 其余只能复制。点按、拖动、长按本身都不会走到这里，只有用户点了菜单里的按钮才会。
Future<void> showTerminalLinkSheet(
  BuildContext context, {
  required String shownText,
  required String address,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TerminalLinkSheet(
        link: TerminalLinkReview.of(shownText: shownText, address: address),
      ),
    );

class TerminalLinkSheet extends ConsumerWidget {
  const TerminalLinkSheet({super.key, required this.link});

  final TerminalLinkReview link;

  // 底部面板是抬起后的页面层：里面的块从这一层再往上数，深色下不然会和面板同色。
  @override
  Widget build(BuildContext context, WidgetRef ref) => prism.Theme(
        data: prism.Theme.of(context).elevated,
        child: Builder(builder: (context) => _content(context, ref)),
      );

  Widget _content(BuildContext context, WidgetRef ref) {
    final colors = prism.Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LText(
            '终端里的链接（来自远端输出）',
            style: prism.AppTextStyle.footnote
                .of(context)
                .copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          if (link.host.isNotEmpty)
            Text(
              link.host,
              key: const ValueKey('terminal-link-host'),
              style: prism.AppTextStyle.title2
                  .of(context, emphasized: true)
                  .copyWith(color: colors.onSurface),
            ),
          const SizedBox(height: 8),
          // 完整地址落在高一层的块里，和上面放大的域名、下面的提醒分开。
          DecoratedBox(
            decoration: ShapeDecoration(
              color: prism.SurfaceContext(context)
                  .raisedSurfaceLevel
                  .colorOf(colors),
              shape: prism.AppShape.md,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: SelectableText(
                link.address,
                key: const ValueKey('terminal-link-address'),
                // 地址多长块就多高，最多六行（原来不管多短都占六行）。
                minLines: 1,
                maxLines: 6,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: colors.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (link.textDiffers)
            _Warning(
              key: const ValueKey('terminal-link-text-differs'),
              text: '屏幕上显示的文字和实际地址不一样：',
              detail: link.shownText,
            ),
          if (link.nonAsciiHost)
            const _Warning(
              key: ValueKey('terminal-link-non-ascii'),
              text: '域名里有非英文字符，可能是仿冒知名网站的域名。',
            ),
          if (link.refusal case final refusal?)
            _Warning(
              key: const ValueKey('terminal-link-refused'),
              text: '不能打开：',
              detail: localized(refusal),
              color: colors.error,
            ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const ValueKey('terminal-link-cancel'),
                onPressed: () => Navigator.pop(context),
                child: const LText('取消'),
              ),
              // 次要动作是中性的：高一层的底、正文色的字，不描边，主色留给「用浏览器打开」。
              FilledButton.tonal(
                key: const ValueKey('terminal-link-copy'),
                style: ShunButton.neutralStyleOf(context),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link.address));
                  if (context.mounted) Navigator.pop(context);
                },
                child: const LText('复制链接'),
              ),
              if (link.canOpen)
                FilledButton(
                  key: const ValueKey('terminal-link-open'),
                  onPressed: () async {
                    final launch = ref.read(externalLinkLauncherProvider);
                    Navigator.pop(context);
                    await launch(link.uri!);
                  },
                  child: const LText('用浏览器打开'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({super.key, required this.text, this.detail, this.color});

  final String text;
  final String? detail;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? prism.Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, size: 18, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LText(text, style: TextStyle(color: foreground)),
                if (detail != null)
                  Text(detail!, style: TextStyle(color: foreground)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
