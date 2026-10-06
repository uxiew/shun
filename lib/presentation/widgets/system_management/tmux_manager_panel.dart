import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

import '../../../domain/models/host.dart';
import '../../../domain/tmux/tmux_target.dart';
import '../../../infrastructure/ssh/ssh_service.dart';
import '../../../infrastructure/tmux/tmux_protocol.dart';
import '../../../infrastructure/tmux/tmux_service.dart';

/// tmux 面板（R21）。所有查询和操作都走打开面板的这个标签自己的 SSH 连接。
///
/// - 查询只读：不启动 server，不建目录；版本不在实测范围、输出不可信时只显示，不给操作。
/// - 附着、结束、鼠标开关都按完整目标（server 代次 + session ID + 创建时间）在远端核对后才做，
///   不按名字；新建是单独的显式动作，只建不附着。
/// - 不改 tmux.conf；鼠标只能对单个会话显式打开，写明作用范围（TMX07）。
class TmuxManagerPanel extends StatefulWidget {
  const TmuxManagerPanel({
    super.key,
    required this.session,
    required this.snippets,
    required this.onAttach,
    this.service = const TmuxService(),
    this.refreshInterval = const Duration(seconds: 5),
  });

  final ActiveTerminalSession session;
  final List<CommandSnippet> snippets;
  final Future<void> Function(TmuxTarget target) onAttach;
  final TmuxService service;
  final Duration refreshInterval;

  @override
  State<TmuxManagerPanel> createState() => _TmuxManagerPanelState();
}

class _TmuxManagerPanelState extends State<TmuxManagerPanel> {
  final _search = TextEditingController();
  Timer? _timer;
  TmuxSocketSpec _socket = const TmuxSocketSpec.standard();
  TmuxProbe? _probe;
  bool _loading = true;
  bool _refreshing = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    // 本标签附着在某个 tmux 上时，默认看它所在的那个 socket。
    _socket = widget.session.tmux?.target.socket ?? _socket;
    _search.addListener(_rebuild);
    _refresh();
    _timer = Timer.periodic(widget.refreshInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search
      ..removeListener(_rebuild)
      ..dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final client = widget.session.sshClient;
    if (_refreshing || !widget.session.connected || client == null) return;
    _refreshing = true;
    final socket = _socket;
    try {
      final probe = await widget.service.probe(client, socket);
      if (!mounted || socket != _socket) return;
      setState(() {
        _probe = probe;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    } finally {
      _refreshing = false;
    }
  }

  TmuxTarget _targetOf(TmuxSessionRow row) {
    final probe = _probe!;
    return targetOf(
      row,
      hostKey: tmuxHostKeyOf(widget.session),
      unixUser: probe.unixUser,
      uid: probe.uid!,
      socket: _socket,
    );
  }

  List<TmuxSessionRow> get _visibleSessions {
    // 只有列表可信（ready）时才列出会话：读失败、版本不在范围时即便有行也不给操作入口。
    final probe = _probe;
    final sessions = probe?.availability == TmuxAvailability.ready
        ? probe!.sessions
        : const <TmuxSessionRow>[];
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return sessions;
    return sessions
        .where(
          (row) =>
              row.name.toLowerCase().contains(query) ||
              row.sessionId.contains(query) ||
              row.group.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  Future<void> _chooseSocket() async {
    final chosen = await showDialog<TmuxSocketSpec>(
      context: context,
      builder: (context) => _SocketDialog(initial: _socket),
    );
    if (chosen == null || chosen == _socket || !mounted) return;
    setState(() {
      _socket = chosen;
      _probe = null;
      _loading = true;
    });
    await _refresh();
  }

  Future<void> _createSession() async {
    final probe = _probe;
    final client = widget.session.sshClient;
    if (probe == null || !probe.canOperate || client == null) return;
    final result = await showDialog<({String name, String command})>(
      context: context,
      builder: (context) => _CreateDialog(
        snippets: widget.snippets,
        socket: _socket,
        serverRunning: probe.availability == TmuxAvailability.ready,
      ),
    );
    if (result == null || !mounted) return;
    try {
      final target = await widget.service.create(
        client,
        hostKey: tmuxHostKeyOf(widget.session),
        unixUser: probe.unixUser,
        uid: probe.uid!,
        socket: _socket,
        name: result.name,
        startupCommand: result.command,
      );
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              LText('新会话 ${target.displayName}（${target.sessionId}）已建好，没有附着'),
          action: SnackBarAction(
            label: localized('附着'),
            onPressed: () => widget.onAttach(target),
          ),
        ),
      );
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _killSession(TmuxSessionRow row) async {
    final client = widget.session.sshClient;
    if (client == null) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.warning_amber_outlined),
            title: const LText('结束 tmux 会话？'),
            content: LText(
              '${row.name}（${row.sessionId}）里的所有窗口和程序都会被终止，不能撤销。'
              '只结束这一个：按 ID 核对后才结束，名字相近的其他会话不受影响。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const LText('结束会话'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      await widget.service.kill(client, _targetOf(row));
      await _refresh();
    } catch (error) {
      if (mounted) _showError(error);
      await _refresh();
    }
  }

  Future<void> _toggleMouse(TmuxSessionRow row) async {
    final client = widget.session.sshClient;
    if (client == null) return;
    final enable = !row.mouse;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: LText(enable ? '为这个会话打开鼠标？' : '取消这个会话的鼠标设置？'),
            content: LText(
              enable
                  ? '${row.name}（${row.sessionId}）：只改这一个会话的 mouse 选项，不改 tmux.conf，'
                      '也不改全局设置；tmux server 重启后失效。打开后在这个会话里滑动、点按会交给 tmux 处理。'
                  : '${row.name}（${row.sessionId}）：去掉这个会话自己的 mouse 设置，回到全局设置'
                      '（全局如果是开着的，鼠标仍然开着）。不改 tmux.conf。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: LText(enable ? '打开' : '取消设置'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      await widget.service.setMouse(client, _targetOf(row), enable: enable);
      await _refresh();
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _detachThisTab() async {
    final binding = widget.session.tmux;
    final client = widget.session.sshClient;
    if (binding == null || client == null) return;
    try {
      await widget.service.detach(client, binding);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LText('已分离本标签；tmux 会话还在远端')),
      );
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: LText('$error')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final probe = _probe;
    final values = _visibleSessions;
    final bound = widget.session.tmux;
    final operable = probe?.canOperate == true;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: LInputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索会话',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: operable ? _createSession : null,
                icon: const Icon(Icons.add),
                label: const LText('新建'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                avatar: const Icon(Icons.terminal, size: 18),
                label: LText(_versionLabel(probe)),
              ),
              ActionChip(
                avatar: const Icon(Icons.cable, size: 18),
                label: LText(_socket.describe()),
                tooltip: localized('换 socket'),
                onPressed: _chooseSocket,
              ),
              if (probe != null && probe.unixUser.isNotEmpty)
                Chip(
                  avatar: const Icon(Icons.person_outline, size: 18),
                  label: LText(probe.unixUser),
                ),
              IconButton(
                tooltip: localized('刷新'),
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (bound != null)
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: ListTile(
              leading: const Icon(Icons.link),
              title: LText(
                '本标签附着在 ${bound.target.displayName}（${bound.target.sessionId}）',
              ),
              subtitle: LText(
                '客户端 ${bound.clientTty} · ${bound.target.socket.describe()}',
              ),
              trailing: TextButton(
                onPressed: widget.session.connected ? _detachThisTab : null,
                child: const LText('分离本标签'),
              ),
            ),
          ),
        for (final notice in _notices(probe))
          MaterialBanner(
            content: LText(notice),
            actions: [
              TextButton(onPressed: _refresh, child: const LText('重试')),
            ],
          ),
        Expanded(
          child: values.isEmpty && !_loading
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.terminal_outlined, size: 48),
                        const SizedBox(height: 10),
                        LText(
                          operable ? '没有 tmux 会话' : '这里没有可操作的 tmux 会话',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
                  itemCount: values.length,
                  itemBuilder: (context, index) {
                    final row = values[index];
                    return _SessionCard(
                      key: ValueKey('${row.server.pid}${row.sessionId}'),
                      row: row,
                      operable: operable,
                      boundHere: bound != null &&
                          bound.target.server == row.server &&
                          bound.target.sessionId == row.sessionId,
                      boundClientTty: bound?.clientTty,
                      loadDetails: () => widget.service.details(
                        widget.session.sshClient!,
                        _targetOf(row),
                      ),
                      onAttach: () => widget.onAttach(_targetOf(row)),
                      onKill: () => _killSession(row),
                      onToggleMouse: () => _toggleMouse(row),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _versionLabel(TmuxProbe? probe) {
    if (probe == null) return 'tmux';
    if (probe.availability == TmuxAvailability.missing) return '没有 tmux';
    return probe.versionLine.isEmpty ? 'tmux' : probe.versionLine;
  }

  List<String> _notices(TmuxProbe? probe) {
    final error = _error;
    if (error != null) return ['tmux 读取失败：$error'];
    if (probe == null) return const [];
    return [
      switch (probe.availability) {
        TmuxAvailability.missing => '远端没有 tmux。没有自动安装；这个标签照常是普通 SSH。',
        TmuxAvailability.unsupported =>
          '${probe.problem ?? probe.versionLine}。只在 tmux $tmuxTestedVersions 上实测过，'
              '这里不提供附着、新建和结束；在终端里照常可以自己用 tmux。',
        TmuxAvailability.noServer =>
          '${probe.socketPath} 上没有在运行的 tmux server（查询不会启动它）。新建会话时才会启动。',
        TmuxAvailability.failed =>
          '读不了 tmux 会话列表：${probe.problem}。为安全起见不提供任何操作。',
        TmuxAvailability.ready => '',
      },
      if (probe.truncated) '会话太多，只显示了前 $tmuxMaxSessions 个会话。',
      if (probe.skippedLines > 0 &&
          probe.availability == TmuxAvailability.ready)
        '有些输出认不出来，已忽略（共 ${probe.skippedLines} 行）。',
    ].where((value) => value.isNotEmpty).toList(growable: false);
  }
}

class _SessionCard extends StatefulWidget {
  const _SessionCard({
    super.key,
    required this.row,
    required this.operable,
    required this.boundHere,
    required this.boundClientTty,
    required this.loadDetails,
    required this.onAttach,
    required this.onKill,
    required this.onToggleMouse,
  });

  final TmuxSessionRow row;
  final bool operable;
  final bool boundHere;
  final String? boundClientTty;
  final Future<({List<TmuxWindowRow> windows, List<TmuxClientRow> clients})>
      Function() loadDetails;
  final VoidCallback onAttach;
  final VoidCallback onKill;
  final VoidCallback onToggleMouse;

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  ({List<TmuxWindowRow> windows, List<TmuxClientRow> clients})? _details;
  bool _loading = false;
  Object? _error;

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final value = await widget.loadDetails();
      if (!mounted) return;
      setState(() {
        _details = value;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final created = DateTime.fromMillisecondsSinceEpoch(row.created * 1000);
    return Card(
      child: ExpansionTile(
        onExpansionChanged: (expanded) {
          if (expanded) _load();
        },
        leading: CircleAvatar(child: LText('${row.windows}')),
        title: LText(row.name),
        subtitle: LText(
          [
            row.sessionId,
            '${row.windows} 个窗口',
            '${row.attached} 个客户端',
            '前缀键 ${row.prefix}',
            row.mouse ? '鼠标开' : '鼠标关',
            DateFormat('MM-dd HH:mm').format(created),
            if (widget.boundHere) '本标签',
          ].join(' · '),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: localized('在新标签里附着'),
              onPressed: widget.operable ? widget.onAttach : null,
              icon: const Icon(Icons.login),
            ),
            PopupMenuButton<String>(
              enabled: widget.operable,
              tooltip: localized('更多'),
              onSelected: (value) => switch (value) {
                'mouse' => widget.onToggleMouse(),
                'kill' => widget.onKill(),
                _ => null,
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'mouse',
                  child: LText(row.mouse ? '取消这个会话的鼠标设置' : '为这个会话打开鼠标'),
                ),
                const PopupMenuItem(
                  value: 'kill',
                  child: LText('结束会话'),
                ),
              ],
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            ListTile(
              dense: true,
              leading: const Icon(Icons.error_outline),
              title: LText('读取详情失败：$_error'),
              trailing: IconButton(
                tooltip: localized('重试'),
                onPressed: _load,
                icon: const Icon(Icons.refresh),
              ),
            ),
          if (_details case final details?) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: LText('窗口', style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final window in details.windows)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  window.active
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                title: LText('#${window.index} ${window.name}'),
                subtitle: LText('${window.panes} 个窗格'),
              ),
            const Divider(),
            Align(
              alignment: Alignment.centerLeft,
              child: LText(
                '已附着的客户端',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (details.clients.isEmpty)
              const ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: LText('没有客户端附着'),
              )
            else
              for (final client in details.clients)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices, size: 19),
                  title: LText(client.tty),
                  subtitle: LText(
                    client.tty == widget.boundClientTty
                        ? 'pid ${client.pid} · 本标签'
                        : 'pid ${client.pid}',
                  ),
                ),
          ],
        ],
      ),
    );
  }
}

class _SocketDialog extends StatefulWidget {
  const _SocketDialog({required this.initial});

  final TmuxSocketSpec initial;

  @override
  State<_SocketDialog> createState() => _SocketDialogState();
}

class _SocketDialogState extends State<_SocketDialog> {
  late TmuxSocketKind _kind = widget.initial.kind;
  late final _value = TextEditingController(text: widget.initial.value);
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final spec = switch (_kind) {
        TmuxSocketKind.standard => const TmuxSocketSpec.standard(),
        TmuxSocketKind.named => TmuxSocketSpec.named(_value.text),
        TmuxSocketKind.path => TmuxSocketSpec.path(_value.text),
      };
      Navigator.pop(context, spec);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const LText('用哪个 tmux server'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<TmuxSocketKind>(
                segments: const [
                  ButtonSegment(
                    value: TmuxSocketKind.standard,
                    label: LText('默认'),
                  ),
                  ButtonSegment(
                    value: TmuxSocketKind.named,
                    label: LText('-L 名称'),
                  ),
                  ButtonSegment(
                    value: TmuxSocketKind.path,
                    label: LText('-S 路径'),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (value) => setState(() {
                  _kind = value.single;
                  _error = null;
                }),
              ),
              const SizedBox(height: 12),
              if (_kind != TmuxSocketKind.standard)
                TextField(
                  controller: _value,
                  autofocus: true,
                  decoration: LInputDecoration(
                    labelText: _kind == TmuxSocketKind.named
                        ? 'socket 名称'
                        : 'socket 路径',
                    hintText: _kind == TmuxSocketKind.named
                        ? '例如 work'
                        : '例如 /run/user/1000/tmux.sock',
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              const SizedBox(height: 8),
              const LText(
                '默认是 tmux 不带参数时用的那个（/tmp/tmux-你的 uid/default）。'
                '如果你在 shell 配置里改了 TMUX_TMPDIR，这里看不到，请填 -S 路径。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(onPressed: _submit, child: const LText('确定')),
        ],
      );
}

class _CreateDialog extends StatefulWidget {
  const _CreateDialog({
    required this.snippets,
    required this.socket,
    required this.serverRunning,
  });

  final List<CommandSnippet> snippets;
  final TmuxSocketSpec socket;
  final bool serverRunning;

  @override
  State<_CreateDialog> createState() => _CreateDialogState();
}

class _CreateDialogState extends State<_CreateDialog> {
  final _name = TextEditingController();
  final _command = TextEditingController();
  CommandSnippet? _snippet;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final name = validateNewSessionName(_name.text);
      if (_command.text.trim().length > tmuxStartupMaxLength) {
        throw const FormatException('启动命令太长');
      }
      Navigator.pop(context, (name: name, command: _command.text.trim()));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const LText('新建 tmux 会话'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                decoration: LInputDecoration(
                  labelText: '会话名称',
                  hintText: '例如 work',
                  errorText: _error,
                ),
              ),
              const SizedBox(height: 12),
              if (widget.snippets.isNotEmpty) ...[
                DropdownButtonFormField<CommandSnippet>(
                  initialValue: _snippet,
                  isExpanded: true,
                  decoration: LInputDecoration(
                    labelText: '从命令片段选择（可选）',
                  ),
                  items: widget.snippets
                      .map(
                        (snippet) => DropdownMenuItem(
                          value: snippet,
                          child: LText(
                            snippet.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (snippet) {
                    setState(() => _snippet = snippet);
                    if (snippet != null) _command.text = snippet.command;
                  },
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _command,
                minLines: 2,
                maxLines: 4,
                decoration: LInputDecoration(
                  labelText: '启动命令（可选）',
                  hintText: '例如 cd /srv/app && ./start.sh',
                ),
              ),
              const SizedBox(height: 8),
              LText(
                widget.serverRunning
                    ? '只新建、不附着。启动命令会原样输入新会话的 shell 并回车一次。'
                    : '只新建、不附着。${widget.socket.describe()} 上还没有 tmux server，'
                        '新建会启动它（会读你的 tmux.conf）。启动命令会原样输入新会话的 shell 并回车一次。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(onPressed: _submit, child: const LText('创建')),
        ],
      );
}
