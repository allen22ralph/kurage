import 'package:flutter/material.dart';

import '../features/settings/appearance.dart';

/// Fades and slides [child] in once, when first built: rows as they load,
/// and their cards one after another ([index] staggers them).
class Entrance extends StatelessWidget {
  const Entrance({super.key, required this.child, this.index = 0, this.offset = 16});

  final Widget child;

  /// Position in a row: each later card starts a little later (the first
  /// eight; the rest come with the eighth).
  final int index;

  /// How far it slides up from, in pixels.
  final double offset;

  static const _base = Duration(milliseconds: 320);
  static const _step = Duration(milliseconds: 45);

  @override
  Widget build(BuildContext context) {
    if (!animationsOn(context)) return child;
    final delay = _step * index.clamp(0, 7);
    final total = _base + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(delay.inMilliseconds / total.inMilliseconds, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * offset), child: child),
      ),
      child: child,
    );
  }
}

/// A row of placeholder cards while it loads, pulsing gently.
class SkeletonRow extends StatefulWidget {
  const SkeletonRow({super.key, required this.cardWidth, required this.aspectRatio, required this.padding});

  final double cardWidth;
  final double aspectRatio;
  final EdgeInsets padding;

  @override
  State<SkeletonRow> createState() => _SkeletonRowState();
}

class _SkeletonRowState extends State<SkeletonRow> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (animationsOn(context)) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.value = 0.5;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ClipRect(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => Opacity(
          opacity: 0.35 + _pulse.value * 0.35,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: widget.padding,
            itemCount: 12,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (_, _) => SizedBox(
              width: widget.cardWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: widget.aspectRatio,
                    child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8))),
                  ),
                  const SizedBox(height: 8),
                  FractionallySizedBox(
                    widthFactor: 0.8,
                    child: Container(height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
