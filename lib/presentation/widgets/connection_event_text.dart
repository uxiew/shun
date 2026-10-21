import '../../application/connection_diagnosis.dart';
import '../../application/connection_events.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../localization/localized_widgets.dart';

/// 把连接记录变成给人看的字（R25）：记录页和导出用这一份，两处说法不会对不上。
///
/// 带数字的句子写成模板（`{n}`），整句翻译以后再填数：英文界面下也是整句，不会被拆碎的片段替换弄乱。
String _t(String template, [Map<String, Object> values = const {}]) {
  var text = localized(template);
  for (final entry in values.entries) {
    text = text.replaceAll('{${entry.key}}', '${entry.value}');
  }
  return text;
}

// 两段长说明各写成一个字面量（不拆行）：翻译表按整句查，拆成几段拼起来就查不到了。
const connectionTimingNote =
    '用时是各阶段从开始到下一阶段开始的时间，按手机上不受对时影响的时钟算，不是网络延迟（ping）。经代理时，代理之后那一段 App 看不到，算在「连代理，由代理连过去」里；等你确认指纹、输入验证码的时间单独标出。';

const connectionLogScope =
    '只记在这台手机上：每次连接走到哪一步、每步多久、失败在哪、断线后自动恢复试了几次。不记地址、用户名、密码、私钥、报错原话，也不记你输入的和屏幕上的内容；不上传。每台最多 200 条、一共最多 1000 条，7 天后自动删掉。';

String connectionEventTitle(ConnectionEvent event) => switch (event.kind) {
      ConnectionEventKind.open => _t('新开连接'),
      ConnectionEventKind.reconnect => _t('重新连接'),
      ConnectionEventKind.restore => event.attempt == null
          ? _t('自动恢复')
          : _t('自动恢复（第 {n} 次）', {'n': event.attempt!}),
      ConnectionEventKind.switchTransport => _t('切换连接方式'),
      ConnectionEventKind.probe => _t('测试连接'),
      ConnectionEventKind.drop => _t('连接断开'),
      ConnectionEventKind.recoveryStopped => _t('自动恢复停了'),
    };

/// 结果一句话。不只靠颜色和图标说成败（UX02）。
String connectionEventOutcome(ConnectionEvent event) => switch (event.kind) {
      ConnectionEventKind.drop => switch (event.dropReason) {
          ConnectionDropReason.closed => _t('连接被关了（对方关闭或网络断开，App 分不出是哪种）'),
          ConnectionDropReason.exited => _t('远端 shell 退出了'),
          ConnectionDropReason.noResponse => _t('App 探了一下，期限内没回应'),
          ConnectionDropReason.ended => _t('插件会话结束了'),
          null => _t('原因未知'),
        },
      ConnectionEventKind.recoveryStopped => switch (event.stopReason) {
          RecoveryStopReason.window => _t('断线后 2 分钟内没恢复上'),
          RecoveryStopReason.locked => _t('手机锁着，后台不重新登录'),
          RecoveryStopReason.needsUser => _t('撞上了要你处理的错，不再自动重试'),
          null => _t('原因未知'),
        },
      _ => switch (event.outcome) {
          ConnectionOutcome.connected => _t('连上了'),
          ConnectionOutcome.cancelled => _t('已取消'),
          ConnectionOutcome.failed => _t('失败：{reason}', {
              'reason': localized(
                  failureLabel(event.failure ?? ConnectionFailureKind.other)),
            }),
          null => _t('结果未知'),
        },
    };

/// 「下一步」；没什么要做的（连上了、取消了）返回 null。都只是建议，没有一条会替用户改路线或改成直连。
String? connectionEventNextStep(ConnectionEvent event) => switch (event.kind) {
      ConnectionEventKind.drop => switch (event.protocol) {
          HostProtocol.mosh ||
          HostProtocol.plugin =>
            _t('Mosh 和插件会话断了不自动重连：要继续就在标签上点「重新连接」，会开一个新会话。'),
          _ => _t('断开后 App 自己试着恢复（最多 2 分钟），结果在后面几条。'),
        },
      ConnectionEventKind.recoveryStopped => switch (event.stopReason) {
          RecoveryStopReason.needsUser => _t('看前一条失败的「下一步」；处理好以后在标签上点「重新连接」。'),
          _ => _t('回到 App 会再试一轮，也可以在标签上点「重新连接」。'),
        },
      _ when event.outcome == ConnectionOutcome.failed => localized(
          failureNextStep(event.failure ?? ConnectionFailureKind.other)),
      _ => null,
    };

String connectionProtocolLabel(HostProtocol? protocol) => switch (protocol) {
      HostProtocol.ssh => 'SSH',
      HostProtocol.mosh => 'Mosh',
      HostProtocol.telnet => 'Telnet',
      HostProtocol.plugin => _t('插件主机'),
      _ => _t('未知协议'),
    };

/// 这一跳在路线里是什么角色：导出时只写这个，不写名字。
String connectionHopRole(int hop, int hopCount) =>
    hopCount <= 1 || hop >= hopCount - 1
        ? _t('目标')
        : _t('跳板 {n}', {'n': hop + 1});

String connectionStepLabel(ConnectionStep step) => switch (step) {
      ConnectionStep.dial => _t('TCP 连接（含域名解析）'),
      ConnectionStep.proxy => _t('连代理，由代理连过去'),
      ConnectionStep.handshake => _t('SSH 握手、核对指纹、登录'),
      ConnectionStep.check => _t('等你完成 Tailscale check'),
      ConnectionStep.forward => _t('经这一跳转发到下一跳'),
      ConnectionStep.shell => _t('打开终端'),
      ConnectionStep.pty => _t('检查远端终端'),
      ConnectionStep.plugin => _t('核对本机 Mosh 插件'),
      ConnectionStep.moshServer => _t('经 SSH 启动 mosh-server'),
      ConnectionStep.moshUdp => _t('Mosh 插件经 UDP 连过去'),
      ConnectionStep.moshTmux => _t('Mosh 附着 tmux 并核对'),
      ConnectionStep.pluginHost => _t('核对本机插件'),
      ConnectionStep.pluginSession => _t('插件打开会话（它自己联网）'),
    };

/// 「其中等你」最少多长才写。已认识的服务器不弹指纹框，可仍走同一个核对回调（查本机记录，几毫秒）；
/// 不设这个门槛，每次握手后面都会挂一句「其中等你 0 ms」（模拟器上实际就是这样）。300 ms 内没人点得完确认框。
const _shownUserWait = Duration(milliseconds: 300);

bool _perHop(ConnectionStep step) => switch (step) {
      ConnectionStep.dial ||
      ConnectionStep.proxy ||
      ConnectionStep.handshake ||
      ConnectionStep.check ||
      ConnectionStep.forward =>
        true,
      _ => false,
    };

/// 没有值就写「未知」，不造一个。
String formatConnectionElapsed(Duration? value) {
  if (value == null) return _t('未知');
  final ms = value.inMilliseconds;
  if (ms < 1000) return '$ms ms';
  if (ms < 10000) {
    return _t('{n} 秒', {'n': (ms / 1000).toStringAsFixed(1)});
  }
  if (ms < 60000) return _t('{n} 秒', {'n': value.inSeconds});
  return _t('{m} 分 {s} 秒', {
    'm': value.inMinutes,
    's': value.inSeconds % 60,
  });
}

/// 记录页里一跳的叫法：有名字时「跳板机“x”」「目标“x”」；这台主机已经删了（[label] 为 null）就只写角色。
String connectionHopName(int hop, int hopCount, String? label) {
  if (label == null) return connectionHopRole(hop, hopCount);
  return hopCount <= 1 || hop >= hopCount - 1
      ? _t('目标“{name}”', {'name': label})
      : _t('跳板机“{name}”', {'name': label});
}

/// 一条记录的几个数：协议、总用时、断开前连了多久、这一轮试了几次。没有的值写「未知」。
List<String> connectionEventFacts(ConnectionEvent event) => [
      if (event.protocol != null) connectionProtocolLabel(event.protocol),
      if (event.isAttempt)
        _t('总用时 {d}', {'d': formatConnectionElapsed(event.total)}),
      if (event.kind == ConnectionEventKind.drop)
        _t('断开前连了 {d}', {'d': formatConnectionElapsed(event.connectedFor)}),
      if (event.kind == ConnectionEventKind.recoveryStopped &&
          event.attempt != null)
        _t('这一轮试了 {n} 次', {'n': event.attempt!}),
    ];

String connectionFailedAt(String hop) => _t('失败在：{hop}', {'hop': hop});

String connectionNextStepLine(String text) => _t('下一步：{text}', {'text': text});

/// 「最近 7 天：连接 n 次（连上、失败、取消），断开 n 次，自动恢复试了 n 次、恢复上 n 次。」
String connectionLogSummary(List<ConnectionEvent> events) {
  int count(bool Function(ConnectionEvent e) test) => events.where(test).length;
  bool attempt(ConnectionEvent e, ConnectionOutcome outcome) =>
      e.isAttempt && e.outcome == outcome;
  return _t(
    '最近 7 天：连接 {a} 次（连上 {ok}、失败 {failed}、取消 {cancelled}），断开 {drops} 次，自动恢复试了 {restores} 次、恢复上 {restored} 次。',
    {
      'a': count((e) => e.isAttempt),
      'ok': count((e) => attempt(e, ConnectionOutcome.connected)),
      'failed': count((e) => attempt(e, ConnectionOutcome.failed)),
      'cancelled': count((e) => attempt(e, ConnectionOutcome.cancelled)),
      'drops': count((e) => e.kind == ConnectionEventKind.drop),
      'restores': count((e) => e.kind == ConnectionEventKind.restore),
      'restored': count((e) =>
          e.kind == ConnectionEventKind.restore &&
          e.outcome == ConnectionOutcome.connected),
    },
  );
}

/// 「手机 → SOCKS5 代理 → 跳板机 → 目标」。[hopName] 给每一跳的叫法：记录页用保险库里的名字，导出只用角色。
String connectionRouteLine(
  ConnectionEvent event,
  String Function(int hop) hopName,
) {
  if (event.hopIds.isEmpty) {
    return event.protocol == HostProtocol.plugin
        ? _t('插件自己联网，不经过本 App 的代理和跳板')
        : _t('路线没算出来就停了');
  }
  return [
    _t('手机'),
    if (event.entry == ConnectionEntryKind.socks5) _t('SOCKS5 代理'),
    if (event.entry == ConnectionEntryKind.http) _t('HTTP 代理'),
    for (var hop = 0; hop < event.hopCount; hop++) hopName(hop),
  ].join(' → ');
}

class ConnectionStageLine {
  const ConnectionStageLine(this.label, this.elapsed, {this.note});
  final String label;
  final String elapsed;
  final String? note;

  /// 阶段名加备注（等你了多久、停在这一步），不含用时。
  String get text =>
      note == null ? label : '$label${_t('（{note}）', {'note': note!})}';
}

/// 一条记录里逐阶段的用时。拨号前有准备时间的先列一行；停在哪一步的那行注明。
List<ConnectionStageLine> connectionStageLines(
  ConnectionEvent event,
  String Function(int hop) hopName,
) {
  if (!event.isAttempt) return const [];
  final lines = <ConnectionStageLine>[];
  final preparation = event.preparation;
  if (event.stages.isNotEmpty &&
      preparation != null &&
      preparation > Duration.zero) {
    lines.add(ConnectionStageLine(
      _t('拨号前的准备（建终端、读保险库、解私钥）'),
      formatConnectionElapsed(preparation),
    ));
  }
  for (var index = 0; index < event.stages.length; index++) {
    final stage = event.stages[index];
    final step = connectionStepLabel(stage.step);
    final label = _perHop(stage.step) && event.hopCount > 1
        ? '${hopName(stage.hop)} · $step'
        : step;
    final last = index == event.stages.length - 1;
    final notes = [
      if (stage.userWait >= _shownUserWait)
        _t('其中等你 {d}', {'d': formatConnectionElapsed(stage.userWait)}),
      if (last && event.outcome == ConnectionOutcome.failed) _t('停在这一步'),
      if (last && event.outcome == ConnectionOutcome.cancelled) _t('在这一步取消'),
    ];
    lines.add(ConnectionStageLine(
      label,
      formatConnectionElapsed(event.stageDuration(index)),
      note: notes.isEmpty ? null : notes.join(localized('；')),
    ));
  }
  return lines;
}

String _two(int value) => value.toString().padLeft(2, '0');

String formatConnectionEventTime(DateTime at) {
  final local = at.toLocal();
  return '${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
}

/// 导出用的纯文本（SEC12、UX10）：主机按出现顺序换成「主机 1」「主机 2」，路线上的各跳只写角色；
/// 记录里本来就没有地址、用户名、报错原话和凭据，这里也不去保险库查名字。只给预览和复制，不上传。
String exportConnectionEvents(
  List<ConnectionEvent> events, {
  required DateTime now,
}) {
  final numbers = <String, int>{};
  for (final event in events) {
    numbers.putIfAbsent(event.hostId, () => numbers.length + 1);
  }
  final local = now.toLocal();
  final buffer = StringBuffer()
    ..writeln(_t(
      'shun 连接记录，导出于 {time}，共 {n} 条。',
      {
        'time': '${local.year}-${formatConnectionEventTime(now)}',
        'n': events.length,
      },
    ))
    ..writeln(_t('主机名、地址、用户名已去掉，主机按出现顺序编号；不含密码、私钥、报错原话、输入和屏幕内容。'))
    ..writeln(localized(connectionTimingNote));
  for (final event in events) {
    String role(int hop) => connectionHopRole(hop, event.hopCount);
    final head = [
      '[${formatConnectionEventTime(event.at)}]',
      _t('主机 {n}', {'n': numbers[event.hostId]!}),
      connectionEventTitle(event),
      connectionEventOutcome(event),
      ...connectionEventFacts(event),
      if (event.isAttempt) connectionRouteLine(event, role),
      if (event.failureHop case final hop? when hop < event.hopCount)
        connectionFailedAt(role(hop)),
    ];
    buffer
      ..writeln()
      ..writeln(head.join(' · '));
    for (final line in connectionStageLines(event, role)) {
      buffer.writeln('    ${line.text}  ${line.elapsed}');
    }
    if (connectionEventNextStep(event) case final next?) {
      buffer.writeln('    ${connectionNextStepLine(next)}');
    }
  }
  return buffer.toString();
}
