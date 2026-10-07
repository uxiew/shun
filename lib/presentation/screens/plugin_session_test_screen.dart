import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';

import '../../application/plugin_discovery.dart';
import '../../application/plugin_registry.dart';
import '../../application/plugin_sessions.dart';
import '../localization/localized_widgets.dart';

/// 会话测试（X12）：插件作者只装本 App 的安装包，就能核对自己的插件走不走得完一次终端会话——
/// 连接（握手）→ 打开 80×24 会话 → 插件写回来什么 → 自己敲一行发过去 → 改尺寸 → 关闭，每一步照实写结果。
///
/// 本 App 不替插件发任何东西：输入只有用户在这页敲的那一行。
/// Kotlin 桥对一个插件只留一条连接，重新 connect 会断掉它正在跑的会话（X09 的坑），所以已经连着就沿用，
/// 离开时只关测试会话；连接是这页开的、而且没有别的会话在用，才断开。
class PluginSessionTestScreen extends ConsumerStatefulWidget {
  const PluginSessionTestScreen({super.key, required this.packageName});

  final String packageName;

  /// 这个插件为什么不能做会话测试；能做返回 null。
  ///
  /// 申请了临时会话凭据的插件（Mosh）不在这里开：它的会话要本 App 先经 SSH 在服务器上拿到这一次的一次性材料，
  /// 这页拿不出来。不开，而不是开一个没有材料的半截会话。
  static String? whyNot(PluginDescriptor? descriptor) {
    if (descriptor == null ||
        !descriptor.capabilities.contains(Capability.terminalSession)) {
      return '这个插件没有声明终端会话能力（terminal-session），没有会话可测。';
    }
    if (descriptor.permissions.contains(Permission.ownSessionEphemeralSecret)) {
      return '这个插件申请了「本会话的临时凭据」：它的会话要本 App 先经 SSH 在服务器上拿到这一次的一次性材料（比如 Mosh 的 key）才能开，会话测试拿不出这些材料，所以不在这里开。Mosh 插件请在主机列表里用 Mosh 协议连接。';
    }
    return null;
  }

  /// 显示插件输出时最多留这么多字节（只留最后的）：插件写多少都不会把这页撑爆。
  static const keepBytes = 16 * 1024;

  /// 把终端字节画成看得见的文字：\r\n 显示成换行，别的控制字符按 ^X 写出来（^[ 是 ESC），
  /// 作者能直接看出自己少写了 \r、多发了什么转义序列。
  static String render(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final out = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x0d && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0a) {
        out.write('\n');
        i++;
      } else if (c == 0x0a) {
        out.write('^J\n'); // 只有 \n 没有 \r：真终端上下一行不回到行首
      } else if (c == 0x09) {
        out.write('\t');
      } else if (c < 0x20) {
        out.write('^${String.fromCharCode(c + 0x40)}');
      } else if (c == 0x7f) {
        out.write('^?');
      } else {
        out.writeCharCode(c);
      }
    }
    return out.toString();
  }

  @override
  ConsumerState<PluginSessionTestScreen> createState() =>
      _PluginSessionTestScreenState();
}

class _PluginSessionTestScreenState
    extends ConsumerState<PluginSessionTestScreen> {
  final _input = TextEditingController();
  final _steps = <String>[];
  final _clock = Stopwatch();
  var _received = <int>[];
  var _receivedTotal = 0;
  PluginTerminalSession? _session;
  final _subscriptions = <StreamSubscription<Object?>>[];
  var _busy = false;
  var _appendCr = true;

  /// 连接是这页开的（原来没连着）。沿用别人在用的连接时为 false：离开时不替别人断开。
  var _opened = false;
  PluginDiscovery? _discovery;
  late final PluginSessionManager _manager;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(pluginSessionManagerProvider);
  }

  bool get _running =>
      _session != null &&
      (_session!.phase == SessionPhase.active ||
          _session!.phase == SessionPhase.opening);

  @override
  void dispose() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    // 先等测试会话关完（插件确认或 2 秒到）再考虑断开：反过来的话插件的 closed 到达时连接已经没了，
    // 插件页的「事件」里多一条看着像出错的「连接已关闭」。
    // 只断这页开的连接，而且那时没有别的会话（比如期间开的 Mosh 标签）在用它。
    final session = _session;
    final discovery = _opened ? _discovery : null;
    final manager = _manager;
    final package = widget.packageName;
    unawaited(() async {
      if (session != null) await session.close();
      final others = manager.sessions.where((s) => s.packageName == package);
      if (others.isEmpty) await discovery?.disconnect(package);
    }());
    _input.dispose();
    super.dispose();
  }

  void _step(String line) {
    if (!mounted) return;
    setState(() => _steps.add('${_clock.elapsedMilliseconds} ms  $line'));
  }

  /// 一步结果：译好的说明 + 原样的值（错误信息再经一次 [localized]，Kotlin 桥的报错有片段翻译）。
  void _say(String label, [Object? value = '']) =>
      _step('${localized(label)}${localized('$value')}');

  PluginEntry? _entry() => ref
      .read(pluginRegistryProvider)
      .where((e) => e.packageName == widget.packageName)
      .firstOrNull;

  Future<void> _start() async {
    final entry = _entry();
    if (_busy ||
        entry == null ||
        PluginSessionTestScreen.whyNot(entry.descriptor) != null) {
      return;
    }
    // 上一个测试会话的监听：它已经结束了，不等取消完成。
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    setState(() {
      _busy = true;
      _steps.clear();
      _received = [];
      _receivedTotal = 0;
      _session = null;
    });
    _clock
      ..reset()
      ..start();
    try {
      final discovery = await ref.read(pluginDiscoveryProvider.future);
      _discovery = discovery;
      final check = await discovery.check(entry);
      _opened = _opened || (check.ok && !check.reused);
      _say('连接：', check.message);
      if (!check.ok) return;
      final PluginTerminalSession session;
      try {
        session = await _manager.open(entry, cols: 80, rows: 24);
      } on Object catch (e) {
        _say('打开会话失败：', e);
        return;
      }
      _session = session;
      _say('打开会话：80×24，代次 ', session.generation);
      _subscriptions
        ..add(session.phases.listen(_onPhase))
        ..add(session.output.listen(_onOutput));
      // 插件的 active 可能在开始监听之前就到了。
      if (session.phase != SessionPhase.opening) _onPhase(session.phase);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onOutput(Uint8List bytes) {
    if (!mounted) return;
    setState(() {
      _receivedTotal += bytes.length;
      _received = [..._received, ...bytes];
      final excess = _received.length - PluginSessionTestScreen.keepBytes;
      if (excess > 0) _received = _received.sublist(excess);
    });
  }

  void _onPhase(SessionPhase phase) {
    final session = _session;
    if (session == null) return;
    final failure = session.failure;
    final reason = failure == null ? null : localized('；插件报告失败：');
    _step(switch (phase) {
          SessionPhase.opening => localized('打开中'),
          SessionPhase.active => localized('插件回报：运行中（active）'),
          SessionPhase.closing => localized('正在关闭：本 App 先关了自己这一端，再请插件关'),
          SessionPhase.closed => switch (session.stopConfirmed) {
              true => localized('已关闭：插件确认已停止（closed）'),
              false => localized('已关闭：2 秒内没等到插件确认（停止未确认）'),
              null => localized('已关闭：插件自己结束了会话（closed）'),
            },
          SessionPhase.interrupted => localized('中断：插件关了它那一端，没有先回报 closed'),
          SessionPhase.providerDied => localized('中断：插件进程没了'),
          SessionPhase.permissionRevoked =>
            localized('中断：本 App 断开了这个插件（停用、撤销批准或插件包变了）'),
        } +
        (reason == null ? '' : '$reason$failure'));
  }

  Future<void> _send() async {
    final session = _session;
    final text = _input.text + (_appendCr ? '\r' : '');
    if (session == null || !_running || text.isEmpty) return;
    final bytes = Uint8List.fromList(utf8.encode(text));
    try {
      await session.write(bytes);
      _say('发送字节数：', bytes.length);
      _say('内容：', PluginSessionTestScreen.render(bytes));
      _input.clear();
    } on Object catch (e) {
      _say('发送失败：', e);
    }
  }

  Future<void> _resize() async {
    final session = _session;
    if (session == null || session.phase != SessionPhase.active) return;
    final (cols, rows) = session.lastResize == '100x30' ? (80, 24) : (100, 30);
    final want = '${cols}x$rows';
    try {
      await session.resize(cols, rows);
    } on Object catch (e) {
      _say('改尺寸失败：', e);
      return;
    }
    _say('请插件改成 ', want);
    // 插件回报 resized:COLSxROWS 才算它知道了；等 2 秒。
    for (var i = 0; i < 20 && session.lastResize != want; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (session.lastResize == want) {
      _say('插件确认尺寸 ', want);
    } else {
      _say('2 秒内没收到插件的 resized 回报');
    }
  }

  Future<void> _close() async {
    final session = _session;
    if (session == null || session.phase.isTerminal) return;
    _step(localized('关闭会话'));
    await session.close();
  }

  String _title(PluginEntry? entry) {
    final name = entry?.descriptor?.displayName ?? widget.packageName;
    final title = localized('会话测试');
    return '$title · $name';
  }

  String _receivedLabel() {
    final label = localized('插件写回来的字节数（控制字符显示成 ^X，^[ 是 ESC）：');
    return '$label$_receivedTotal';
  }

  @override
  Widget build(BuildContext context) {
    final entry = ref
        .watch(pluginRegistryProvider)
        .where((e) => e.packageName == widget.packageName)
        .firstOrNull;
    final small = Theme.of(context).textTheme.bodySmall;
    final mono = small?.copyWith(fontFamily: 'monospace');
    final unavailable = PluginSessionTestScreen.whyNot(entry?.descriptor);
    final ready = entry?.status == PluginStatus.ready;
    final active = _session?.phase == SessionPhase.active;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title(entry)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const LText(
              '给插件作者核对插件用：连接、打开一个 80×24 的终端会话、看插件写回来什么、发一行字、改尺寸、关闭，每一步写在下面。本 App 不替插件发任何东西，只发你在下面敲的那一行。'),
          LText(
            '插件已经连着（比如有 Mosh 标签开着）就沿用那条连接、不重新握手，它正在跑的会话不受影响。离开这页只关测试会话；连接是这页开的、又没有别的会话在用，才断开。',
            style: small,
          ),
          if (!ready) LText('插件现在不是「可用」，先回详情页批准或启用。', style: small),
          if (ready && unavailable != null)
            LText(unavailable,
                key: const ValueKey('session-test-unavailable'), style: small),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const ValueKey('session-test-start'),
                onPressed: !ready || unavailable != null || _busy || _running
                    ? null
                    : _start,
                child: LText(_session == null ? '开始' : '重新开始'),
              ),
              OutlinedButton(
                key: const ValueKey('session-test-resize'),
                onPressed: active ? _resize : null,
                child: LText(_session?.lastResize == '100x30'
                    ? '改回 80×24'
                    : '改成 100×30'),
              ),
              OutlinedButton(
                key: const ValueKey('session-test-close'),
                onPressed: _running ? _close : null,
                child: const LText('关闭会话'),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          for (final line in _steps) SelectableText(line, style: small),
          const SizedBox(height: 12),
          Text(_receivedLabel(), style: small),
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            constraints: const BoxConstraints(minHeight: 80),
            child: SelectableText(
              PluginSessionTestScreen.render(_received),
              key: const ValueKey('session-test-output'),
              style: mono,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('session-test-input'),
                  controller: _input,
                  enabled: _running,
                  decoration: InputDecoration(labelText: localized('发给插件的一行')),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('session-test-send'),
                onPressed: _running ? _send : null,
                child: const LText('发送'),
              ),
            ],
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _appendCr,
            onChanged: (v) => setState(() => _appendCr = v ?? true),
            title: const LText(r'末尾加回车（\r，和终端里按回车一样）'),
          ),
        ],
      ),
    );
  }
}
