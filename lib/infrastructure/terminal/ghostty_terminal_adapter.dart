import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart' hide Key;

import 'terminal_session_adapter.dart';

/// Ghostty 的资源上限（docs/06「初始设计预算」，R04 问题 7）。
///
/// flterm 的默认值不适合手机上开好几个标签：Kitty 图像缓存 64 MiB、APC 缓冲 65 MiB，
/// 而滚动区默认只留约 10 KB（几十行），又太少。
const ghosttyTerminalConfig = TerminalConfig(
  // 每个会话最多 5000 行滚动区。Ghostty 超了就整页回收，实测 80 列留 4611 行、200 列留 4983 行。
  // 字节上限只在很宽的屏幕上起作用（200 列时先到 8 MiB，留 4507 行）。
  scrollbackMaxLines: 5000,
  scrollbackMaxBytes: 8 * 1024 * 1024,
  // 不支持终端里显示图像：远端发来的 Kitty 图像和 APC 数据直接丢，不占内存。
  kittyImageStorageLimit: 0,
  apcBufferLimit: 0,
);

/// Ghostty 引擎（libghostty + flterm）的适配器（R17，docs/06 C 步）。
///
/// 远端字节原样进 [TerminalController.write]，不先转字符串；终端发出的字节（用户输入、
/// 协议回应）原样交给当前代次的连接。除了测试，App 里只有这个文件和 Ghostty 视图认识 flterm。
final class GhosttyTerminalAdapter extends TerminalSessionAdapterBase {
  /// 原生库加载不了、终端建不起来时抛 [TerminalEngineUnavailableException]，
  /// 调用方照实告诉用户，不偷偷换成别的引擎（docs/06：UI 显示实际引擎与错误）。
  factory GhosttyTerminalAdapter({
    TerminalConfig config = ghosttyTerminalConfig,
  }) {
    final TerminalController controller;
    try {
      controller = TerminalController(config: config);
    } catch (error) {
      throw TerminalEngineUnavailableException('Ghostty', error);
    }
    return GhosttyTerminalAdapter._(controller);
  }

  GhosttyTerminalAdapter._(this.controller) {
    // 先接回调再喂数据：write 里同步产生的协议回应（DA、光标位置报告）要有人接。
    // 剪贴板读写、桌面通知、进度、标题、工作目录这些效果回调一个都不接，保持 null：
    // 远端发来的请求就没人执行（SEC09）。
    controller
      ..onOutput = emitInput
      ..onResize = _onResize
      ..addListener(_onControllerChanged);
    input.addListener(_syncModifiers);
  }

  /// 只给 Ghostty 专用视图（`presentation/terminal/ghostty_terminal_view.dart`）和测试用。
  /// 连接层、会话控制器不该碰它，见 `test/terminal_layering_test.dart`。
  final TerminalController controller;

  final _changes = _Changes();
  final _pending = Queue<Uint8List>();
  var _writing = false;
  var _fedSinceBind = false;
  Object? _engineOwner;
  var _controllerDisposed = false;

  @override
  String get engine => 'Ghostty';

  @override
  void feed(Uint8List bytes) {
    if (isDisposed || bytes.isEmpty) return;
    _fedSinceBind = true;
    _write(bytes);
  }

  @override
  void showNotice(String text) {
    if (isDisposed || text.isEmpty) return;
    _write(Uint8List.fromList(utf8.encode(text)));
  }

  /// write 期间又来的数据先排队，这次写完再按顺序写（GST03）。
  ///
  /// write 会同步触发回调，回调里再 write 是库明令禁止的重入，后果是原生层状态错乱，
  /// 不是抛异常。现在的回调链（发给 SSH、Telnet）不会绕回来，这里兜住以后的改动。
  void _write(Uint8List bytes) {
    if (_writing) {
      _pending.add(bytes);
      return;
    }
    _writing = true;
    try {
      controller.write(bytes);
      while (_pending.isNotEmpty && !isDisposed) {
        controller.write(_pending.removeFirst());
      }
    } finally {
      _writing = false;
      _pending.clear();
    }
  }

  /// 新代次接手前，打断上一代没写完的控制序列。
  ///
  /// 旧连接可能断在一个转义序列中间（比如设标题的 OSC 没等到结束符）。不打断的话，
  /// 新 shell 的输出会被当成那个序列的一部分吞掉，屏幕上什么都不出。CAN（0x18）在任何状态下
  /// 都让解析器回到普通状态，在普通状态下什么都不做（VT100/xterm 同样）。
  @override
  void onRebind() {
    if (!_fedSinceBind) return;
    _fedSinceBind = false;
    _write(Uint8List.fromList(const [0x18]));
  }

  @override
  void sendText(String text) {
    if (isDisposed || text.isEmpty) return;
    // 快捷键栏、片段发来的是现成的字符串（方向键也是 "\x1b[A" 这种），和 xterm2 时一样
    // 先套上一次性修饰键再发。按键编码（应用光标模式等）的迁移在 R18。
    controller.sendText(input.consume(text));
  }

  /// 快捷键栏的一次性修饰键交给 flterm 的虚拟修饰键：软键盘、输入法发来的下一个键由 flterm 自己
  /// 套上修饰再编码；用掉以后 flterm 清掉虚拟修饰键，这边跟着清，快捷键栏上的高亮就灭了。
  void _syncModifiers() {
    if (isDisposed) return;
    var wanted = const Mods.none();
    for (final modifier in input.modifiers) {
      wanted = wanted |
          switch (modifier) {
            'ctrl' => const Mods.ctrl(),
            'alt' => const Mods.alt(),
            'shift' => const Mods.shift(),
            _ => const Mods.none(),
          };
    }
    if (controller.virtualMods == wanted) return;
    controller.clearVirtualMods();
    if (!wanted.isEmpty) controller.toggleMod(wanted);
  }

  void _onControllerChanged() {
    if (isDisposed) return;
    if (controller.virtualMods.isEmpty && input.modifiers.isNotEmpty) {
      input.clearModifiers();
    }
    _changes.notify();
  }

  void _onResize(int columns, int rows) => emitResize(columns, rows, 0, 0);

  @override
  bool get isAlternateScreen =>
      !isDisposed && controller.activeScreen == TerminalScreen.alternate;

  @override
  int get viewRows =>
      isDisposed ? 0 : controller.totalRows - controller.scrollbackRows;

  @override
  List<TerminalTextLine> recentLines(int count) {
    if (isDisposed) return const [];
    return [
      for (final row in controller.tailRows(count))
        TerminalTextLine(row.text, wrapped: row.wrapped),
    ];
  }

  @override
  String allText() {
    if (isDisposed) return '';
    final formatter = controller.createFormatter(format: FormatterFormat.plain);
    try {
      return formatter.format();
    } finally {
      formatter.dispose();
    }
  }

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  /// 新视图拿到显示权时通知旧视图：旧视图据此重建，把它的 flterm 视图卸下。
  @override
  TerminalViewLease attachView() {
    final lease = super.attachView();
    _changes.notify();
    return lease;
  }

  /// 有没有 flterm 视图正挂在控制器上。
  bool get hasEngineView => _engineOwner != null;

  /// 挂着 flterm 视图的是不是 [owner] 之外的视图。flterm 一个控制器同一时刻只能挂一个视图，
  /// 第二个来挂会抛 StateError；新视图要等旧的卸下（R16 的显示权只决定谁该显示）。
  bool engineViewHeldByOther(Object owner) =>
      _engineOwner != null && !identical(_engineOwner, owner);

  /// [owner] 挂上了 flterm 视图，和 [releaseEngineView] 成对。
  void retainEngineView(Object owner) => _engineOwner = owner;

  /// [owner] 卸下了 flterm 视图。终端已经释放、只等视图卸下时，由这里真正释放控制器。
  ///
  /// 不当场释放：Flutter 停用一棵子树时先停用父组件、后停用子组件，注销这一刻 flterm 视图
  /// 还没解绑；等这一轮同步工作做完（微任务）再释放，那时它已经解绑。
  void releaseEngineView(Object owner) {
    if (!identical(_engineOwner, owner)) return;
    _engineOwner = null;
    if (!isDisposed) return;
    scheduleMicrotask(() {
      if (_engineOwner == null) _disposeController();
    });
  }

  /// 关标签时会话控制器立刻释放终端，可视图要到下一帧才卸下；flterm 的绘制路径不检查控制器
  /// 是否已释放，这一帧里画就是读已经释放的原生内存，进程直接崩（R16「给 R17 的话」）。
  /// 所以视图还挂着时只做标记、通知视图卸下，控制器等最后一个视图卸下再释放。
  @override
  void disposeEngine() {
    input.removeListener(_syncModifiers);
    _pending.clear();
    if (_engineOwner == null) {
      _disposeController();
    } else {
      _changes.notify();
    }
  }

  void _disposeController() {
    if (_controllerDisposed) return;
    _controllerDisposed = true;
    // _changes 不释放：视图卸下时还会 removeListener，它只是 Dart 对象，随适配器回收。
    controller
      ..removeListener(_onControllerChanged)
      ..onOutput = null
      ..onResize = null
      ..dispose();
  }

  /// 原生控制器是否已经真正释放。只给测试核对「视图卸下前不释放、卸下后一定释放」。
  @visibleForTesting
  bool get engineReleased => _controllerDisposed;
}

class _Changes extends ChangeNotifier {
  void notify() => notifyListeners();
}
