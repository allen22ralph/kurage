import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/animations.dart';
import '../../settings/appearance.dart';

/// Lets horizontal lists be dragged with a mouse too (desktop). Shift +
/// wheel and touchpad swipes already scroll them sideways.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {...super.dragDevices, PointerDeviceKind.mouse};
}

/// Whether Home's rows are paged (Settings > Appearance > Rows).
bool _paged(WidgetRef ref) => ref.watch(appearanceProvider.select((a) => a.value?.rowStyle)) == RowStyle.paged;

/// One of Home's rows: what its title (‹ › and the scrub bar, [RowPager]),
/// its list ([SideScroll] with `pageable`) and its cards ([RowItem]) share
/// in the Paged row style: the scroll position, and which way it's moving.
class RowScope extends StatefulWidget {
  const RowScope({super.key, required this.child});

  final Widget child;

  static RowScopeState? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RowScopeData>()?.state;

  @override
  State<RowScope> createState() => RowScopeState();
}

class RowScopeState extends State<RowScope> {
  final controller = ScrollController();

  /// −1 … 1 while the row moves (left / right), 0 at rest: cards lean.
  final lean = ValueNotifier<double>(0);

  /// Bumped when the row's size is known or changes (the pager shows from
  /// its first layout, not its first scroll).
  final laidOut = ValueNotifier<int>(0);
  Timer? _settle;

  /// Overshoots a little, then settles (the mockup's cubic-bezier).
  static const curve = Cubic(0.65, 0, 0.12, 1.12);

  void moved(double delta) {
    lean.value = (delta / 14).clamp(-1.0, 1.0);
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 110), () => lean.value = 0);
  }

  /// A page (about the row's width) back or on.
  void page(int direction) {
    if (!controller.hasClients) return;
    final p = controller.position;
    controller.animateTo(
      (p.pixels + direction * p.viewportDimension * 0.9).clamp(p.minScrollExtent, p.maxScrollExtent),
      duration: const Duration(milliseconds: 750),
      curve: curve,
    );
  }

  @override
  void dispose() {
    _settle?.cancel();
    controller.dispose();
    lean.dispose();
    laidOut.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _RowScopeData(state: this, child: widget.child);
}

class _RowScopeData extends InheritedWidget {
  const _RowScopeData({required this.state, required super.child});

  final RowScopeState state;

  @override
  bool updateShouldNotify(_RowScopeData old) => old.state != state;
}

/// Paged rows: ‹ › beside the row's title (dimmed at the ends) and a thin
/// bar showing where in the row you are. Nothing in the Classic style.
class RowPager extends ConsumerWidget {
  const RowPager({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = RowScope.of(context);
    if (scope == null || !_paged(ref)) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: Listenable.merge([scope.controller, scope.laidOut]),
      builder: (context, _) {
        final c = scope.controller;
        final p = c.hasClients && c.position.hasContentDimensions ? c.position : null;
        final max = p?.maxScrollExtent ?? 0;
        if (p == null || max <= 0) return const SizedBox.shrink();
        final at = (p.pixels / max).clamp(0.0, 1.0);
        // Mouse / touch only: keyboard and D-pad focus stays on the cards.
        return ExcludeFocus(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Back',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_left),
                onPressed: p.pixels > p.minScrollExtent + 1 ? () => scope.page(-1) : null,
              ),
              SizedBox(
                width: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Stack(
                    children: [
                      Container(height: 3, color: accent.withValues(alpha: 0.18)),
                      FractionallySizedBox(
                        widthFactor: math.max(0.12, at),
                        child: Container(height: 3, color: accent),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'More',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_right),
                onPressed: p.pixels < max - 1 ? () => scope.page(1) : null,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A card in one of Home's rows. Classic: it fades and slides in
/// ([Entrance]). Paged: it swings in from the right on first load, and
/// leans the way the row moves (each a little after the one before).
class RowItem extends ConsumerWidget {
  const RowItem({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = RowScope.of(context);
    if (scope == null || !_paged(ref)) return Entrance(index: index, child: child);
    if (!animationsOn(context)) return child;
    final stagger = index.clamp(0, 7);
    final swingIn = Duration(milliseconds: 520 + 70 * stagger);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: swingIn,
      curve: Interval(70 * stagger / swingIn.inMilliseconds, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform(
          alignment: Alignment.centerLeft,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..translateByDouble((1 - t) * 90, 0, 0, 1)
            ..rotateY((1 - t) * -0.38),
          child: child,
        ),
      ),
      child: ValueListenableBuilder<double>(
        valueListenable: scope.lean,
        builder: (context, lean, child) => TweenAnimationBuilder<double>(
          tween: Tween(end: lean),
          duration: Duration(milliseconds: 170 + 30 * (index % 6)),
          curve: Curves.easeOut,
          builder: (context, l, child) => Transform(
            alignment: Alignment.bottomCenter,
            transform: Matrix4.identity()
              ..translateByDouble(-l * 14, 0, 0, 1)
              ..multiply(Matrix4.skewX(-l * 0.12))
              ..scaleByDouble(1 - 0.03 * l.abs(), 1 - 0.03 * l.abs(), 1, 1),
            child: child,
          ),
          child: child,
        ),
        child: child,
      ),
    );
  }
}

/// A horizontally scrolling row with ‹ › buttons at its ends while the
/// mouse is over it (desktop), each moving about a screen's width. The
/// buttons only show when there's more to see that way.
///
/// [pageable] (Home's rows): in the Paged row style its ‹ › are by the
/// title instead ([RowPager]), and the row tells its cards how it moves.
class SideScroll extends ConsumerStatefulWidget {
  const SideScroll({super.key, required this.builder, this.pageable = false});

  /// Builds the horizontal list; it must use [controller].
  final Widget Function(ScrollController controller) builder;
  final bool pageable;

  @override
  ConsumerState<SideScroll> createState() => _SideScrollState();
}

class _SideScrollState extends ConsumerState<SideScroll> {
  final _own = ScrollController();
  bool _hover = false;
  RowScopeState? _scope;

  ScrollController get _controller => (widget.pageable ? _scope?.controller : null) ?? _own;

  @override
  void initState() {
    super.initState();
    // Re-check which arrows apply as the list scrolls.
    _own.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = RowScope.of(context);
    if (scope != _scope) {
      _scope?.controller.removeListener(_changed);
      _scope = scope?..controller.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _scope?.controller.removeListener(_changed);
    _own.dispose();
    super.dispose();
  }

  void _page(int direction) {
    final p = _controller.position;
    _controller.animateTo(
      (p.pixels + direction * p.viewportDimension * 0.85).clamp(p.minScrollExtent, p.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final paged = widget.pageable && _scope != null && _paged(ref);
    final controller = _controller;
    final p = controller.hasClients && controller.position.hasContentDimensions ? controller.position : null;
    final canBack = p != null && p.pixels > p.minScrollExtent + 1;
    final canForward = p != null && p.pixels < p.maxScrollExtent - 1;
    Widget arrow(IconData icon, int direction) => Center(
          // Mouse only: keyboard / D-pad focus stays on the cards.
          child: ExcludeFocus(
            child: Material(
              color: Colors.black.withValues(alpha: 0.6),
              shape: const CircleBorder(),
              child: IconButton(color: Colors.white, icon: Icon(icon), onPressed: () => _page(direction)),
            ),
          ),
        );

    final list = NotificationListener<ScrollMetricsNotification>(
      // The first layout's extents arrive here.
      onNotification: (_) {
        setState(() {});
        if (widget.pageable) _scope?.laidOut.value++;
        return false;
      },
      child: widget.builder(controller),
    );
    if (paged) {
      // Which way the row moves, for its cards to lean.
      return NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) {
          if (n.metrics.axis == Axis.horizontal && n.scrollDelta != null) _scope!.moved(n.scrollDelta!);
          return false;
        },
        child: list,
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        children: [
          list,
          if (_hover && canBack) Positioned(left: 4, top: 0, bottom: 0, child: arrow(Icons.chevron_left, -1)),
          if (_hover && canForward) Positioned(right: 4, top: 0, bottom: 0, child: arrow(Icons.chevron_right, 1)),
        ],
      ),
    );
  }
}
