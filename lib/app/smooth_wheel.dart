import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../features/settings/appearance.dart';

/// How long a notch of the mouse wheel takes to arrive.
const _glide = Duration(milliseconds: 220);

/// Gives a page a scroll controller whose mouse wheel glides instead of jumping
/// a notch at a time, which shows most on what follows the scroll (Depth's
/// drum). Touch, touchpads and the scrollbar already move continuously. With
/// animations off, the wheel steps as usual.
class SmoothWheel extends StatefulWidget {
  const SmoothWheel({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller) builder;

  @override
  State<SmoothWheel> createState() => _SmoothWheelState();
}

class _SmoothWheelState extends State<SmoothWheel> {
  late final _controller = _SmoothWheelController(() => mounted && animationsOn(context));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

class _SmoothWheelController extends ScrollController {
  _SmoothWheelController(this.animate);

  final bool Function() animate;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _SmoothWheelPosition(
        animate: animate,
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
      );
}

class _SmoothWheelPosition extends ScrollPositionWithSingleContext {
  _SmoothWheelPosition({
    required this.animate,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final bool Function() animate;

  /// Where the notches so far are heading: the next one adds to it, so quick
  /// notches add up rather than restart from wherever the glide has got to.
  double? _target;

  @override
  void pointerScroll(double delta) {
    if (delta == 0 || !animate()) {
      _target = null;
      super.pointerScroll(delta);
      return;
    }
    final target = math.min(math.max((_target ?? pixels) + delta, minScrollExtent), maxScrollExtent);
    if (target == _target || target == pixels) return;
    _target = target;
    updateUserScrollDirection(delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse);
    animateTo(target, duration: _glide, curve: Curves.easeOutCubic).whenComplete(() {
      // (Unless a later notch has taken over.)
      if (_target == target) _target = null;
    });
  }
}
