import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/vault_controller.dart';
import '../../domain/connection_route.dart' show proxyIdentityKey;
import '../../domain/credential_identity.dart';
import '../../domain/models/host.dart';
import '../../domain/proxy_profiles.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'empty_state.dart';
import 'proxy_profile_editor.dart';

Future<String?> selectRouteProxy(
        BuildContext context, Map<String, dynamic>? inlineConfig) =>
    Navigator.push<String>(
        context,
        MaterialPageRoute(
            builder: (_) => inlineConfig == null
                ? const ProxyProfilesPage(selecting: true)
                : ProxyProfileEditor(inlineConfig: inlineConfig)));

class ProxyProfilesPage extends ConsumerStatefulWidget {
  const ProxyProfilesPage({super.key, this.selecting = false});
  final bool selecting;
  @override
  ConsumerState<ProxyProfilesPage> createState() => _ProxyProfilesPageState();
}

class _ProxyProfilesPageState extends ConsumerState<ProxyProfilesPage> {
  bool _busy = false;
  String? _error;

  Future<void> _edit([String? id]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final controller = ref.read(vaultControllerProvider.notifier);
      final vault = await controller.ready();
      final profile = vault.proxyProfiles.where((p) => p.id == id).firstOrNull;
      if (id != null && profile == null) throw const ProxyProfileChanged();
      if (id != null &&
          ref
              .read(vaultControllerProvider)
              .unreadableSecrets
              .contains('proxy.$id.password')) {
        throw const ProxyProfileChanged();
      }
      if (!mounted) return;
      final selected = await Navigator.push<String>(
          context,
          MaterialPageRoute(
              builder: (_) => ProxyProfileEditor(profile: profile)));
      if (mounted && selected != null && widget.selecting) {
        Navigator.pop(context, selected);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '代理无法读取或已变化，请重新打开后再操作。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(String id) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final controller = ref.read(vaultControllerProvider.notifier);
      final vault = await controller.ready();
      final profile = vault.proxyProfiles.where((p) => p.id == id).firstOrNull;
      if (profile == null) throw const ProxyProfileChanged();
      final shown = ProxyDeletion(vault, profile);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: const LText('删除代理'),
                content: SizedBox(
                    width: 360,
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(profile.label),
                          // 以前没有主机在用时也先写「以下主机引用此代理……」，再写「没有主机引用」，前后矛盾。
                          if (shown.hosts.isEmpty)
                            const LText('没有主机引用此代理。')
                          else
                            const LText('这些主机在用它。删了以后它们会连不上，要重新选代理；不会自动改成直连：'),
                          for (final h in shown.hosts)
                            Text(
                                '${h.label} · ${h.username}@${h.hostname}:${h.port}'),
                        ]))),
                actions: [
                  ShunButton(
                      key: const ValueKey('proxy-delete-cancel'),
                      kind: ShunButtonKind.text,
                      onPressed: () => Navigator.pop(context, false),
                      label: '取消'),
                  ShunButton(
                      key: const ValueKey('proxy-delete-confirm'),
                      onPressed: () => Navigator.pop(context, true),
                      label: '删除')
                ],
              ));
      if (confirmed == true) await controller.deleteProxyProfile(shown);
    } on ProxyProfileChanged catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } catch (_) {
      if (mounted) setState(() => _error = '代理删除失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultControllerProvider);
    final profiles = state.data?.proxyProfiles ?? const <ProxyProfile>[];
    final enabled = !_busy && !state.loading && state.error == null;
    final credentials = {
      if (state.data case final vault?)
        for (final identity in vaultIdentities(vault))
          identity.id: identity.label,
    };
    return Scaffold(
        appBar: ShunAppBar(
            title: LText(widget.selecting ? '选择代理' : '代理管理'),
            actions: [
              ShunBarButton(
                  key: const ValueKey('proxy-create'),
                  onPressed: enabled ? () => _edit() : null,
                  icon: Icons.add,
                  tooltip: localized('新建代理'))
            ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (state.loading) const LinearProgressIndicator(),
          if (state.error != null) const LText('代理无法读取或已变化，请重新打开后再操作。'),
          if (_error != null)
            LText(_error!, key: const ValueKey('proxy-manager-error')),
          if (profiles.isEmpty && !state.loading && state.error == null)
            const EmptyState(icon: Icons.public, title: '还没有代理'),
          if (profiles.isNotEmpty)
            // 每个代理一行 Prism 卡片（R89）。选择模式点行返回 id；管理模式点行等于点「编辑」
            // （以前点行没反应；Prism 卡片行没有点按会被读屏报成「不可用的按钮」）。
            // 编辑、删除是行尾独立的图标按钮，key 沿用原来的。
            ShunSection(children: [
              for (final profile in profiles)
                ShunListRow(
                    key: ValueKey('proxy-profile-${profile.id}'),
                    leading: const Icon(Icons.public),
                    title: profile.label,
                    subtitle:
                        '${profile.config?.host ?? ''}:${profile.config?.port ?? ''}',
                    details: switch (
                        credentials[profile.data[proxyIdentityKey]]) {
                      final credential? => Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: ShunPill(credential),
                        ),
                      null => null,
                    },
                    enabled: enabled,
                    onTap: widget.selecting
                        ? () => Navigator.pop(context, profile.id)
                        : () => _edit(profile.id),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          key: ValueKey('proxy-edit-${profile.id}'),
                          tooltip: localized('编辑'),
                          onPressed: enabled ? () => _edit(profile.id) : null,
                          icon: const Icon(Icons.edit_outlined)),
                      IconButton(
                          key: ValueKey('proxy-delete-${profile.id}'),
                          tooltip: localized('删除'),
                          onPressed: enabled ? () => _delete(profile.id) : null,
                          icon: const Icon(Icons.delete_outline)),
                    ])),
            ]),
        ]));
  }
}
