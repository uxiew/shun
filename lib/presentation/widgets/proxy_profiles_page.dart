import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../domain/proxy_profiles.dart';
import '../localization/localized_widgets.dart';
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
                          const LText(
                              '以下主机引用此代理。删除后会因代理缺失而拒绝连接，请重新选择代理；不会自动改成直连。'),
                          if (shown.hosts.isEmpty) const LText('没有主机引用此代理。'),
                          for (final h in shown.hosts)
                            Text(
                                '${h.label} · ${h.username}@${h.hostname}:${h.port}'),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const LText('取消')),
                  TextButton(
                      key: const ValueKey('proxy-delete-confirm'),
                      onPressed: () => Navigator.pop(context, true),
                      child: const LText('删除'))
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
    return Scaffold(
        appBar:
            AppBar(title: LText(widget.selecting ? '选择代理' : '代理管理'), actions: [
          TextButton(
              key: const ValueKey('proxy-create'),
              onPressed: enabled ? () => _edit() : null,
              child: const LText('新建代理'))
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (state.loading) const LinearProgressIndicator(),
          if (state.error != null) const LText('代理无法读取或已变化，请重新打开后再操作。'),
          if (_error != null)
            LText(_error!, key: const ValueKey('proxy-manager-error')),
          if (profiles.isEmpty && !state.loading)
            const LText('还没有代理，点「新建代理」添加。'),
          for (final profile in profiles)
            Card(
                child: Column(children: [
              ListTile(
                  key: ValueKey('proxy-profile-${profile.id}'),
                  leading: const Icon(Icons.public),
                  title: Text(profile.label),
                  subtitle: Text(
                      '${profile.config?.host ?? ''}:${profile.config?.port ?? ''}'),
                  onTap: widget.selecting && enabled
                      ? () => Navigator.pop(context, profile.id)
                      : null),
              Wrap(spacing: 8, children: [
                TextButton(
                    key: ValueKey('proxy-edit-${profile.id}'),
                    onPressed: enabled ? () => _edit(profile.id) : null,
                    child: const LText('编辑')),
                TextButton(
                    key: ValueKey('proxy-delete-${profile.id}'),
                    onPressed: enabled ? () => _delete(profile.id) : null,
                    child: const LText('删除')),
              ]),
            ])),
        ]));
  }
}
