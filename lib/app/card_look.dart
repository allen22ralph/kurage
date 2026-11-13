import 'package:flutter/material.dart';

import '../features/settings/appearance.dart';
import 'layout.dart';

/// How the cards below draw themselves: Classic's (no [CardLook]), or a
/// theme's poster tiles (Depth): rounder, lifting and tilting with a shine
/// under the mouse or focus, the status as a pill on the top left.
class CardLook extends InheritedWidget {
  const CardLook({super.key, required this.tiles, this.kicker, required super.child});

  final bool tiles;

  /// A small line above the row's title ("From Seerr").
  final String? kicker;

  static CardLook? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<CardLook>();

  /// Tiles' poster width: Depth's 184 on a PC, 124 on a phone, 250 on a TV,
  /// scaled by Appearance > Card size like other cards.
  static double tileWidth(BuildContext context) {
    final layout = context.layout;
    final base = switch (layout.formFactor) {
      FormFactor.phone => 124.0,
      FormFactor.desktop => 184.0,
      FormFactor.tv => 250.0,
    };
    return base * layout.cardScale;
  }

  /// A row title under a kicker: larger, in the display font (34 on a PC).
  static TextStyle? headingStyle(BuildContext context) {
    final size = switch (context.layout.formFactor) {
      FormFactor.phone => 24.0,
      FormFactor.desktop => 34.0,
      FormFactor.tv => 40.0,
    };
    return Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontSize: size,
          fontWeight: FontWeight.w600,
          letterSpacing: -size * 0.02,
          color: Colors.white,
        );
  }

  @override
  bool updateShouldNotify(CardLook oldWidget) => tiles != oldWidget.tiles || kicker != oldWidget.kicker;
}

/// A row's title as a theme with kickers draws it: the small uppercase line
/// in the second accent, then the title in the display font.
class KickerHeading extends StatelessWidget {
  const KickerHeading({super.key, required this.kicker, required this.title});

  final String kicker;
  final Widget title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          kicker.toUpperCase(),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.secondary,
            fontWeight: FontWeight.w800,
            letterSpacing: 2.6,
          ),
        ),
        const SizedBox(height: 4),
        title,
      ],
    );
  }
}

/// A poster tile's picture: lifts 10px and tilts towards the viewer with a
/// violet shadow and a shine sweeping across while [lifted]; presses in
/// while [pressed]. Without animations it only gets the border.
class TiltTile extends StatelessWidget {
  const TiltTile({
    super.key,
    required this.lifted,
    required this.radius,
    required this.child,
    this.focused = false,
  });

  final bool lifted;

  /// Remote / keyboard focus: a light ring as well.
  final bool focused;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final up = lifted && animationsOn(context) && effectsOf(context) != EffectsLevel.lite;
    return TiltMotion(
      tilted: up,
      child: AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: focused
              ? const Color(0xFFF2F0FF)
              : Colors.white.withValues(alpha: lifted ? 0.25 : 0.08),
          width: focused ? 3 : 1,
        ),
        boxShadow: [
          if (lifted)
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
              blurRadius: 50,
              spreadRadius: -24,
              offset: const Offset(0, 30),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - 1),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            child,
            if (up) const Positioned.fill(child: TileShine()),
          ],
        ),
      ),
      ),
    );
  }
}

/// Lifts [child] 10px and tilts it while [tilted], swinging there (and
/// back) with a little overshoot. Under a mouse it leans with the cursor:
/// the edge you point at dips away, easing after it as it moves; without
/// one (focus, touch) it takes the design's fixed tilt. One value animates
/// and the 3D transform is built from it each frame: blending two matrices
/// instead squashes the picture on the way.
class TiltMotion extends StatefulWidget {
  const TiltMotion({super.key, required this.tilted, required this.child});

  final bool tilted;
  final Widget child;

  /// The design's fixed tilt (6° and -8°), as a lean.
  static const restingLean = Offset(0.7, 0.66);

  /// The tilt at [t] (0 flat, 1 lifted), leaning to [lean] (-1..1 across
  /// and down the tile).
  static Matrix4 at(double t, [Offset lean = restingLean]) => Matrix4.identity()
    ..setEntry(3, 2, 1 / 800)
    ..translateByDouble(0, -10 * t, 0, 1)
    ..rotateX(0.16 * lean.dy * t)
    ..rotateY(-0.2 * lean.dx * t);

  @override
  State<TiltMotion> createState() => _TiltMotionState();
}

class _TiltMotionState extends State<TiltMotion> {
  Offset? _lean;

  void _point(PointerEvent e) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.isEmpty) return;
    final p = e.localPosition;
    setState(() => _lean = Offset(
          (p.dx / box.size.width * 2 - 1).clamp(-1.0, 1.0),
          (p.dy / box.size.height * 2 - 1).clamp(-1.0, 1.0),
        ));
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onHover: _point,
        onExit: (_) => setState(() => _lean = null),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: widget.tilted ? 1 : 0),
          duration: const Duration(milliseconds: 500),
          curve: const Cubic(0.2, 0.8, 0.2, 1.2),
          child: widget.child,
          // The lean eases after the cursor rather than jumping with it.
          builder: (context, t, child) => TweenAnimationBuilder<Offset>(
            tween: Tween(end: _lean ?? TiltMotion.restingLean),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: child,
            builder: (context, lean, child) =>
                t == 0 ? child! : Transform(alignment: Alignment.center, transform: TiltMotion.at(t, lean), child: child),
          ),
        ),
      );
}


/// A diagonal light sweeping across once (a lifted tile).
class TileShine extends StatelessWidget {
  const TileShine({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: -1.6, end: 1.6),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeInOut,
          builder: (context, x, _) => Align(
            alignment: Alignment(x, 0),
            child: FractionallySizedBox(
              widthFactor: 0.45,
              heightFactor: 1.6,
              child: Transform.rotate(
                angle: 0.44,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [Colors.transparent, Color(0x33FFFFFF), Colors.transparent]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// A status as a tile's pill: uppercase, dark text on [color].
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: color.withValues(alpha: 0.93), borderRadius: BorderRadius.circular(999)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          child: Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Color(0xFF0B0C12),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.66,
            ),
          ),
        ),
      );
}
