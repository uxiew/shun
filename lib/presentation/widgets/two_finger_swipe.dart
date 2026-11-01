import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 终端区域里两指上滑时做什么。放在首页外壳上：总览的动画归它管，手势要贴着终端区域。
/// 单独测终端页时没有它，两指就什么都不做。
class TwoFingerSwipeHandlers extends InheritedWidget {
  const TwoFingerSwipeHandlers({
    super.key,
    required this.onUpdate,
    required this.onEnd,
    required super.child,
  });

  /// 两指的平均竖直位移，往上是负数。
  final ValueChanged<double> onUpdate;

  /// 松手时的竖直速度（dp/秒），往上是负数。
  final ValueChanged<double> onEnd;

  static TwoFingerSwipeHandlers? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TwoFingerSwipeHandlers>();

  @override
  bool updateShouldNotify(TwoFingerSwipeHandlers oldWidget) => false;
}

/// 两指往上滑（所有者 11-01：会话总览用，终端页整个屏幕都算）。
///
/// [eager] 为 true 时，第二根手指一落下就把两根手指都要过来，不等它们动。终端显示区域要这样：手指动得快时
/// 第一根一步就过了终端滚动的门槛（18dp），比距离抢不过，终端就滚了，开着鼠标的 tmux 还会收到滚轮。
///
/// [eager] 为 false 时，要两根手指都真的往上走了才接管，整个屏幕其余地方用这个：按住 Ctrl 再按别的键也是
/// 两根手指，一落下就接管的话第二个键就按不下去了。
///
/// 一根手指时什么都不做，单指滚动、点按、长按照旧。第一根已经在滚动了再放第二根，算单指滚动。
class TwoFingerSwipeUp extends StatelessWidget {
  const TwoFingerSwipeUp({
    super.key,
    required this.enabled,
    required this.eager,
    required this.child,
  });

  /// 手指落下时问一次。不能靠换掉这个组件来开关：换掉会把里面的终端重建。
  final bool Function() enabled;
  final bool eager;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final handlers = TwoFingerSwipeHandlers.maybeOf(context);
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        _TwoFingerSwipeRecognizer:
            GestureRecognizerFactoryWithHandlers<_TwoFingerSwipeRecognizer>(
          _TwoFingerSwipeRecognizer.new,
          (recognizer) {
            recognizer.eager = eager;
            recognizer.enabled = () => handlers != null && enabled();
            recognizer.onUpdate = (delta) => handlers?.onUpdate(delta);
            recognizer.onEnd = (velocity) => handlers?.onEnd(velocity);
          },
        ),
      },
      child: child,
    );
  }
}

class _TwoFingerSwipeRecognizer extends OneSequenceGestureRecognizer {
  /// 每根手指都往上走够这么多才算上滑。两根合计 16dp，比终端滚动的 18dp 小；放着不动、轻微抖动不算。
  static const _slop = 8.0;

  late bool eager;
  late bool Function() enabled;
  late ValueChanged<double> onUpdate;
  late ValueChanged<double> onEnd;

  /// 从第二根手指落下时量起：第一根之前走的不算。
  final _origins = <int, Offset>{};
  final _latest = <int, Offset>{};
  VelocityTracker? _velocity;
  var _active = false;

  /// 有手指抬起来了，这次手势到此为止，只等剩下的手指也抬起。
  var _finished = false;

  @override
  String get debugDescription => 'two finger swipe up';

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      event.kind == PointerDeviceKind.touch &&
      enabled() &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // 第三根手指不管，前两根继续算。
    if (_finished || _latest.length == 2) return;
    startTrackingPointer(event.pointer, event.transform);
    _latest[event.pointer] = event.position;
    _origins
      ..clear()
      ..addAll(_latest);
    _velocity ??= VelocityTracker.withKind(event.kind);
    if (eager && _latest.length == 2) resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_latest.containsKey(event.pointer)) return;
    if (event is PointerMoveEvent) {
      _latest[event.pointer] = event.position;
      if (event.pointer == _latest.keys.first) {
        _velocity?.addPosition(event.timeStamp, event.position);
      }
      if (_active) {
        onUpdate(event.delta.dy / 2);
      } else if (!_finished && _latest.length == 2) {
        _decide();
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_active) {
        final velocity = _velocity?.getVelocity().pixelsPerSecond.dy ?? 0;
        _active = false;
        onEnd(event is PointerCancelEvent ? 0 : velocity);
      }
      _finished = true;
      // 还没接管就别占着竞技场：按键、点按等着它让路才算数。已经接管时这句什么也不做。
      resolve(GestureDisposition.rejected);
      stopTrackingIfPointerNoLongerDown(event);
    }
  }

  void _decide() {
    final moved = [
      for (final MapEntry(key: pointer, value: position) in _latest.entries)
        position - _origins[pointer]!,
    ];
    if (moved.every(
      (value) => value.dy <= -_slop && value.dy.abs() >= value.dx.abs(),
    )) {
      _active = true;
      resolve(GestureDisposition.accepted);
      onUpdate((moved[0].dy + moved[1].dy) / 2);
    } else if (!eager &&
        moved.any((value) => value.dy > _slop || value.dx.abs() > _slop * 2)) {
      resolve(GestureDisposition.rejected);
    }
  }

  @override
  void rejectGesture(int pointer) {
    // 把竞技场的条目也摘掉。留着的话，下次手指落下时停用的识别器拿旧条目去放弃，断言就炸（host 上撞过）。
    resolvePointer(pointer, GestureDisposition.rejected);
    stopTrackingPointer(pointer);
    _origins.remove(pointer);
    _latest.remove(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _origins.clear();
    _latest.clear();
    _velocity = null;
    _active = false;
    _finished = false;
  }
}
