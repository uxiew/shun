import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';

import '../../application/plugin_registry.dart';
import '../../application/uuremote.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/plugins/uuremote_adapter.dart';
import '../localization/localized_widgets.dart';
import '../widgets/catalog_text.dart';

// UU 远程（X06）的界面。规则都在 application/uuremote.dart；这里只负责说清楚：
// 远控在 UU 远程里进行，本 App 只发起、只显示 UU 报告的结果；全屏 UU 不回报，所以永远不说「已连接」。

const _limits = '远控画面、账号和网络都在 UU 远程里，本 App 只负责发起和记录 UU 报告的结果。'
    'UU 只能控制 Windows 和 macOS 电脑，不能控制 Linux、安卓或电视。';

/// 挂在首页外面：App 一启动就开始接 UU 的回调（冷启动带进来的也不漏），
/// 绑定回来时在任何页面弹确认框，忽略了一条回调时给个提示。
class UuRemoteListener extends ConsumerStatefulWidget {
  const UuRemoteListener({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UuRemoteListener> createState() => _UuRemoteListenerState();
}

class _UuRemoteListenerState extends ConsumerState<UuRemoteListener> {
  var _asking = false;

  @override
  Widget build(BuildContext context) {
    ref.listen<UuRemoteState>(uuRemoteProvider, (previous, next) {
      if (next.offer != null && previous?.offer != next.offer && !_asking) {
        unawaited(_confirm(next.offer!));
      }
      final notice = next.notice;
      if (notice != null && notice != previous?.notice) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: LText(notice)));
        ref.read(uuRemoteProvider.notifier).clearNotice();
      }
    });
    return widget.child;
  }

  Future<void> _confirm(UuBindOffer offer) async {
    _asking = true;
    try {
      final vault = ref.read(vaultControllerProvider).data;
      final host = vault?.hosts.where((h) => h.id == offer.hostId).firstOrNull;
      final controller = ref.read(uuRemoteProvider.notifier);
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const LText('UU 远程返回了一台设备'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              catalogLine('要关联到主机：', host?.label ?? offer.hostId),
              const SizedBox(height: 8),
              const LText(
                'UU 只给了一个加密的设备标识，本 App 看不到设备名，也不会把它显示、导出或复制。'
                '关联之后可以在这台主机上用 UU 远程发起远控；本 App 不会自动发起。',
              ),
              const SizedBox(height: 8),
              const LText(
                '如果你没有刚在 UU 里选过设备，点「不要」：这条回调可能不是你发起的。',
              ),
            ],
          ),
          actions: [
            TextButton(
              key: const ValueKey('uu-offer-discard'),
              onPressed: () => Navigator.pop(context, false),
              child: const LText('不要'),
            ),
            FilledButton(
              key: const ValueKey('uu-offer-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: const LText('关联'),
            ),
          ],
        ),
      );
      if (ok == true) {
        try {
          await controller.confirmOffer();
          _snack('已关联 UU 远程。');
        } on Object catch (e) {
          _snack('$e');
        }
      } else {
        controller.discardOffer();
      }
    } finally {
      _asking = false;
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: LText(text)));
  }
}

/// 一台主机的 UU 远程：绑定、全屏/小窗远控、最近一次结果。
class UuRemoteHostScreen extends ConsumerStatefulWidget {
  const UuRemoteHostScreen({super.key, required this.hostId});
  final String hostId;

  @override
  ConsumerState<UuRemoteHostScreen> createState() => _UuRemoteHostScreenState();
}

class _UuRemoteHostScreenState extends ConsumerState<UuRemoteHostScreen> {
  var _busy = false;
  late final AppLifecycleListener _lifecycle;

  UuRemoteController get _uu => ref.read(uuRemoteProvider.notifier);

  @override
  void initState() {
    super.initState();
    unawaited(_uu.refreshApp());
    // 用户多半是看了这页的提示，去装/更新 UU 或卸载别的 App 再回来：回来时重查，不用他退出重进。
    _lifecycle =
        AppLifecycleListener(onResume: () => unawaited(_uu.refreshApp()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on UuRouteNeedsConfirmation {
      rethrow;
    } on Object catch (e) {
      final unavailable = localized('UU 远程调用现在不可用：');
      _snack(e is PluginUnavailable ? '$unavailable$e' : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _launch(UuWindow window) async {
    try {
      await _run(() => _uu.launch(widget.hostId, window));
    } on UuRouteNeedsConfirmation {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const LText('UU 远程不走这台主机的代理或跳板'),
          content: const LText(
            '这台主机的 SSH 经代理或跳板连接。UU 远程用它自己的网络和账号，不会经过这些设置。'
            '如果你要求远控也必须走同一条路线，UU 做不到，请取消。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const LText('取消'),
            ),
            FilledButton(
              key: const ValueKey('uu-route-accept'),
              onPressed: () => Navigator.pop(context, true),
              child: const LText('用 UU 自己的网络继续'),
            ),
          ],
        ),
      );
      if (go == true) {
        await _run(() => _uu.launch(
              widget.hostId,
              window,
              acceptProviderManagedNetwork: true,
            ));
      }
    }
  }

  Future<void> _delete(UuBinding binding) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('删除这条 UU 绑定？'),
        content: const LText(
          '只删本 App 里的这条绑定。主机、它的 SSH 设置和别的关联都不动；UU 远程里的设备也不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const LText('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await _run(() => _uu.deleteBinding(binding.id));
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: LText(text)));
  }

  @override
  Widget build(BuildContext context) {
    final uu = ref.watch(uuRemoteProvider);
    final host = ref
        .watch(vaultControllerProvider)
        .data
        ?.hosts
        .where((h) => h.id == widget.hostId)
        .firstOrNull;
    final small = Theme.of(context).textTheme.bodySmall;
    final binding = uu.bindingOf(widget.hostId);
    final pending = uu.pending;
    final waitingHere = pending != null && pending.hostId == widget.hostId;
    final waitingElsewhere = pending != null && !waitingHere;
    final ready = uu.app is UuReady;
    final canSend = ready && !_busy && pending == null;
    // 绑定和小窗要靠回调地址收结果；地址被别的 App 也声明了就不发（全屏不带回调，照常）。
    final canSendWithCallback = canSend && uu.callbackRivals.isEmpty;
    final attempt = uu.attempts[widget.hostId];
    return Scaffold(
      appBar: AppBar(
          title: Text(host == null
              ? localized('UU 远程')
              : '${localized('UU 远程')} · ${host.label}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          LText(_limits, style: small),
          const SizedBox(height: 12),
          UuAppStatusCard(app: uu.app),
          UuCallbackRivalsNote(rivals: uu.callbackRivals),
          const SizedBox(height: 12),
          if (host == null)
            const LText('这台主机已不在保险库里。')
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const LText('绑定'),
                    const SizedBox(height: 4),
                    if (binding == null)
                      LText(
                        '还没绑定。点「在 UU 里选设备」，UU 会列出你账号下的 Windows/macOS 电脑，选一台再回到这里确认。',
                        style: small,
                      )
                    else if (binding.valid)
                      catalogLine('已绑定，时间：', catalogTime(binding.createdAt),
                          style: small)
                    else
                      LText(
                        'UU 报告这条绑定已失效（设备解绑、被删，或换了 UU 账号），要重新绑定。只有这条 UU 绑定受影响，主机的 SSH 照常。',
                        key: const ValueKey('uu-binding-invalid'),
                        style: small,
                      ),
                    if (binding != null && binding.valid)
                      LText('UU 不把设备名告诉第三方 App，所以这里只显示绑定时间。', style: small),
                    if (sshRouteOf(host) != RequestedRoute.systemDefault)
                      LText(
                        '这台主机的 SSH 经代理或跳板；UU 远程不走这条路线，用它自己的网络。',
                        key: const ValueKey('uu-route-note'),
                        style: small,
                      ),
                    if (waitingElsewhere)
                      LText('另一台主机的 UU 请求还在等回报，先到那里结束等待。', style: small),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (binding != null && binding.valid) ...[
                          FilledButton.icon(
                            key: const ValueKey('uu-launch-fullscreen'),
                            onPressed: canSend
                                ? () => _launch(UuWindow.fullscreen)
                                : null,
                            icon: const Icon(Icons.fullscreen),
                            label: const LText('全屏远控'),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('uu-launch-pip'),
                            onPressed: canSendWithCallback
                                ? () => _launch(UuWindow.pip)
                                : null,
                            icon: const Icon(
                                Icons.picture_in_picture_alt_outlined),
                            label: const LText('小窗远控'),
                          ),
                        ],
                        OutlinedButton.icon(
                          key: const ValueKey('uu-bind'),
                          onPressed: canSendWithCallback
                              ? () => _run(() => _uu.startBind(widget.hostId))
                              : null,
                          icon: const Icon(Icons.link),
                          label: LText(binding == null ? '在 UU 里选设备' : '重新绑定'),
                        ),
                        if (binding != null)
                          TextButton(
                            key: const ValueKey('uu-delete'),
                            onPressed: _busy ? null : () => _delete(binding),
                            child: const LText('删除绑定'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (attempt != null || waitingHere) ...[
            const SizedBox(height: 12),
            Card(
              key: const ValueKey('uu-attempt'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const LText('最近一次'),
                    const SizedBox(height: 4),
                    if (attempt != null)
                      Text(
                        uuAttemptText(attempt, waiting: waitingHere),
                        key: const ValueKey('uu-attempt-text'),
                      ),
                    if (waitingHere) ...[
                      catalogLine('最多等到：', catalogTime(pending.expiresAt),
                          style: small),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: const ValueKey('uu-end-waiting'),
                          onPressed: () => _run(_uu.endWaiting),
                          child: const LText('结束等待'),
                        ),
                      ),
                    ],
                    if (!waitingHere &&
                        attempt?.code == UuReasons.pipUnsupported &&
                        binding != null &&
                        binding.valid)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: const ValueKey('uu-retry-fullscreen'),
                          onPressed: canSend
                              ? () => _launch(UuWindow.fullscreen)
                              : null,
                          child: const LText('改用全屏'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 设置里的总览：手机上的 UU 远程能不能用、证书核对，以及全部绑定（包括主机已被删掉的）。
class UuRemoteSettingsScreen extends ConsumerStatefulWidget {
  const UuRemoteSettingsScreen({super.key});

  @override
  ConsumerState<UuRemoteSettingsScreen> createState() =>
      _UuRemoteSettingsScreenState();
}

class _UuRemoteSettingsScreenState
    extends ConsumerState<UuRemoteSettingsScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final uu = ref.read(uuRemoteProvider.notifier);
    unawaited(uu.refreshApp());
    _lifecycle =
        AppLifecycleListener(onResume: () => unawaited(uu.refreshApp()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uu = ref.watch(uuRemoteProvider);
    final hosts =
        ref.watch(vaultControllerProvider).data?.hosts ?? const <HostProfile>[];
    final small = Theme.of(context).textTheme.bodySmall;
    return Scaffold(
      appBar: AppBar(title: const LText('UU 远程')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const LText(_limits),
          const SizedBox(height: 4),
          LText('在保险库里点开一台主机，选「UU 远程」来绑定和发起远控。', style: small),
          const SizedBox(height: 12),
          UuAppStatusCard(app: uu.app),
          UuCallbackRivalsNote(rivals: uu.callbackRivals),
          const SizedBox(height: 16),
          const LText('绑定'),
          if (uu.bindings.isEmpty)
            LText('还没有 UU 绑定。', style: small)
          else
            for (final binding in uu.bindings)
              Card(
                child: ListTile(
                  key: ValueKey('uu-binding-${binding.id}'),
                  title: Text(hosts
                          .where((h) => h.id == binding.hostId)
                          .firstOrNull
                          ?.label ??
                      localized('（主机已删除）')),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      catalogLine('绑定时间：', catalogTime(binding.createdAt),
                          style: small),
                      if (!binding.valid)
                        LText('已失效：UU 报告设备不存在或换了账号', style: small),
                    ],
                  ),
                  trailing: IconButton(
                    tooltip: localized('删除绑定'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => ref
                        .read(uuRemoteProvider.notifier)
                        .deleteBinding(binding.id),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// 手机上的 UU 远程此刻能不能用，不能用就说为什么、该怎么办；证书要核对时在这里批准。
class UuAppStatusCard extends ConsumerWidget {
  const UuAppStatusCard({super.key, required this.app});
  final UuAppStatus? app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final small = Theme.of(context).textTheme.bodySmall;
    final controller = ref.read(uuRemoteProvider.notifier);
    final app = this.app;
    // 带包名、版本号的句子拆成「标签：值」，标签按精确表翻，值原样显示——整句交给片段表翻会误伤别的文案。
    List<Widget> others(List<String> handlers) => [
          if (handlers.isNotEmpty) ...[
            catalogLine(
              '另有 App 也声明能打开 uuremote://：',
              handlers.join(', '),
              style: small,
            ),
            LText(
              '本 App 只把请求发给官方包名，不会发给它们。',
              key: const ValueKey('uu-other-handlers'),
              style: small,
            ),
          ],
        ];
    Future<void> approve(String signer) async {
      try {
        await controller.approveSigner(signer);
      } on Object catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: LText('$e')));
        }
      }
    }

    final children = <Widget>[
      const LText('手机上的 UU 远程'),
      const SizedBox(height: 4),
      ...switch (app) {
        null => [const LinearProgressIndicator()],
        UuPlatformUnsupported() => [const LText('UU 远程联动目前只支持 Android。')],
        UuNotInstalled(:final otherHandlers) => [
            catalogLine('没有装 UU 远程：', UuRemoteProtocol.package,
                key: const ValueKey('uu-not-installed')),
            catalogLine(
              '请从官方渠道（uuyc.163.com 或正规应用商店）安装，最低版本：',
              UuRemoteProtocol.minVersionText,
              style: small,
            ),
            ...others(otherHandlers),
          ],
        UuVersionTooOld(:final versionName) => [
            catalogLine('装着的 UU 远程版本太旧：', versionName ?? '?',
                key: const ValueKey('uu-too-old')),
            catalogLine(
              '跨 App 调用要求的最低版本，请先更新：',
              UuRemoteProtocol.minVersionText,
              style: small,
            ),
          ],
        UuSchemeNotHandled(:final versionName) => [
            catalogLine(
              '装着的 UU 远程不接受跨 App 请求，可能被停用了。版本：',
              versionName ?? '?',
            ),
          ],
        UuSignerUnsupported() => [const LText('这个 UU 远程由多张证书签名，暂不支持。')],
        UuSignerNeedsApproval(:final signer, :final versionName) => [
            catalogLine('版本：', versionName ?? '?', style: small),
            catalogLine('签名证书 SHA-256：', formatDigest(signer), style: small),
            const SizedBox(height: 4),
            const LText(
              '这张证书还不在本 App 核对过的官方证书里。只有在你确定这个 UU 远程是从官方渠道（uuyc.163.com 或正规应用商店）装的时候才批准；批准后证书再变，本 App 会停下来让你重新核对。',
              key: ValueKey('uu-needs-approval'),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                key: const ValueKey('uu-approve'),
                onPressed: () => approve(signer),
                child: const LText('批准这张证书'),
              ),
            ),
          ],
        UuSignerChanged(:final approved, :final current) => [
            const LText(
              '手机上的 UU 远程换了签名证书：可能是换了渠道重装，也可能是冒牌的。核对之前不会再发任何请求。',
              key: ValueKey('uu-signer-changed'),
            ),
            catalogLine('批准时：', formatDigest(approved), style: small),
            catalogLine('现在：', formatDigest(current), style: small),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: const ValueKey('uu-approve'),
                onPressed: () => approve(current),
                child: const LText('批准新证书'),
              ),
            ),
          ],
        UuReady(:final versionName, :final official, :final otherHandlers) => [
            catalogLine('版本：', versionName ?? '?', style: small),
            LText(
              official ? '签名证书和从官方下载的一致。' : '签名证书是你批准过的那张（还没和官方 APK 核对）。',
              key: const ValueKey('uu-ready'),
              style: small,
            ),
            ...others(otherHandlers),
            if (!official)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: controller.revokeApproval,
                  child: const LText('撤销批准'),
                ),
              ),
          ],
      },
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

/// 别的 App 也声明了本 App 的 UU 回调地址时的提醒（UUR06）。没有就不占地方。
class UuCallbackRivalsNote extends StatelessWidget {
  const UuCallbackRivalsNote({super.key, required this.rivals});
  final List<String> rivals;

  @override
  Widget build(BuildContext context) {
    if (rivals.isEmpty) return const SizedBox.shrink();
    return Card(
      key: const ValueKey('uu-callback-rivals'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            catalogLine('另有 App 也声明了本 App 的 UU 回调地址：', rivals.join(', ')),
            const SizedBox(height: 4),
            LText(
              'UU 的回报可能被它截走或冒充，所以绑定和小窗远控现在不发；全屏远控不受影响。卸载它之后回到这里。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// 64 位十六进制按 4 位一组，方便和别处的证书对着看。
String formatDigest(String hex) => [
      for (var i = 0; i < hex.length; i += 4)
        hex.substring(i, i + 4 > hex.length ? hex.length : i + 4),
    ].join(' ');

/// UU 绑定失败的错误码（官方 2.5）。
String uuBindErrorText(String code) => switch (code) {
      UuBindErrors.noDevice => '你的 UU 账号下没有可关联的 Windows/macOS 电脑',
      UuBindErrors.userCancel => '你在 UU 里取消了',
      UuBindErrors.timeout => 'UU 等你登录或加载设备列表超时',
      UuBindErrors.notLogined => 'UU 远程没有登录',
      UuBindErrors.superseded => '这次绑定被 UU 里更新的一次请求取代了',
      UuBindErrors.logout => '等待期间 UU 退出了登录',
      UuBindErrors.internalError => 'UU 远程内部出错',
      uuDiscardedByUser => '你没有保存这次绑定',
      uuCallbackContested => '另有 App 也声明了本 App 的 UU 回调地址，这次返回的设备不可信，没有采用',
      // 未知错误码、本 App 自己的拒收原因：原样显示，不猜含义。
      _ => code,
    };

/// UU 小窗远控的失败原因（官方 3.5）。未知的按连接失败显示，并带上原文。
String uuReasonText(String reason) => switch (reason) {
      UuReasons.busy => 'UU 正在远控别的设备，或在做不能同时进行的事',
      UuReasons.deviceOffline => '目标电脑离线',
      UuReasons.deviceNotFound => '设备不存在、已解绑，或换了 UU 账号：这条绑定已失效，要重新绑定',
      UuReasons.pipUnsupported => '这台手机现在不能用小窗，可以改用全屏',
      UuReasons.loginTimeout => 'UU 登录或首页初始化超时',
      UuReasons.networkUnavailable => '手机没有可用网络',
      UuReasons.notAllowed => '目标电脑没开「允许被控」，或平台不受支持',
      UuReasons.connectTimeout => '连接或等首帧超时',
      UuReasons.connectFailed => '连接失败',
      UuReasons.userCancel => '你取消了',
      UuReasons.invalidRequest => '请求参数不对',
      UuReasons.internalError => 'UU 远程内部出错',
      _ => '连接失败，UU 给的原因本 App 不认识：',
    };

/// 最近一次的结果，已经按当前语言翻好（界面直接用 Text 显示）。
///
/// 故意没有「已连接」：全屏 UU 不回报；小窗的成功只是 UU 那一刻的报告。
/// 时间、错误码原文和句子分开翻再拼：整句带插值交给片段表翻，短片段会误伤别处的文案。
String uuAttemptText(UuAttempt attempt, {required bool waiting}) {
  String t(String source) => localized(source);
  final bind = attempt.kind == UuCallbackKind.bind;
  final code = attempt.code ?? '';
  if (attempt.unconfirmed) {
    return t(bind
        ? '你结束了等待：这次绑定结果未确认，UU 之后的回报会被忽略。'
        : '你结束了等待：这次小窗结果未确认，UU 之后的回报会被忽略。');
  }
  // 带时间的一行：时间 · 句子（· 附加的原文）。句子单独按精确表翻。
  String line(String source, [String detail = '']) =>
      [catalogTime(attempt.at), t(source) + detail].join(' · ');
  // 不认识的原因后面带上原文：本 App 不猜它的意思。
  final reason = UuRemoteProtocol.controlReasons.contains(code)
      ? t(uuReasonText(code))
      : t(uuReasonText(code)) + code;
  final discarded = code == uuDiscardedByUser;
  final fullscreen = attempt.window == UuWindow.fullscreen;

  return switch ((bind, attempt.phase)) {
    (_, ExternalLaunchPhase.launchFailed) => t('没能打开 UU 远程：') + t(code),
    (true, ExternalLaunchPhase.launchedUnverified) => waiting
        ? t('已打开 UU 远程的设备授权页，等它回报。UU 可能在等你登录（最长 3 分钟）。')
        : line('已打开 UU 远程的设备授权页。'),
    (true, ExternalLaunchPhase.providerReportedSuccess) =>
      discarded ? line('UU 返回了一台设备，你没有保存。') : line('UU 返回了一台设备。'),
    (true, ExternalLaunchPhase.providerReportedFailure) =>
      line('绑定没成功：', t(uuBindErrorText(code))),
    (false, ExternalLaunchPhase.launchedUnverified) => fullscreen
        ? line('已交给 UU 远程。全屏模式 UU 不回报结果，连没连上请看 UU 远程。')
        : waiting
            ? line('已交给 UU 远程，等它回报小窗结果。UU 可能先弹窗让你确认，不会自动超时。')
            : line('已交给 UU 远程。'),
    (false, ExternalLaunchPhase.providerReportedSuccess) =>
      line('UU 报告小窗已就绪。这只是 UU 那一刻的报告，不代表现在还连着。'),
    (false, ExternalLaunchPhase.providerReportedFailure) =>
      line('UU 报告小窗远控失败：', reason),
    (_, ExternalLaunchPhase.launching) => t('正在打开 UU 远程…'),
  };
}
