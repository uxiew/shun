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
import '../widgets/empty_state.dart';
import '../widgets/host_address_line.dart';
import '../widgets/host_system_icon.dart';
import '../widgets/keychain_sheet.dart';
import '../widgets/port_forward_sheet.dart';
import '../widgets/proxy_profiles_page.dart';

/// 主机、凭据、代理、转发各一个 tab，这一类的增删改连都在 tab 里（R72，学 LobiShell）。
///
/// 以前四类摞成一条长列表，只能找不能干，点开又是另一页（所有者 11-02：莫名其妙）。
/// 搜索框比 LobiShell 多一点：一个框搜四类（R79），tab 上写命中几条，当前 tab 没有就跳到有的那个。
class ManageScreen extends ConsumerStatefulWidget {
  const ManageScreen({super.key});

  @override
  ConsumerState<ManageScreen> createState() => _ManageScreenState();
}

class _ManageScreenState extends ConsumerState<ManageScreen>
    with SingleTickerProviderStateMixin {
  static const _labels = ['主机', '凭据', '代理', '转发'];
  static const _keys = ['hosts', 'credentials', 'proxies', 'forwards'];

  late final _tabs = TabController(length: _labels.length, vsync: this)
    // 右下角的 ＋ 跟着 tab 变。
    ..addListener(() => setState(() {}));
  final _search = TextEditingController();
  final _proxyList = GlobalKey<ProxyProfilesListState>();

  String get _query => _search.text.trim().toLowerCase();

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  List<HostProfile> _hosts() =>
      (ref.read(vaultControllerProvider).data?.hosts ?? const <HostProfile>[])
          .where((host) => hostMatchesQuery(host, _query))
          .toList();

  List<ActivePortForward> _forwards() {
    final query = _query;
    return ref
        .read(portForwardControllerProvider)
        .where((item) => [item.describe(), item.hostLabel]
            .any((field) => (field ?? '').toLowerCase().contains(query)))
        .toList();
  }

  /// 每个 tab 命中几条，顺序同 [_labels]。
  List<int> _counts() {
    final vault = ref.read(vaultControllerProvider).data;
    final query = _query;
    return [
      _hosts().length,
      vault == null
          ? 0
          : vaultIdentities(vault)
                  .where((item) => identityMatchesQuery(item, query))
                  .length +
              vault.keys.where((item) => keyMatchesQuery(item, query)).length,
      vault == null
          ? 0
          : vault.proxyProfiles
              .where((item) => proxyMatchesQuery(item, query))
              .length,
      _forwards().length,
    ];
  }

  void _onSearch(String _) {
    final counts = _counts();
    if (_query.isNotEmpty && counts[_tabs.index] == 0) {
      final first = counts.indexWhere((count) => count > 0);
      if (first >= 0) _tabs.animateTo(first);
    }
    setState(() {});
  }

  List<ActiveTerminalSession> _liveSsh() => ref
      .read(sessionControllerProvider)
      .sessions
      .where((session) => session.connected && session.isSsh)
      .toList();

  void _add() => switch (_tabs.index) {
        0 => editSavedHost(context, ref, null),
        1 => showKeychainAddSheet(context, ref),
        2 => _proxyList.currentState?.create(),
        _ => _addForward(),
      };

  /// 转发跟着连接走：连着几台，先选一台（学 LobiShell，只连着一台就不问）。
  Future<void> _addForward() async {
    final live = _liveSsh();
    final session = live.length == 1
        ? live.single
        : await showDialog<ActiveTerminalSession>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const LText('选一个连接'),
              children: [
                for (final item in live)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, item),
                    child: Text(item.host.label),
                  ),
              ],
            ),
          );
    if (session == null || !mounted) return;
    await _openForwards(session);
  }

  Future<void> _openForwards(ActiveTerminalSession session) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => PortForwardSheet(session: session),
      );

  @override
  Widget build(BuildContext context) {
    ref.watch(vaultControllerProvider);
    ref.watch(portForwardControllerProvider);
    final sessions = ref.watch(sessionControllerProvider).sessions;
    final searching = _query.isNotEmpty;
    final counts = _counts();
    final canAdd = _tabs.index != 3 || _liveSsh().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const LText('管理'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(112),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: TextField(
                  key: const ValueKey('manage-search'),
                  controller: _search,
                  onChanged: _onSearch,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: localized('搜索主机、凭据、代理、转发'),
                  ),
                ),
              ),
              TabBar(
                controller: _tabs,
                tabs: [
                  for (var i = 0; i < _labels.length; i++)
                    Tab(
                      key: ValueKey('manage-tab-${_keys[i]}'),
                      text: searching
                          ? '${localized(_labels[i])} ${counts[i]}'
                          : localized(_labels[i]),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: canAdd
          ? FloatingActionButton(
              key: const ValueKey('manage-add'),
              tooltip: localized('添加'),
              onPressed: _add,
              child: const Icon(Icons.add),
            )
          : null,
      body: TabBarView(
        controller: _tabs,
        children: [
          _hostTab(),
          KeychainList(query: _query),
          ProxyProfilesList(key: _proxyList, query: _query),
          _forwardTab(sessions),
        ],
      ),
    );
  }

  Widget _hostTab() {
    final hosts = _hosts();
    if (hosts.isEmpty) {
      return EmptyState(
        icon: _query.isEmpty ? Icons.dns_outlined : Icons.search_off,
        title: _query.isEmpty ? '还没有主机' : '没有匹配的项目',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
      children: [
        for (final host in hosts)
          ListTile(
            key: ValueKey('manage-host-${host.id}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: HostSystemIcon(host: host, size: 40),
            title: Text(host.label),
            subtitle: HostAddressLine(host),
            onTap: () => editSavedHost(context, ref, host, canDelete: true),
            trailing: TextButton(
              key: ValueKey('manage-connect-${host.id}'),
              onPressed: () =>
                  connectHostFromList(context, host, leavePushedPages: true),
              child: const LText('连接'),
            ),
          ),
      ],
    );
  }

  Widget _forwardTab(List<ActiveTerminalSession> sessions) {
    final forwards = _forwards();
    if (forwards.isEmpty) {
      return EmptyState(
        icon: _query.isEmpty ? Icons.swap_horiz : Icons.search_off,
        title: _query.isNotEmpty
            ? '没有匹配的项目'
            : _liveSsh().isEmpty
                ? '连上主机后才能开转发'
                : '还没有转发',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
      children: [
        for (final forward in forwards)
          _forwardTile(
            forward,
            sessions
                .where((session) => session.id == forward.sessionId)
                .firstOrNull,
          ),
      ],
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
        onTap: session == null ? null : () => _openForwards(session),
      );
}
