import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/tailscale_ssh.dart';
import '../../infrastructure/ssh/ssh_login_watch.dart';
import '../localization/localized_widgets.dart';

/// 把 check 链接交给系统浏览器。测试里换成记录调用的假实现，不真的开浏览器。
final externalLinkLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) => (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// 等 Tailscale check 时显示的卡片。终端的连接等待页和「测试连接」共用。
///
/// 只在用户点按钮时把链接交给外部浏览器，从不自动打开、不复制、不截图（docs/05）；
/// 只显示域名，不显示链接里的 token。浏览器回来不算通过，以 SSH 登录结果为准。
class TailscaleCheckCard extends ConsumerStatefulWidget {
  const TailscaleCheckCard({super.key, required this.prompt});

  final TailscaleCheckPrompt prompt;

  @override
  ConsumerState<TailscaleCheckCard> createState() => _TailscaleCheckCardState();
}

class _TailscaleCheckCardState extends ConsumerState<TailscaleCheckCard> {
  /// 这张卡片上点过「打开」后的结果：null 没点过，true 已交给浏览器，false 没有能打开的 App。
  bool? _opened;

  @override
  void didUpdateWidget(TailscaleCheckCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.prompt, widget.prompt)) _opened = null;
  }

  Future<void> _open(CheckLinkBanner link) async {
    var opened = false;
    try {
      opened = await ref.read(externalLinkLauncherProvider)(link.link);
    } on Object {
      opened = false;
    }
    if (mounted) setState(() => _opened = opened);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final prompt = widget.prompt;
    final link = prompt.link;
    final rejected = prompt.banner is RejectedLinkBanner
        ? prompt.banner as RejectedLinkBanner
        : null;
    final hop =
        prompt.hopCount > 1 ? '第 ${prompt.hop + 1}/${prompt.hopCount} 跳，' : '';
    final deadline = TimeOfDay.fromDateTime(prompt.deadline).format(context);
    final small = theme.textTheme.bodySmall;
    return Container(
      key: const ValueKey('tailscale-check-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: link != null ? scheme.primaryContainer : scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: link != null
              ? scheme.onPrimaryContainer
              : scheme.onErrorContainer,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LText(
              link != null ? 'Tailscale 要求 check' : '收到的认证链接不会打开',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            _row(
                '登录的主机', '$hop“${prompt.hostLabel}”（${prompt.endpoint}），指纹已核对'),
            if (link != null) ...[
              _row('链接', link.display,
                  key: const ValueKey('check-link-domain')),
              _row('用途', '在浏览器里用你的 Tailscale 账号确认这次 SSH 登录'),
            ] else ...[
              _row(
                '为什么',
                rejected!.reason,
                key: const ValueKey('check-link-rejected-reason'),
              ),
              if (rejected.linkHost != null) _row('链接指向', rejected.linkHost!),
            ],
            _row('Tailscale 认的来源', prompt.sourceNode),
            _row('最晚等到', deadline),
            const SizedBox(height: 6),
            LText(
              link != null
                  ? '在浏览器里确认后回到这里，这里会自己继续。回到 App 不代表已经通过，以这边的登录结果为准。'
                  : '只打开 https://$tailscaleCheckHost/a/… 这种链接。可以终止连接；'
                      '确认这是你自己的认证服务，也可以用别的方式（比如自建控制面的命令行）批准，这里会继续等到截止时间。',
              style: small,
            ),
            if (prompt.banner.text.isNotEmpty) ...[
              const SizedBox(height: 6),
              LText('服务器原话（链接已隐去）：', style: small),
              Text(
                prompt.banner.text,
                key: const ValueKey('check-banner-text'),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: small?.copyWith(fontFamily: 'monospace'),
              ),
            ],
            if (link != null) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const ValueKey('open-check-link'),
                onPressed: () => _open(link),
                icon: const Icon(Icons.open_in_browser),
                label: const LText('在浏览器中打开'),
              ),
              if (_opened == true)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: LText(
                    '已交给浏览器，还在等 Tailscale 回话。',
                    key: const ValueKey('check-link-opened'),
                    style: small,
                  ),
                ),
              if (_opened == false)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: LText(
                    '没有能打开这个链接的浏览器。装一个浏览器后再点，或者终止连接。',
                    key: const ValueKey('check-link-open-failed'),
                    style: small,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {Key? key}) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 112,
              child:
                  LText(label, style: Theme.of(context).textTheme.labelMedium),
            ),
            Expanded(child: LText(value, key: key)),
          ],
        ),
      );
}
