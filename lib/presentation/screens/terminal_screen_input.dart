part of 'terminal_screen.dart';

/// 终端下面的输入方式（R25 第一部分，所有者 10-07 提的）：系统键盘直接打进终端（原来的方式）、App 的按键面板、
/// 大输入框。后两个在同一个面板里左右滑动切换；快捷键栏上的按钮在系统键盘和面板之间切；记住上次用的方式。
///
/// 面板占的是系统键盘的位置：高度取这个方向上最近一次系统键盘的高度（没见过就按屏幕高度估），
/// 系统键盘往下收的同时面板往上长，两者加起来不变，终端的行数就不跟着抖。切换的那一刻还让终端
/// 先别把尺寸发给远端（[TerminalSessionAdapter.holdResize]），过 400ms 只发最后一个。
mixin _TerminalInputHost on ConsumerState<TerminalScreen> {
  /// 面板模式下面板是不是展开着。点「收起键盘」、按返回键收起；点终端、点快捷键栏的按钮再展开。
  var _panelOpen = true;

  /// 用户这次切过的方式；设置要异步存，界面先照这个变。
  String? _modeOverride;

  /// 上次用的是按键面板还是大输入框：从系统键盘切回面板时回到那一页。
  String? _lastPanelMode;

  final _drafts = TerminalComposeDrafts();
  final _composeFocus = FocusNode(debugLabel: 'terminal-compose');

  /// 不弹键盘时终端页有多高，按（宽度、全屏与否）记。弹着键盘时用它算出键盘占了多少。
  final _fullHeights = <(double, bool), double>{};

  /// 每个方向上最近一次系统键盘占掉的高度。面板照这个高度开。
  final _keyboardHeights = <Orientation, double>{};
  var _keyboardShowMax = 0.0;
  Orientation? _keyboardShowOrientation;

  /// 刚从面板换回系统键盘：键盘升上来之前先把面板的位置空着，免得终端先变高、再被键盘压回去。
  DateTime? _awaitKeyboardUntil;
  Timer? _awaitKeyboardTimer;

  var _keyboardSerial = 0;
  ({String sessionId, int serial})? _keyboardRequest;

  /// 正显示着的那一两格终端：切换时让它们先别发尺寸。
  var _visibleTerminals = const <TerminalSessionAdapter>[];

  static const _resizeHold = Duration(milliseconds: 400);
  static const _awaitKeyboardFor = Duration(milliseconds: 700);

  void initInputHost() {
    _composeFocus.addListener(_onComposeFocusChanged);
  }

  void disposeInputHost() {
    _awaitKeyboardTimer?.cancel();
    _composeFocus
      ..removeListener(_onComposeFocusChanged)
      ..dispose();
    _drafts.dispose();
  }

  String _inputModeOf(AppSettings settings) =>
      _modeOverride ?? settings.terminalInputMode;

  String get _inputMode => _inputModeOf(ref.read(settingsControllerProvider));

  String get _panelMode {
    final remembered = _lastPanelMode;
    if (remembered != null) return remembered;
    final mode = _inputMode;
    return mode == terminalInputSystem ? terminalInputKeys : mode;
  }

  void _holdResize() {
    for (final terminal in _visibleTerminals) {
      terminal.holdResize(_resizeHold);
    }
  }

  void _setInputMode(String mode) {
    if (mode == _inputMode) return;
    setState(() {
      _modeOverride = mode;
      if (mode != terminalInputSystem) _lastPanelMode = mode;
    });
    _holdResize();
    // 偏好而已：存不上（比如存储暂时不可用）就只在这次运行里生效，不打扰用户。
    unawaited(
      ref
          .read(settingsControllerProvider.notifier)
          .updateTerminalInputMode(mode)
          .catchError((Object _) {}),
    );
  }

  /// 快捷键栏上的按钮：系统键盘 → 面板（回到上次那一页）；面板收着 → 展开；面板开着 → 换回系统键盘。
  void _toggleInputPanel(ActiveTerminalSession input) {
    if (_inputMode == terminalInputSystem) {
      _openPanel(_panelMode);
    } else if (!_panelOpen) {
      _openPanel(_inputMode);
    } else {
      _useSystemKeyboard(input);
    }
  }

  void _openPanel(String mode) {
    setState(() => _panelOpen = true);
    _setInputMode(mode);
    _holdResize();
    if (mode == terminalInputCompose) {
      _focusComposeSoon();
    } else {
      _composeFocus.unfocus();
      // 终端的输入法连接还在，只是不再叫键盘：把已经弹着的收下去，面板顶上来。
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    }
  }

  void _useSystemKeyboard(ActiveTerminalSession input) {
    _composeFocus.unfocus();
    _awaitKeyboardTimer?.cancel();
    _awaitKeyboardUntil = DateTime.now().add(_awaitKeyboardFor);
    _awaitKeyboardTimer = Timer(_awaitKeyboardFor, () {
      if (!mounted) return;
      setState(() => _awaitKeyboardUntil = null);
    });
    setState(() {
      _keyboardRequest = (sessionId: input.id, serial: ++_keyboardSerial);
    });
    _setInputMode(terminalInputSystem);
  }

  /// 面板里左右滑、点顶上的标签换了页。
  void _onPanelModeChanged(String mode) {
    _setInputMode(mode);
    if (mode == terminalInputCompose) {
      _focusComposeSoon();
    } else {
      _composeFocus.unfocus();
    }
  }

  void _focusComposeSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _composeFocus.canRequestFocus) {
        _composeFocus.requestFocus();
      }
    });
  }

  /// 点了终端（不是拖、不是长按）。用面板时面板收着就展开：点终端是想打字。
  void _onTerminalTap() {
    if (_inputMode == terminalInputSystem || _panelOpen) return;
    _openPanel(_inputMode);
  }

  /// 「收起键盘」、返回键：用面板时把面板收起来，系统键盘照旧收起。
  void _hideInput() {
    if (_inputMode != terminalInputSystem && _panelOpen) {
      setState(() => _panelOpen = false);
      _holdResize();
    }
    _composeFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _onComposeFocusChanged() {
    if (!mounted) return;
    // 大输入框拿到/丢了焦点：系统键盘跟着出来/收起，面板在两种高度之间换。
    _holdResize();
    setState(() {});
  }

  /// 这一帧终端下面的东西各多高、快捷键栏怎么摆。顺带记下不弹键盘时的页高和键盘的高度（只是缓存）。
  _InputLayout _measureInput(
    BuildContext context,
    BoxConstraints constraints, {
    required bool panelVisible,
    required bool fullscreen,
  }) {
    final view = View.of(context);
    final inset = view.viewInsets.bottom / view.devicePixelRatio;
    final orientation = MediaQuery.orientationOf(context);
    final height = constraints.maxHeight;
    final key = (constraints.maxWidth, fullscreen);
    if (orientation != _keyboardShowOrientation) {
      _keyboardShowOrientation = orientation;
      _keyboardShowMax = 0;
    }
    if (inset <= 0) {
      _fullHeights[key] = height;
      // 键盘收完了：这一次它最高升到多少，就是这个方向上的键盘高度。
      if (_keyboardShowMax > 0) {
        _keyboardHeights[orientation] = _keyboardShowMax;
      }
      _keyboardShowMax = 0;
    }
    final full = _fullHeights[key] ?? height;
    // 系统键盘现在压掉了终端页多少（键盘还在升降的那几帧里是中间值）。
    final overlap = inset > 0 ? math.max(0.0, full - height) : 0.0;
    if (inset > 0) _keyboardShowMax = math.max(_keyboardShowMax, overlap);
    // 键盘正在升的那几帧还没升到顶：先照上次记下的高度算。不然面板空出来的位置跟着一帧帧变小，终端先变高再被压回去。
    final known = _keyboardHeights[orientation];
    final keyboard = known == null || _keyboardShowMax > known
        ? (_keyboardShowMax > 0 ? _keyboardShowMax : null)
        : known;
    final portrait = orientation == Orientation.portrait;
    final estimate = full * (portrait ? .38 : .5);
    // 至少放得下顶上一行和一页键（竖屏四行、横屏两行，见 TerminalInputPanel）：
    // 有的键盘比这矮，或者键盘盖住了底部导航栏、终端页只被压掉一百来 dp，照它开面板就只露出两行键。
    final usable = portrait ? 256.0 : 156.0;
    final panel = math
        .max(keyboard ?? estimate, usable)
        .clamp(156.0, math.max(156.0, full * .55))
        .toDouble();
    final composing = _inputMode == terminalInputCompose;
    final composeFocused = composing && _composeFocus.hasFocus;

    var panelHeight = 0.0;
    var reserve = 0.0;
    var dense = false;
    if (panelVisible) {
      if (composeFocused) {
        // 大输入框弹着系统键盘：框贴在键盘上面。地方太小就只留一行。
        dense = height - _composeHeight < 140;
        final compose = dense ? _denseComposeHeight : _composeHeight;
        panelHeight = math.max(compose, panel - overlap);
      } else {
        panelHeight = math.max(0.0, panel - overlap);
      }
    } else if (_awaitKeyboardUntil case final until?
        when DateTime.now().isBefore(until) && keyboard != null) {
      // 空出来的是键盘要占的位置（上次键盘的高度），不是面板的高度：面板比键盘高时（面板有最低高度），
      // 照面板空，终端会先被压矮、键盘升上来以后再变高，远端收到两次尺寸（模拟器上撞过：17 行再 27 行）。
      reserve = math.max(0.0, keyboard - overlap);
    }
    // 键盘升降的那几帧里，终端页会比不弹键盘时还高一截（模拟器上最多 24dp）：键盘一出来，系统手势条那一截
    // 底部留白就不算了，底部导航栏随之变矮。这一截也空着，不然终端先多一行再缩回去，远端收到两次尺寸。
    if (inset > 0 && height > full) reserve += height - full;
    final remaining = height - panelHeight - reserve;
    final tight = remaining < _tightTerminalHeight;
    return _InputLayout(
      panelHeight: panelHeight,
      // 面板按完整高度排版、多出来的剪掉：键盘还没收完那几帧面板只露出一截，不报溢出。
      // 大输入框弹着键盘时按露出来的高度排，按钮才在看得见的地方。
      panelLayoutHeight:
          composeFocused ? panelHeight : math.max(panelHeight, panel),
      reserve: reserve,
      dense: dense,
      compact: panelVisible || remaining < _compactTerminalHeight,
      tight: tight,
      // 横屏弹着键盘在大输入框里打字：快捷键栏用不上，让给终端。
      hideQuickBar: panelVisible && composeFocused && tight,
      // 在大输入框里打字、系统键盘弹着时面板只剩框那么高：顶上那一行收起来，地方给框。
      showPanelHeader: !composeFocused || panelHeight >= _composeHeight + 48,
    );
  }

  /// 系统键盘弹着时大输入框露出来的高度：框三行、按钮一行，再放得下一条提醒（放不下就换成一行的写法）。
  static const _composeHeight = 152.0;
  static const _denseComposeHeight = 68.0;
}

/// 终端页下半截这一帧的摆法。
@immutable
class _InputLayout {
  const _InputLayout({
    required this.panelHeight,
    required this.panelLayoutHeight,
    required this.reserve,
    required this.dense,
    required this.compact,
    required this.tight,
    required this.hideQuickBar,
    required this.showPanelHeader,
  });

  /// 面板露出来的高度。
  final double panelHeight;

  /// 面板按多高排版（露不全的部分剪掉）。
  final double panelLayoutHeight;

  /// 终端下面额外空出来的高度：刚换回系统键盘、键盘还没升上来时给它留的位置，
  /// 以及键盘升降那几帧里终端页多出来的那一截。
  final double reserve;
  final bool dense;
  final bool compact;
  final bool tight;
  final bool hideQuickBar;
  final bool showPanelHeader;
}
