import 'dart:collection';
import 'dart:typed_data';

/// 防重入写入：[write] 期间（比如在 onOutput 回调里）再来的数据先排队，
/// 当前这次写完后按顺序补写。
///
/// flterm/libghostty 的回调在 write 里同步触发，库要求调用方不得在回调里再次 write；
/// 原生层重入的后果不是抛异常，可能是内存损坏或进程崩溃，所以只能在 Dart 这层挡住。
/// 这是 R16 终端适配器的雏形（GST03），不是最终实现。
class GuardedWriter {
  GuardedWriter(this._sink);

  final void Function(Uint8List bytes) _sink;
  final _queue = Queue<Uint8List>();
  bool _writing = false;
  int _maxDepth = 0;
  int _depth = 0;

  /// 观测到的最大嵌套深度；正确时永远是 1。
  int get maxDepth => _maxDepth;

  /// 是否正在 write 中。此时 onOutput 收到的是终端对远端数据的协议回应（如 DA），
  /// 不是用户输入：该发往远端，绝不能再喂回终端，否则可能自问自答循环。
  bool get isWriting => _writing;

  bool _closed = false;
  int _droppedAfterClose = 0;

  /// 关闭后仍被调用、因而丢弃的写入次数（比如 SSH 迟到的数据）。
  int get droppedAfterClose => _droppedAfterClose;

  /// 必须在 controller.dispose() 之前调用。
  ///
  /// dispose 之后再 write：flterm 0.0.5 会段错误、整个进程崩溃（R04 实测）；上游 main 起改成抛
  /// StateError，不崩了，但 SSH 迟到的数据照样会抛。所以迟到的数据在 Dart 这层丢掉。
  void close() {
    _closed = true;
    _queue.clear();
  }

  void write(Uint8List bytes) {
    if (_closed) {
      _droppedAfterClose++;
      return;
    }
    if (_writing) {
      _queue.add(Uint8List.fromList(bytes));
      return;
    }
    _writing = true;
    try {
      _run(bytes);
      while (_queue.isNotEmpty) {
        _run(_queue.removeFirst());
      }
    } finally {
      _writing = false;
    }
  }

  void _run(Uint8List bytes) {
    _depth++;
    if (_depth > _maxDepth) _maxDepth = _depth;
    try {
      _sink(bytes);
    } finally {
      _depth--;
    }
  }
}
