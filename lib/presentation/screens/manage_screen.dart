import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/port_forward_controller.dart';
import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/credential_identity.dart';
import '../../domain/host_summary.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../localization/localized_widgets.dart';
import '../widgets/connect_host.dart';
import '../widgets/credential_field.dart';
import '../widgets/empty_state.dart';
import '../widgets/host_address_line.dart';
import '../widgets/host_system_icon.dart';
import '../widgets/keychain_sheet.dart';
import '../widgets/port_forward_sheet.dart';
import '../widgets/proxy_profiles_page.dart';

/// 主机、凭据、代理、转发一个搜索框全搜到（F39、R79）。
///
/// 只负责找：点开还是各自原来的页面。这里再做一套编辑，两处迟早对不上。
class ManageScreen extends ConsumerStatefulWidget {
  const ManageScreen({super.key});

  @override
  ConsumerState<ManageScreen> createState() => _ManageScreenState();
}

class _ManageScreenState extends ConsumerState<ManageScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  void _openCredentials() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const KeychainSheet(),
      );

  void _openProxies() => _push(const ProxyProfilesPage());

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(vaultControllerProvider).data;
    final forwards = ref.watch(portForwardControllerProvider);
    final sessions = ref.watch(sessionControllerProvider).sessions;
    final query = _search.text.trim().toLowerCase();
    final searching = query.isNotEmpty;
    bool hits(List<String?> fields) =>
        fields.any((field) => (field ?? '').toLowerCase().contains(query));

    final allHosts = vault?.hosts ?? const <HostProfile>[];
    final allKeys = vault?.keys ?? const <SshKeyProfile>[];
    final hosts =
        allHosts.where((host) => hostMatchesQuery(host, query)).toList();
    final identities = vault == null
        ? const <IdentityProfile>[]
        : vaultIdentities(vault)
            .where((item) => hits([item.label, item.username]))
            .toList();
    final keys = allKeys.where((item) => hits([item.label])).toList();
    final proxies = (vault?.proxyProfiles ?? const <ProxyProfile>[])
        .where((item) => hits([item.label, item.config?.host]))
        .toList();
    final matchedForwards = forwards
        .where((item) => hits([item.describe(), item.hostLabel]))
        .toList();
    final nothing = searching &&
        hosts.isEmpty &&
        identities.isEmpty &&
        keys.isEmpty &&
        proxies.isEmpty &&
        matchedForwards.isEmpty;

    return Scaffold(
      appBar: AppBar(title: const LText('管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          TextField(
            key: const ValueKey('manage-search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: localized('搜索主机、凭据、代理、转发'),
            ),
          ),
          if (nothing)
            const EmptyState(icon: Icons.search_off, title: '没有匹配的项目'),
          // 搜索时没命中的分组不占地方；不搜时都在，才看得出还能管哪些。
          if (!searching || hosts.isNotEmpty) ...[
            const _Section('主机'),
            if (hosts.isEmpty) const _Nothing('在「连接」页添加'),
            for (final host in hosts)
              ListTile(
                key: ValueKey('manage-host-${host.id}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: HostSystemIcon(host: host, size: 40),
                title: Text(host.label),
                subtitle: HostAddressLine(host),
                onTap: () => editSavedHost(context, ref, host),
              ),
          ],
          if (!searching || identities.isNotEmpty || keys.isNotEmpty) ...[
            _Section(
              '凭据',
              openKey: const ValueKey('manage-open-credentials'),
              onOpen: _openCredentials,
            ),
            if (identities.isEmpty && keys.isEmpty) const _Nothing('还没有凭据'),
            for (final identity in identities)
              ListTile(
                key: ValueKey('manage-identity-${identity.id}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: CircleAvatar(
                  child: Icon(credentialIcon(identity, allKeys)),
                ),
                title: Text(identity.label),
                subtitle: Text(credentialDetail(identity, allKeys)),
                onTap: _openCredentials,
              ),
            for (final key in keys)
              ListTile(
                key: ValueKey('manage-key-${key.id}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: const CircleAvatar(child: Icon(Icons.key_outlined)),
                title: Text(key.label),
                onTap: _openCredentials,
              ),
          ],
          if (!searching || proxies.isNotEmpty) ...[
            _Section(
              '代理',
              openKey: const ValueKey('manage-open-proxies'),
              onOpen: _openProxies,
            ),
            if (proxies.isEmpty) const _Nothing('还没有代理'),
            for (final proxy in proxies)
              ListTile(
                key: ValueKey('manage-proxy-${proxy.id}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: const CircleAvatar(child: Icon(Icons.alt_route)),
                title: Text(proxy.label),
                subtitle: Text(
                  '${proxy.config?.host ?? ''}:${proxy.config?.port ?? ''}',
                ),
                onTap: _openProxies,
              ),
          ],
          if (!searching || matchedForwards.isNotEmpty) ...[
            const _Section('转发'),
            if (matchedForwards.isEmpty) const _Nothing('在终端或主机菜单里开'),
            for (final forward in matchedForwards)
              _forwardTile(
                forward,
                sessions
                    .where((session) => session.id == forward.sessionId)
                    .firstOrNull,
              ),
          ],
        ],
      ),
    );
  }

  /// 转发跟着连接走，不存盘。连接没了就只能看，开新的要先连上。
  Widget _forwardTile(ActivePortForward item, ActiveTerminalSession? session) =>
      ListTile(
        key: ValueKey('manage-forward-${item.id}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: CircleAvatar(
          child: Icon(item.running ? Icons.link : Icons.link_off),
        ),
        title: LText(item.describe()),
        subtitle: LText([
          if (item.hostLabel != null) item.hostLabel!,
          if (!item.running) localized(item.endedReason!),
        ].join(' · ')),
        onTap: session == null
            ? null
            : () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => PortForwardSheet(session: session),
                ),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.title, {this.onOpen, this.openKey});

  final String title;

  /// 打开这一类自己的页面，新建也在那里。
  final VoidCallback? onOpen;
  final Key? openKey;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: LText(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (onOpen != null)
              TextButton(
                key: openKey,
                onPressed: onOpen,
                child: const LText('全部'),
              ),
          ],
        ),
      );
}

class _Nothing extends StatelessWidget {
  const _Nothing(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: LText(text, style: Theme.of(context).textTheme.bodySmall),
      );
}
