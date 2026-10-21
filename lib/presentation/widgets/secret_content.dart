import 'package:flutter/widgets.dart';

import '../../application/sensitive_screen.dart';

/// 包住输入或显示密码、私钥口令、代理口令、token 的一整页或一个对话框（R44）。
///
/// 它真显示在屏幕上时，Android 窗口带 FLAG_SECURE：截屏、录屏、投屏和最近任务的缩略图里都是黑的。
/// 「真显示」是指：不在 IndexedStack 没选中的那页里（设置页一直挂在首页的 IndexedStack 里），
/// 也没被不透明的新页面盖住（盖住时 Overlay 关掉它的 TickerMode）。只按「挂在树上」算的话，
/// 设置页里一个密码框就会让终端页也截不了屏。对话框盖在上面不算盖住：底下的内容还看得见。
///
/// 别包终端页：用户要截终端（R44 的停止条件）。里面的密码框另外要关输入法学习：
/// `enableIMEPersonalizedLearning: false`、`enableSuggestions: false`、`autocorrect: false`
/// （`test/secret_content_test.dart` 会扫出漏了的 `obscureText` 框）。
///
/// 没用 Flutter 自带的 SensitiveContent：它只在 Android 15 起、投屏或共享屏幕时遮挡，
/// 管不了截屏和最近任务；也只按挂没挂在树上算，碰上上面说的 IndexedStack 就会把终端页一起遮了。
class SecretContent extends StatefulWidget {
  const SecretContent({super.key, required this.child});

  final Widget child;

  @override
  State<SecretContent> createState() => _SecretContentState();
}

class _SecretContentState extends State<SecretContent> {
  // 记住登记在哪个守卫上：测试中途换了 instance，dispose 也要从原来那个里去掉。
  final _guard = SensitiveScreenGuard.instance;
  var _showing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final showing =
        Visibility.of(context) && TickerMode.valuesOf(context).enabled;
    if (showing == _showing) return;
    _showing = showing;
    showing ? _guard.show(this) : _guard.hide(this);
  }

  @override
  void dispose() {
    _guard.hide(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
