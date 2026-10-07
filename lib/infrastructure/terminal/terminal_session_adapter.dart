import 'dart:async';

import 'package:flutter/foundation.dart';

import 'terminal_input_controller.dart';

/// 终端要发给远端的字节：用户输入和终端自己的协议回应（比如 DA 查询的应答）。
typedef TerminalInputSink = void Function(Uint8List bytes);

/// 终端尺寸变了，要告诉远端 PTY。像素尺寸不知道时是 0。
typedef TerminalResizeSink = void Function(
  int columns,
  int rows,
  int pixelWidth,
  int pixelHeight,
);

/// 快捷键栏、按键面板上的功能键（R18；R25 的按键面板加了回车、退格、Delete、Insert、F1–F12）。
///
/// 按键怎么编码交给引擎：远端程序打开「应用光标键」（vim、less、tmux 常这样）后，方向键要发
/// `ESC O A` 而不是 `ESC [ A`，Home/End 同理；快捷键栏以前写死字符串，在这些程序里方向键会乱跳。
enum TerminalSpecialKey {
  escape,
  tab,
  arrowUp,
  arrowDown,
  arrowLeft,
  arrowRight,
  home,
  end,
  pageUp,
  pageDown,
  enter,
  backspace,
  delete,
  insert,
  f1,
  f2,
  f3,
  f4,
  f5,
  f6,
  f7,
  f8,
  f9,
  f10,
  f11,
  f12,
}

/// 缓冲区里的一行（含滚动区）。[wrapped] 表示它是上一行放不下自动折过来的，不是新的一行。
@immutable
class TerminalTextLine {
  const TerminalTextLine(this.text, {this.wrapped = false});
  final String text;
  final bool wrapped;
}

/// 终端引擎和连接层之间唯一的接口（R16，docs/06 B 步）。
///
/// SSH、Telnet 只往这里送远端的**原始字节**、从 [bind] 拿要发给远端的字节，
/// 不知道背后是 xterm2 还是 Ghostty，也不在网络分包处把字节转成字符串。
/// 它拿不到主机、凭据，不能拨号：远端用转义序列「说服」终端，最多影响画面，
/// 读写剪贴板、打开链接、发通知这类效果一律不接（SEC09）。
///
/// 生命周期跟着标签走，由会话控制器创建和销毁；页面重建、切标签、旋转只换视图，
/// 不碰它，更不碰背后的连接（GST02）。
abstract interface class TerminalSessionAdapter implements Listenable {
  /// 实际引擎名，界面和日志照实写（docs/06：UI 显示实际引擎）。
  String get engine;

  /// 快捷键栏的一次性修饰键，作用于下一次输入。
  TerminalInputController get input;

  /// 远端输出。块边界是网络分包，不是字符边界：多字节字符被切开时，前半截留到下一块。
  void feed(Uint8List bytes);

  /// App 自己的提示（断线、恢复中），直接显示，不经远端。
  void showNotice(String text);

  /// 把输入和尺寸变化交给「当前代次」的连接。
  ///
  /// 同一时刻只有一个绑定有效：新的绑定立刻取代旧的，旧代次再也收不到任何字节（NET09、SEC09）。
  /// 绑定时如果终端已经知道自己的尺寸（视图量过），立刻补发一次给新绑定：
  /// 恢复连接时新 PTY 按默认 80x24 打开，而尺寸没变时引擎不会再通知，不补发远端就一直是 80x24。
  TerminalBinding bind(TerminalInputSink input, {TerminalResizeSink? resize});

  /// 当作键盘输入发出去（快捷键栏的字符键、自定义快捷键）。经过修饰键，和真按键一样；
  /// 里面的换行就是按了回车。剪贴板、片段这类整段文字用 [paste]。
  void sendText(String text);

  /// 发一个功能键，套上快捷键栏的一次性修饰键，按远端当前的键盘模式编码。
  void sendKey(TerminalSpecialKey key);

  /// 把一整段文字当粘贴发出去（R19，GST04）。和 [sendText] 的区别：
  /// 不套快捷键栏的修饰键（先清掉）；远端程序打开了 bracketed paste（DEC 2004）时整段包进粘贴标记，
  /// 没打开时换行按回车（CR）发；引擎还会把 NUL、ESC、Ctrl-C 这类控制字节换成空格或去掉。末尾不追加回车。
  ///
  /// 这些都**不保证远端不执行**：没开 bracketed paste 的程序收到换行就执行前面那行；开了的程序
  /// 拿到粘贴怎么处理也由它自己决定。多行、带控制字符的内容要先让用户看过（终端页的粘贴预览）。
  void paste(String text);

  /// 远端程序现在有没有打开 bracketed paste（DEC 2004）。只用来在粘贴预览里照实告诉用户，不是安全保证。
  bool get bracketedPasteMode;

  /// 全屏程序（vim、tmux、less）切到了备用屏。
  bool get isAlternateScreen;

  /// 可见行数。
  int get viewRows;

  /// 最近 [count] 个物理行（含滚动区），最旧的在前。
  ///
  /// 画中画小窗、AI 上下文只看最近几百行。不提供按序号读任意一行：Ghostty 读滚动区里的行
  /// 每次都要从头遍历分页，逐行读几百行就是几百次遍历（R17）。
  List<TerminalTextLine> recentLines(int count);

  /// 整个缓冲区的纯文本（复制快照用）。
  String allText();

  /// 占用显示权。同一时刻只有一个视图能显示这个终端（GST02，flterm 一个 controller 只能挂一个 view）：
  /// 新视图占用时旧的立刻失效；旧视图晚一步销毁时释放已失效的占用，不影响新视图。
  TerminalViewLease attachView();

  bool get isDisposed;

  /// 释放引擎资源。之后 [feed]、[sendText] 等都被忽略，不会抛错，也不会碰已释放的对象。
  void dispose();
}

/// 一次输入绑定。被新绑定取代或 [release] 之后失效。
final class TerminalBinding {
  TerminalBinding._(this._owner, this._generation);

  final TerminalSessionAdapterBase _owner;
  final int _generation;

  bool get isActive => !_owner.isDisposed && _owner._binding == _generation;

  /// 只解除自己：已经被新代次取代时什么都不做，不会顺手把新代次也解掉。
  void release() {
    if (isActive) _owner._unbind();
  }
}

/// 一次显示占用。被新视图取代或 [release] 之后失效。
final class TerminalViewLease {
  TerminalViewLease._(this._owner, this._generation);

  final TerminalSessionAdapterBase _owner;
  final int _generation;

  bool get isActive => !_owner.isDisposed && _owner._view == _generation;

  void release() {
    if (isActive) _owner._view = 0;
  }
}

/// 代次、视图占用、销毁这几样每个引擎都一样的规矩，引擎实现只管字节和画面。
abstract class TerminalSessionAdapterBase implements TerminalSessionAdapter {
  TerminalSessionAdapterBase({TerminalInputController? input})
      : input = input ?? TerminalInputController();

  @override
  final TerminalInputController input;

  var _generations = 0;
  var _binding = 0;
  var _view = 0;
  TerminalInputSink? _inputSink;
  TerminalResizeSink? _resizeSink;
  ({int columns, int rows, int pixelWidth, int pixelHeight})? _size;
  ({int columns, int rows, int pixelWidth, int pixelHeight})? _sentSize;
  Timer? _resizeThrottle;
  var _disposed = false;

  /// 两次把尺寸发给远端之间至少隔这么久（TER06）。软键盘弹出、收起的动画有十几帧，
  /// 每帧行数都不一样；不节流就是十几个 window-change，远端的 vim、htop 跟着重画十几次。
  static const resizeInterval = Duration(milliseconds: 100);

  @override
  bool get isDisposed => _disposed;

  /// 最后一次发给远端的尺寸（列, 行）。只给测试和设备验证核对「远端尺寸跟上了没有」。
  @visibleForTesting
  (int, int)? get sentSize =>
      _sentSize == null ? null : (_sentSize!.columns, _sentSize!.rows);

  /// 现在有没有视图占着这个终端。只给测试核对「旧视图晚销毁没有把新视图的占用释放掉」。
  @visibleForTesting
  bool get hasActiveView => !_disposed && _view != 0;

  @override
  TerminalBinding bind(TerminalInputSink input, {TerminalResizeSink? resize}) {
    if (_disposed) throw StateError('终端已释放，不能再绑定连接');
    _binding = ++_generations;
    _inputSink = input;
    _resizeSink = resize;
    onRebind();
    // 新代次立刻拿到最新尺寸，旧代次没发完的那次不用再补。
    _resizeThrottle?.cancel();
    _resizeThrottle = null;
    _sentSize = null;
    _sendSize();
    return TerminalBinding._(this, _binding);
  }

  void _unbind() {
    _binding = 0;
    _inputSink = null;
    _resizeSink = null;
    _resizeThrottle?.cancel();
    _resizeThrottle = null;
  }

  @override
  TerminalViewLease attachView() {
    if (_disposed) throw StateError('终端已释放，不能再显示');
    _view = ++_generations;
    return TerminalViewLease._(this, _view);
  }

  /// 引擎产生了要发给远端的字节。没有绑定（已断开、已被取代）时丢弃。
  @protected
  void emitInput(Uint8List bytes) {
    if (_disposed || bytes.isEmpty) return;
    _inputSink?.call(bytes);
  }

  /// 引擎量出了新尺寸。记下来，换代次时补发。
  ///
  /// 0 行或 0 列不发（布局还没完成、窗口被压扁时会量出来），远端 PTY 收到会把程序挤坏。
  /// 第一次立刻发；之后 [resizeInterval] 内的变化合并，到点只补发最后一个（TER06）。
  @protected
  void emitResize(int columns, int rows, int pixelWidth, int pixelHeight) {
    if (_disposed || columns <= 0 || rows <= 0) return;
    _size = (
      columns: columns,
      rows: rows,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
    if (_resizeThrottle == null) _sendSize();
  }

  void _sendSize() {
    final size = _size;
    final sink = _resizeSink;
    if (_disposed || size == null || sink == null || size == _sentSize) return;
    _sentSize = size;
    sink(size.columns, size.rows, size.pixelWidth, size.pixelHeight);
    _resizeThrottle = Timer(resizeInterval, () {
      _resizeThrottle = null;
      _sendSize();
    });
  }

  /// 换了代次。引擎在这里丢掉上一代没处理完的状态（比如被切开的半个字符）。
  @protected
  void onRebind() {}

  /// 引擎释放自己的资源。只会调一次。
  @protected
  void disposeEngine();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _unbind();
    _view = 0;
    disposeEngine();
    input.dispose();
  }
}

/// 终端引擎建不起来（原生库加载失败、ABI 不支持等）。连接照常失败，错误里写清是哪个引擎。
class TerminalEngineUnavailableException implements Exception {
  TerminalEngineUnavailableException(this.engine, this.cause);

  final String engine;
  final Object cause;

  @override
  String toString() => '终端引擎 $engine 无法启动：$cause';
}
