import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';

import '../../application/plugin_registry.dart';
import '../../application/rustdesk.dart';
import '../../infrastructure/plugins/rustdesk_external.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import '../widgets/catalog_text.dart';
import '../widgets/hint.dart';
import '../widgets/remote_entry_widgets.dart';

// RustDesk 外部客户端联动（X07）的界面。规则都在 application/rustdesk.dart；这里只负责说清楚：
// 远控在 RustDesk 里进行，本 App 只把 ID 交给它；RustDesk 不回报，所以永远不说「已连接」「已断开」。

// 原来常驻在两页顶上，现在收进标题栏的 ⓘ（docs/dev/ui-text.md）；完整说明在使用手册。
const _limits =
    '远控画面、密码、服务器设置和网络都在 RustDesk 里，本 App 只把这条连接的 RustDesk ID 交给它。RustDesk 不向本 App 回报结果：连没连上、什么时候断开，都要在 RustDesk 里看。';

/// 一台主机的 RustDesk：填 ID、发起远控、最近一次请求。
class RustDeskHostScreen extends ConsumerStatefulWidget {
  const RustDeskHostScreen({super.key, required this.hostId});
  final String hostId;

  @override
  ConsumerState<RustDeskHostScreen> createState() => _RustDeskHostScreenState();
}

class _RustDeskHostScreenState extends ConsumerState<RustDeskHostScreen> {
  final _id = TextEditingController();
  var _busy = false;
  var _editing = false;
  String? _idError;
  late final AppLifecycleListener _lifecycle;

  RustDeskController get _rd => ref.read(rustDeskProvider.notifier);

  @override
  void initState() {
    super.initState();
    unawaited(_rd.refreshApp().catchError((Object _) {}));
    // 用户多半是看了这页的提示，去装/更新 RustDesk 再回来：回来时重查，不用他退出重进。
    // 只重查手机上装了什么，不发任何请求。
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_rd.refreshApp().catchError((Object _) {})),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _id.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on RustDeskRouteNeedsConfirmation {
      rethrow;
    } on Object catch (e) {
      final unavailable = localized('RustDesk 调用现在不可用：');
      _snack(e is PluginUnavailable ? '$unavailable$e' : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _idError = null;
    });
    try {
      await _rd.saveLink(widget.hostId, _id.text);
      if (mounted) setState(() => _editing = false);
    } on RustDeskPeerIdRejected catch (e) {
      // 错在输入上，写在输入框下面，不用一闪而过的提示条。
      if (mounted) setState(() => _idError = localized(e.message));
    } on Object catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _launch() async {
    try {
      await _run(() => _rd.launch(widget.hostId));
    } on RustDeskRouteNeedsConfirmation {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const LText('RustDesk 不走这台主机的代理或跳板'),
          content: const LText(
            '这台主机的 SSH 经代理或跳板连接。RustDesk 用它自己配置的 ID 服务器和中继，不会经过这些设置。如果你要求远控也必须走同一条路线，RustDesk 做不到，请取消。',
          ),
          actions: [
            ShunButton(
              kind: ShunButtonKind.text,
              onPressed: () => Navigator.pop(context, false),
              label: '取消',
            ),
            ShunButton(
              key: const ValueKey('rd-route-accept'),
              onPressed: () => Navigator.pop(context, true),
              label: '用 RustDesk 自己的网络继续',
            ),
          ],
        ),
      );
      if (go == true) {
        await _run(() =>
            _rd.launch(widget.hostId, acceptProviderManagedNetwork: true));
      }
    }
  }

  Future<void> _delete(RustDeskLink link) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('删除这条连接的 RustDesk ID？'),
        content: const LText('只删本 App 里的这条关联，RustDesk 里的设备、密码和服务器设置不受影响。'),
        actions: [
          ShunButton(
            kind: ShunButtonKind.text,
            onPressed: () => Navigator.pop(context, false),
            label: '取消',
          ),
          ShunButton(
            key: const ValueKey('rd-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            label: '删除',
          ),
        ],
      ),
    );
    if (ok == true) await _run(() => _rd.deleteLink(link.id));
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: LText(text)));
  }

  @override
  Widget build(BuildContext context) {
    final rd = ref.watch(rustDeskProvider);
    final host = rd.entries.where((e) => e.id == widget.hostId).firstOrNull;
    final small = Theme.of(context).textTheme.bodySmall;
    final link = rd.linkOf(widget.hostId);
    final attempt = rd.attempts[widget.hostId];
    final editing = _editing || link == null;
    return Scaffold(
      appBar: ShunAppBar(
        title: Text(host == null ? 'RustDesk' : 'RustDesk · ${host.label}'),
        actions: [
          const HintButton(title: 'RustDesk', message: _limits),
          if (host != null)
            RemoteEntryActions(
              entry: host,
              rename: (label) => _rd.renameEntry(host.id, label),
              delete: () => _rd.deleteEntry(host.id),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (rd.notice != null) ...[
            LText(rd.notice!, key: const ValueKey('rd-notice')),
            const SizedBox(height: 12),
          ],
          RustDeskAppStatusCard(app: rd.app),
          const SizedBox(height: 12),
          if (host == null)
            const LText('这条远控连接已删除。')
          else
            ShunSection(children: [
              ShunSectionItem(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const HintTitle(
                      '这条连接的 RustDesk ID',
                      hint:
                          '在被控电脑的 RustDesk 主界面上看「ID」，照着填。只填 ID：密码到 RustDesk 里输，本 App 不保存、也不传密码。保存只是记下 ID，不会打开 RustDesk，也不会连接。',
                    ),
                    if (editing) ...[
                      const SizedBox(height: 4),
                      TextField(
                        key: const ValueKey('rd-id-field'),
                        controller: _id,
                        autocorrect: false,
                        enableSuggestions: false,
                        maxLength: RustDeskPeerId.maxInputLength,
                        decoration: InputDecoration(
                          labelText: 'RustDesk ID',
                          hintText: '123 456 789',
                          errorText: _idError,
                          errorMaxLines: 4,
                          counterText: '',
                        ),
                        onSubmitted: (_) => _save(),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          ShunButton(
                            key: const ValueKey('rd-save'),
                            onPressed: _busy ? null : _save,
                            label: '保存',
                          ),
                          if (link != null)
                            ShunButton(
                              kind: ShunButtonKind.text,
                              onPressed: _busy
                                  ? null
                                  : () => setState(() {
                                        _editing = false;
                                        _idError = null;
                                      }),
                              label: '取消',
                            ),
                        ],
                      ),
                    ] else ...[
                      Text(
                        link.peer.display,
                        key: const ValueKey('rd-peer-id'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      catalogLine(
                        '保存时间：',
                        catalogTime(link.createdAt),
                        style: small,
                      ),
                      if (host.routeWarning != RequestedRoute.systemDefault)
                        LText(
                          'RustDesk 不走这台主机的代理或跳板，用它自己的网络',
                          key: const ValueKey('rd-route-note'),
                          style: small,
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ShunButton(
                            key: const ValueKey('rd-launch'),
                            onPressed: rd.app is RustDeskReady && !_busy
                                ? _launch
                                : null,
                            icon: Icons.open_in_new,
                            label: '用 RustDesk 远控',
                          ),
                          ShunButton(
                            kind: ShunButtonKind.tonal,
                            key: const ValueKey('rd-edit'),
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                      _id.text = link.peer.display;
                                      _editing = true;
                                    }),
                            label: '改 ID',
                          ),
                          ShunButton(
                            kind: ShunButtonKind.text,
                            key: const ValueKey('rd-delete'),
                            onPressed: _busy ? null : () => _delete(link),
                            label: '删除',
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              )
            ]),
          if (attempt != null)
            ShunSection(children: [
              ShunSectionItem(
                key: const ValueKey('rd-attempt'),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const LText('最近一次'),
                    const SizedBox(height: 4),
                    Text(
                      rustDeskAttemptText(attempt),
                      key: const ValueKey('rd-attempt-text'),
                    ),
                    catalogLine(
                      '交给了：',
                      '${attempt.package} ${attempt.versionName ?? '?'}',
                      key: const ValueKey('rd-attempt-target'),
                      style: small,
                    ),
                  ],
                ),
              ),
            ]),
        ],
      ),
    );
  }
}

/// 设置里的总览：手机上的 RustDesk 能不能用、发给谁，以及全部关联（包括主机已被删掉的）。
class RustDeskSettingsScreen extends ConsumerStatefulWidget {
  const RustDeskSettingsScreen({super.key});

  @override
  ConsumerState<RustDeskSettingsScreen> createState() =>
      _RustDeskSettingsScreenState();
}

class _RustDeskSettingsScreenState
    extends ConsumerState<RustDeskSettingsScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final rd = ref.read(rustDeskProvider.notifier);
    unawaited(rd.refreshApp().catchError((Object _) {}));
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(rd.refreshApp().catchError((Object _) {})),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rd = ref.watch(rustDeskProvider);
    final hosts = rd.entries;
    return Scaffold(
      appBar: ShunAppBar(
        title: const Text('RustDesk'),
        actions: [
          // 逐句本地化再拼：拼好的整段在英文表里查不到。
          HintButton(
            title: 'RustDesk',
            message: [
              localized(_limits),
              localized('在首页添加连接时选择 RustDesk，无需 SSH 地址和用户名。'),
            ].join('\n\n'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (rd.notice != null) ...[
            LText(rd.notice!, key: const ValueKey('rd-notice')),
            const SizedBox(height: 12),
          ],
          RustDeskAppStatusCard(app: rd.app),
          if (hosts.isNotEmpty)
            ShunSection(children: [
              for (final entry in hosts)
                RemoteEntryTile(
                  entry: entry,
                  provider: 'RustDesk',
                  onOpen: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RustDeskHostScreen(hostId: entry.id),
                    ),
                  ),
                ),
            ]),
          const SizedBox(height: 12),
          ShunButton(
            kind: ShunButtonKind.text,
            onPressed: () => ref.read(rustDeskProvider.notifier).retryLoad(),
            label: '重新读取本机远控记录',
          ),
        ],
      ),
    );
  }
}

/// 手机上的 RustDesk 此刻能不能用、请求会发给哪个包；不能用就说为什么、该怎么办；要核对证书时在这里批准。
class RustDeskAppStatusCard extends ConsumerWidget {
  const RustDeskAppStatusCard({super.key, required this.app});
  final RustDeskAppStatus? app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final small = Theme.of(context).textTheme.bodySmall;
    final controller = ref.read(rustDeskProvider.notifier);
    final app = this.app;

    void snack(Object e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LText('$e')));
    }

    Future<void> trust(String package, String signer) async {
      try {
        await controller.trustClient(package, signer);
      } on Object catch (e) {
        snack(e);
      }
    }

    /// 改用别的包名是把 RustDesk ID 交给一个本 App 不认识的 App：先让用户对着包名和证书确认一次。
    Future<void> trustOther(RustDeskClient other) async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const LText('信任这个 App、改用它来远控？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              catalogLine('包名：', other.package),
              catalogLine('签名证书 SHA-256：', formatDigest(other.signers.single),
                  style: small),
              const SizedBox(height: 8),
              const LText(
                '之后远控请求（里面有 RustDesk ID）会发给它，不再发给官方包名的 RustDesk。只有当它是你自己编译的、或你信得过的 RustDesk 客户端时才信任。它的证书以后变了，本 App 会停下来让你重新核对。',
              ),
            ],
          ),
          actions: [
            ShunButton(
              kind: ShunButtonKind.text,
              onPressed: () => Navigator.pop(context, false),
              label: '取消',
            ),
            ShunButton(
              key: const ValueKey('rd-trust-confirm'),
              onPressed: () => Navigator.pop(context, true),
              label: '信任并改用',
            ),
          ],
        ),
      );
      if (ok == true) await trust(other.package, other.signers.single);
    }

    List<Widget> client(RustDeskClient c) => [
          catalogLine('包名：', c.package, style: small),
          catalogLine('版本：', c.versionName ?? '?', style: small),
        ];

    Widget revoke() => ShunButton(
          kind: ShunButtonKind.text,
          key: const ValueKey('rd-revoke'),
          onPressed: () => controller.revokeTrust().catchError(snack),
          label: '撤销信任',
        );

    final children = <Widget>[
      ...switch (app) {
        null => [const LinearProgressIndicator()],
        RustDeskPlatformUnsupported() => [
            const LText('RustDesk 联动目前只支持 Android。')
          ],
        RustDeskNotInstalled() => [
            catalogLine(
              '没有装 RustDesk：',
              RustDeskProtocol.officialPackage,
              key: const ValueKey('rd-not-installed'),
            ),
            LText('请从 RustDesk 的 GitHub 发行页或 F-Droid 安装。装好后回到这里。',
                style: small),
          ],
        RustDeskVersionTooOld(:final client) => [
            catalogLine('装着的 RustDesk 版本太旧：', client.versionName ?? '?',
                key: const ValueKey('rd-too-old')),
            catalogLine(
              '从这个版本起 RustDesk 才接受别的 App 发来的连接请求，请先更新：',
              RustDeskProtocol.minVersionText,
              style: small,
            ),
          ],
        RustDeskSignerUnsupported(client: final c) => [
            ...client(c),
            const LText('这个 RustDesk 由多张证书签名，暂不支持。'),
          ],
        RustDeskSignerNeedsApproval(client: final c, :final signer) => [
            ...client(c),
            catalogLine('签名证书 SHA-256：', formatDigest(signer), style: small),
            const SizedBox(height: 4),
            const LText(
              '这张证书没核对过，分不出是重签、自编译还是冒牌。确定来源才批准。',
              key: ValueKey('rd-needs-approval'),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: ShunButton(
                key: const ValueKey('rd-approve'),
                onPressed: () => trust(c.package, signer),
                label: '批准这张证书',
              ),
            ),
          ],
        RustDeskSignerChanged(
          client: final c,
          :final approved,
          :final current
        ) =>
          [
            const LText(
              'RustDesk 换了签名证书，可能是重装，也可能是冒牌。核对前不发请求。',
              key: ValueKey('rd-signer-changed'),
            ),
            ...client(c),
            catalogLine('批准时：', formatDigest(approved), style: small),
            catalogLine('现在：', formatDigest(current), style: small),
            Wrap(
              spacing: 8,
              children: [
                ShunButton(
                  kind: ShunButtonKind.tonal,
                  key: const ValueKey('rd-approve'),
                  onPressed: () => trust(c.package, current),
                  label: '批准新证书',
                ),
                revoke(),
              ],
            ),
          ],
        RustDeskReady(client: final c, :final source, :final version) => [
            ...client(c),
            LText(
              switch (source) {
                RustDeskTrustSource.githubRelease => '签名证书和 GitHub 官方发行版的一致。',
                RustDeskTrustSource.fdroid => '签名证书和 F-Droid 构建的一致。',
                RustDeskTrustSource.userApproved =>
                  '这是你明确信任的客户端。本 App 没有核对过它的来源。',
              },
              key: const ValueKey('rd-ready'),
              style: small,
            ),
            ...switch (version) {
              // 用户自己信任的客户端只是版本号对得上，它的链接处理改没改过本 App 不知道，不替它作保。
              RustDeskVersionSupport.verified => [
                  if (source != RustDeskTrustSource.userApproved)
                    LText('这个版本的连接链接按源码核对过。', style: small),
                ],
              RustDeskVersionSupport.deepLinksUngated => [
                  catalogLine(
                    '这个版本会执行外来的改密码、改服务器链接。建议至少更新到：',
                    RustDeskProtocol.gatedSinceText,
                    key: const ValueKey('rd-version-ungated'),
                    style: small,
                  ),
                ],
              RustDeskVersionSupport.newerUnverified => [
                  catalogLine(
                    '这个版本比核对过的新，出问题先怀疑这里。核对过的最高版本：',
                    RustDeskProtocol.verifiedUpToText,
                    key: const ValueKey('rd-version-unverified'),
                    style: small,
                  ),
                ],
              // 走不到 tooOld：那种情况不会是「可用」。留着只为 switch 穷尽。
              RustDeskVersionSupport.unreadable ||
              RustDeskVersionSupport.tooOld =>
                [
                  LText(
                    '看不懂这个版本号，连接链接按核对过的写法发。',
                    key: const ValueKey('rd-version-unreadable'),
                    style: small,
                  ),
                ],
            },
            if (source == RustDeskTrustSource.userApproved)
              Align(alignment: Alignment.centerLeft, child: revoke()),
          ],
      },
      for (final other in app?.others ?? const <RustDeskClient>[]) ...[
        const SizedBox(height: 12),
        catalogLine('另有 App 也声明能打开 rustdesk://：', other.package,
            key: ValueKey('rd-other-${other.package}')),
        catalogLine('版本：', other.versionName ?? '?', style: small),
        if (other.signers.length == 1) ...[
          catalogLine('签名证书 SHA-256：', formatDigest(other.signers.single),
              style: small),
          LText('本 App 不会把请求发给它，除非你明确信任它。', style: small),
          Align(
            alignment: Alignment.centerLeft,
            child: ShunButton(
              kind: ShunButtonKind.text,
              key: ValueKey('rd-trust-${other.package}'),
              onPressed: () => trustOther(other),
              label: '信任并改用',
            ),
          ),
        ] else
          LText('本 App 不会把请求发给它。它由多张证书签名，也没法信任。', style: small),
      ],
    ];
    return ShunSection(title: '手机上的 RustDesk', children: [
      ShunSectionItem(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      )
    ]);
  }
}

/// 最近一次请求，已经按当前语言翻好（界面直接用 Text 显示）。
///
/// 只有两种说法：交出去了、没交出去。RustDesk 不回报，所以没有「已连接」「失败」「已断开」（RDX03）。
/// 时间、原因原文和句子分开翻再拼：整句带插值交给片段表翻，短片段会误伤别处的文案。
String rustDeskAttemptText(RustDeskAttempt attempt) {
  if (attempt.phase == ExternalLaunchPhase.launchFailed) {
    return localized('没能打开 RustDesk：') + localized(attempt.code ?? '');
  }
  return [
    catalogTime(attempt.at),
    localized('已交给 RustDesk。它不向本 App 回报结果，连没连上请看 RustDesk。'),
  ].join(' · ');
}
