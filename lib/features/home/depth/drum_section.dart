import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../app/layout.dart';
import '../../settings/appearance.dart';

/// How a section rides the drum, from when its top enters the bottom of the
/// screen (0) to when its bottom leaves the top (1).
class DrumSpec {
  const DrumSpec({
    required this.perspective,
    required this.rollIn,
    required this.rollOut,
    required this.startTilt,
    required this.startDrop,
    required this.startScale,
    required this.endTilt,
    required this.endRise,
    required this.endScale,
    required this.endOpacity,
  });

  final double perspective;

  /// Where it has finished rolling up, and where it starts tilting away.
  final double rollIn;
  final double rollOut;

  /// Degrees, positive leaning away from the viewer at the top.
  final double startTilt;
  final double startDrop;
  final double startScale;
  final double endTilt;
  final double endRise;
  final double endScale;
  final double endOpacity;

  static DrumSpec of(FormFactor form) => switch (form) {
    FormFactor.phone => const DrumSpec(
      perspective: 900,
      rollIn: 0.22,
      rollOut: 0.8,
      startTilt: 34,
      startDrop: 50,
      startScale: 0.94,
      endTilt: -14,
      endRise: 0,
      endScale: 0.97,
      endOpacity: 0.4,
    ),
    FormFactor.desktop => const DrumSpec(
      perspective: 1400,
      rollIn: 0.24,
      rollOut: 0.76,
      startTilt: 38,
      startDrop: 90,
      startScale: 0.92,
      endTilt: -16,
      endRise: 30,
      endScale: 0.97,
      endOpacity: 0.35,
    ),
    FormFactor.tv => const DrumSpec(
      perspective: 1600,
      rollIn: 0.24,
      rollOut: 0.78,
      startTilt: 34,
      startDrop: 90,
      startScale: 0.93,
      endTilt: -14,
      endRise: 30,
      endScale: 0.97,
      endOpacity: 0.35,
    ),
  };

  /// At [progress]: the tilt (degrees), offset down, scale and opacity. All
  /// neutral while the section is being read.
  ({double tilt, double dy, double scale, double opacity}) frameAt(double progress) {
    final p = progress.clamp(0.0, 1.0);
    if (p < rollIn) {
      final left = 1 - p / rollIn;
      return (tilt: startTilt * left, dy: startDrop * left, scale: 1 + (startScale - 1) * left, opacity: 1 - left);
    }
    if (p > rollOut) {
      final gone = (p - rollOut) / (1 - rollOut);
      return (
        tilt: endTilt * gone,
        dy: -endRise * gone,
        scale: 1 + (endScale - 1) * gone,
        opacity: 1 + (endOpacity - 1) * gone,
      );
    }
    return (tilt: 0, dy: 0, scale: 1, opacity: 1);
  }
}

/// How far through the screen a section [height] tall is, with its top at [top]
/// in a viewport [viewport] tall: 0 entering at the bottom, 1 gone at the top.
double drumProgress({required double top, required double height, required double viewport}) {
  final travel = viewport + height;
  return travel <= 0 ? 0 : (viewport - top) / travel;
}

/// A section of Home on Depth's drum ("drum"): it rolls up from below as it
/// comes into view, stays flat while it's read, and tilts away at the top. By
/// position on screen, so it doesn't matter that Home may have no end.
class DrumSection extends StatefulWidget {
  const DrumSection({super.key, required this.child});

  final Widget child;

  @override
  State<DrumSection> createState() => _DrumSectionState();
}

class _DrumSectionState extends State<DrumSection> {
  @override
  Widget build(BuildContext context) {
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null || !animationsOn(context) || effectsOf(context) != EffectsLevel.full) return widget.child;
    return _Drum(
      position: scrollable.position,
      viewport: scrollable.context,
      spec: DrumSpec.of(context.layout.formFactor),
      // Its picture is kept: scrolling only moves it, without painting it again.
      child: RepaintBoundary(child: widget.child),
    );
  }
}

class _Drum extends SingleChildRenderObjectWidget {
  const _Drum({required this.position, required this.viewport, required this.spec, super.child});

  final ScrollPosition position;
  final BuildContext viewport;
  final DrumSpec spec;

  @override
  RenderDrum createRenderObject(BuildContext context) => RenderDrum(position: position, viewport: viewport, spec: spec);

  @override
  void updateRenderObject(BuildContext context, RenderDrum renderObject) {
    renderObject
      ..position = position
      ..viewport = viewport
      ..spec = spec;
  }
}

/// Draws its child tilted, working the tilt out while painting, when the layout
/// of this frame's scroll is known. Hit testing and focus see the flat section.
class RenderDrum extends RenderProxyBox {
  RenderDrum({required this._position, required this.viewport, required this.spec});

  ScrollPosition _position;
  BuildContext viewport;
  DrumSpec spec;

  /// The opacity as last painted.
  @visibleForTesting
  double lastOpacity = 1;

  /// The tilt as last painted, in degrees.
  @visibleForTesting
  double lastTilt = 0;

  set position(ScrollPosition value) {
    if (identical(value, _position)) return;
    if (attached) _position.removeListener(markNeedsPaint);
    _position = value;
    if (attached) _position.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _position.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _position.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final box = viewport.findRenderObject();
    if (box is! RenderBox || !box.attached || size.height == 0) {
      context.paintChild(child, offset);
      return;
    }
    final top = localToGlobal(Offset.zero, ancestor: box).dy;
    final frame = spec.frameAt(drumProgress(top: top, height: size.height, viewport: box.size.height));
    lastOpacity = frame.opacity;
    lastTilt = frame.tilt;
    if (frame.opacity <= 0) return;
    if (frame.tilt == 0 && frame.dy == 0 && frame.scale == 1 && frame.opacity >= 1) {
      context.paintChild(child, offset);
      return;
    }
    // Turning about the section's bottom edge, seen from there.
    final origin = Offset(size.width / 2, size.height);
    final matrix = Matrix4.translationValues(origin.dx, origin.dy, 0)
      ..multiply(Matrix4.identity()..setEntry(3, 2, 1 / spec.perspective))
      ..rotateX(-frame.tilt * math.pi / 180)
      ..multiply(Matrix4.translationValues(0, frame.dy, 0))
      ..multiply(Matrix4.diagonal3Values(frame.scale, frame.scale, 1))
      ..multiply(Matrix4.translationValues(-origin.dx, -origin.dy, 0));
    context.pushOpacity(offset, (frame.opacity * 255).round().clamp(0, 255), (context, offset) {
      context.pushTransform(needsCompositing, offset, matrix, (context, offset) {
        context.paintChild(child, offset);
      });
    });
  }
}
