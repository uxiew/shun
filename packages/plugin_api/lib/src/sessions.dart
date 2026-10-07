// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

/// 三类会话各有各的状态机，不能合成一个"SSH 是否已连接"的布尔值（docs/03 V3 段）。
library;

/// 终端/远程桌面会话的生命周期（docs/15 §7）。
enum SessionPhase {
  opening,
  active,
  closing,
  closed,
  interrupted,
  providerDied,
  permissionRevoked;

  bool get isTerminal =>
      this == closed ||
      this == interrupted ||
      this == providerDied ||
      this == permissionRevoked;
}

/// 外部 App 发起记录。**没有"已连接"状态**：拉起外部 App 不等于远控成功，
/// 只有提供方明确回报时才有 [providerReportedSuccess]，其余一律是"不知道"。
enum ExternalLaunchPhase {
  launching,
  launchedUnverified,
  providerReportedSuccess,
  providerReportedFailure,
  launchFailed,
}

/// 带代次的会话状态。旧代次的回调只会被丢弃，不能让已停止的会话"复活"。
class SessionState<P extends Enum> {
  const SessionState(this.generation, this.sequence, this.phase);

  final int generation;
  final int sequence;
  final P phase;

  /// 应用一个来自 provider 的事件。代次不同或序号不增的事件直接忽略。
  SessionState<P> apply(int generation, int sequence, P phase) {
    if (generation != this.generation || sequence <= this.sequence) {
      return this;
    }
    return SessionState(generation, sequence, phase);
  }
}

sealed class SessionKind {
  const SessionKind(this.sessionHandle, this.providerId);

  /// 宿主生成的不透明句柄；provider 不能跨会话使用别人的句柄。
  final String sessionHandle;
  final String providerId;
}

/// 原始 VT 字节流会话（SSH、Mosh）。
class TerminalSessionRef extends SessionKind {
  const TerminalSessionRef(super.sessionHandle, super.providerId, this.state);
  final SessionState<SessionPhase> state;
}

/// 内嵌远程桌面画面（后续 R38），绝不经过终端引擎。
class RemoteDesktopSessionRef extends SessionKind {
  const RemoteDesktopSessionRef(
    super.sessionHandle,
    super.providerId,
    this.state,
  );
  final SessionState<SessionPhase> state;
}

/// 外部 App 联动（UU/RustDesk 首版）。
class ExternalLaunchAttempt extends SessionKind {
  const ExternalLaunchAttempt(
    super.sessionHandle,
    super.providerId,
    this.state,
  );
  final SessionState<ExternalLaunchPhase> state;
}
