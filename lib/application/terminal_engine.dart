import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../infrastructure/terminal/ghostty_terminal_adapter.dart';
import '../infrastructure/terminal/terminal_session_adapter.dart';

typedef TerminalAdapterFactory = TerminalSessionAdapter Function();

/// 这个版本唯一的终端引擎。R20 起原来的 xterm2 不在安装包里了（docs/06 E 步）。
/// 终端标签只给别的引擎标名字；现在没有别的。
const terminalEngineName = 'Ghostty';

/// 建一个终端。Ghostty 建不起来（原生库加载失败、ABI 不对等）时抛 [TerminalEngineUnavailableException]：
/// 没有别的引擎可换，连接如实失败、设置页照实显示原因，不悄悄凑合（docs/06：UI 显示实际引擎与错误，TER12）。
TerminalSessionAdapter newTerminalAdapter() => GhosttyTerminalAdapter();

/// 这次运行里终端引擎实际怎样，设置页照实显示（TER12：要的是哪个、实际用的是哪个、为什么没起来）。
/// 只记在内存里：原生库这次加载不了，下次启动还会再试，不留一个「上次坏了」的记号把人吓住。
@immutable
class TerminalEngineStatus {
  const TerminalEngineStatus({
    this.started = 0,
    this.failure,
    this.nativeVersion,
  });

  /// 要的引擎。这个版本只有一个。
  String get requested => terminalEngineName;

  /// 实际在用的引擎：最近一次建终端成功了才是 Ghostty。失败了是 null——没有别的引擎顶上；
  /// 还没建过终端也是 null（不知道就说不知道）。
  String? get effective =>
      failure == null && started > 0 ? terminalEngineName : null;

  /// 这次运行里建成过几个终端（含设置页的「检查」）。
  final int started;

  /// 最近一次建终端失败的原因（原生库报的原话）。之后又建成了就清掉。
  final Object? failure;

  /// 原生库自己报的版本（Ghostty 源码版本）。建成过终端才读得到。
  final String? nativeVersion;
}

class TerminalEngineStatusController
    extends StateNotifier<TerminalEngineStatus> {
  TerminalEngineStatusController([this._build = newTerminalAdapter])
      : super(const TerminalEngineStatus());

  final TerminalAdapterFactory _build;

  /// 建一个终端，顺手记下成没成。失败时照样抛出去，连接那边要如实失败。
  TerminalSessionAdapter create() {
    final TerminalSessionAdapter terminal;
    try {
      terminal = _build();
    } on TerminalEngineUnavailableException catch (error) {
      state = TerminalEngineStatus(
        started: state.started,
        failure: error.cause,
        nativeVersion: state.nativeVersion,
      );
      rethrow;
    }
    state = TerminalEngineStatus(
      started: state.started + 1,
      nativeVersion: state.nativeVersion ?? ghosttyNativeVersion(),
    );
    return terminal;
  }

  /// 设置页的「检查」：建一个终端马上释放，看这台手机上原生库能不能用。不连任何服务器。
  void check() {
    try {
      create().dispose();
    } on TerminalEngineUnavailableException {
      // 已经记进 state，设置页照着显示。
    }
  }
}

final terminalEngineStatusProvider =
    StateNotifierProvider<TerminalEngineStatusController, TerminalEngineStatus>(
  (ref) => TerminalEngineStatusController(),
);

/// 新标签用的终端。经引擎状态建，成没成设置页都看得到。
final terminalAdapterFactoryProvider = Provider<TerminalAdapterFactory>(
  (ref) => ref.read(terminalEngineStatusProvider.notifier).create,
);
