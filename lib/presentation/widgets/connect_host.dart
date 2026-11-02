import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/fork_features.dart';
import '../../application/home_navigation.dart';
import '../../application/session_controller.dart';
import '../../application/settings_controller.dart';
import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/tailscale/catalog_cache_repository.dart';
import '../localization/localized_widgets.dart';
import 'connection_prompts.dart';
import 'first_login_dialog.dart';
import 'host_editor.dart';
import '../../domain/vault_secrets.dart';

/// 从列表里点一台主机去连：保险库页和 Tailscale 目录页共用（R26），两边表现一样。
/// 还没配好登录的（Tailscale 导入时不统一填用户名和密码）先问，写回这一台再连；然后切到终端页。
///
/// [leavePushedPages]：从压在首页上面的页（比如目录的设备页）发起时，先回到首页再连，不然终端在下面看不到。
/// 回去以后那一页就没了，所以只用 [context] 拿全局的东西（Provider 容器、Navigator），不用页面自己的 ref。
Future<void> connectHostFromList(
  BuildContext context,
  HostProfile host, {
  bool leavePushedPages = false,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final vault = container.read(vaultControllerProvider).data;
  if (needsFirstLogin(host,
      identities: vault == null ? const [] : vaultIdentityMaps(vault))) {
    final login = await askFirstLogin(context, host);
    if (login == null || !context.mounted) return;
    final updated = hostWithFirstLogin(host, login);
    await container.read(vaultControllerProvider.notifier).upsertHost(updated);
    if (!context.mounted) return;
    host = updated;
  }
  if (leavePushedPages) {
    final navigator = Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
    context = navigator.context;
  }
  // 两个回调在连接当中才用到：先取好，跳到终端页后 context 可能已经不在了。
  final verify = hostKeyVerifier(context);
  final ask = keyboardInteractivePrompt(context);
  final messenger = ScaffoldMessenger.of(context);
  container.read(homeTabProvider.notifier).state = 1;
  try {
    final connected = await container
        .read(sessionControllerProvider.notifier)
        .connect(host, verify, keyboardInteractive: ask);
    // 用户点了「终止连接」时 connect 正常返回 false，这时不能说已连接。
    if (connected) {
      messenger.showSnackBar(SnackBar(content: LText('${host.label} 已连接')));
    }
  } catch (error) {
    // 连接失败页已经把原因、下一步写全了，再弹一条一样的提示条只是重复（docs/dev/ui-text.md）。
    // 没走到失败页的（比如还没开始连就被拒）才在这里说。
    final shown = container
        .read(sessionControllerProvider)
        .pendingConnections
        .any((p) =>
            p.host.id == host.id && p.phase == PendingConnectionPhase.failed);
    if (!shown) {
      messenger.showSnackBar(SnackBar(content: LText('连接失败：$error')));
    }
  }
}

/// 点一台还没导入的 Tailscale 设备：按来源的导入默认值建成主机，接着连（R26：不再弹设置页）。
/// 别处刚导入过的就直接连那台。用户名、密码没有的在连接前后问（[connectHostFromList]）。
Future<void> importAndConnect(
  BuildContext context,
  String catalogId,
  String deviceId, {
  bool leavePushedPages = false,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.of(context);
  final controller = container.read(vaultControllerProvider.notifier);
  try {
    // 从磁盘读最新的：刚在设置页改过默认值，列表手里的可能还是旧的。
    final cache =
        await container.read(catalogCacheRepositoryProvider).load(catalogId);
    if (cache == null) {
      messenger.showSnackBar(const SnackBar(content: LText('本机没有这个目录来源')));
      return;
    }
    final result = await importCatalogDevices(controller, cache, [deviceId]);
    var host = result.added.firstOrNull;
    if (host == null) {
      final vault = await controller.ready();
      host = vault.hosts.where((h) {
        final binding = CatalogBinding.of(h);
        return binding?.catalogId == catalogId && binding?.deviceId == deviceId;
      }).firstOrNull;
    }
    if (host == null) {
      final skip = result.skipped.firstOrNull;
      messenger.showSnackBar(SnackBar(
        content: Text([
          localized('没有导入：'),
          if (skip != null) '${skip.name}：${localized(skip.reason)}',
        ].join()),
      ));
      return;
    }
    if (!context.mounted) return;
    await connectHostFromList(context, host,
        leavePushedPages: leavePushedPages);
  } on CatalogImportInvalid catch (error) {
    messenger.showSnackBar(SnackBar(
      content: Text(
          '${localized('Tailscale 设置里的导入设置不成立：')}${localized(error.message)}'),
    ));
  }
}

/// 不在连接页时新建或改一台主机：失败页、管理页。保存了只写回，不替用户连。
/// host 是 null 就是新建，只能选终端类型：Tailscale、RustDesk 这些走连接页的 ⊕。
Future<void> editSavedHost(
  BuildContext context,
  WidgetRef ref,
  HostProfile? host, {
  bool canDelete = false,
}) async {
  final result = await showModalBottomSheet<HostProfile>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // 下滑关闭会绕过编辑器「有没保存的改动」的确认（R41）。
    enableDrag: false,
    builder: (_) => HostEditor(
      host: host,
      onDelete: canDelete && host != null
          ? () => confirmDeleteHost(context, ref, host)
          : null,
      verifyHostKey: hostKeyVerifier(context),
      keyboardInteractive: keyboardInteractivePrompt(context),
    ),
  );
  if (result == null) return;
  await ref.read(vaultControllerProvider.notifier).upsertHost(result);
}

/// 先问再删一台主机。删了返回 true。
Future<bool> confirmDeleteHost(
  BuildContext context,
  WidgetRef ref,
  HostProfile host,
) async {
  final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.delete_outline),
          title: const LText('删除服务器？'),
          // 没开自动同步就不说「会传到其他设备」，那句是上游留下的。
          content: LText(ref.read(forkFeaturesProvider).cloudSync &&
                  ref.read(settingsControllerProvider).autoSyncEnabled
              ? '将从保险库中删除“${host.label}”，此操作可通过云端备份传播到其他设备。'
              : '将从保险库中删除“${host.label}”，删了不能撤销。'),
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
      ) ??
      false;
  if (!confirmed || !context.mounted) return false;
  await ref.read(vaultControllerProvider.notifier).deleteHost(host.id);
  return true;
}
