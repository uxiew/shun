import 'models/host.dart';

/// 标签对应的保险库主机 ID。临时标签（tmux、托管终端）的 host 是拷出来的，ID 是新生成的，
/// 建它的时候把来源主机记在 [sourceHostIdKey] 里。
const sourceHostIdKey = '_sourceHostId';

String sourceHostIdOf(HostProfile host) =>
    host.data[sourceHostIdKey]?.toString() ?? host.id;
