import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/backdrop.dart';
import '../../../app/card_look.dart';
import '../../../app/glow_backdrop.dart';
import '../../../app/layout.dart';
import '../../../core/jellyfin/items.dart';
import '../../../theme/app_tokens.dart';
import '../../anime/widgets/mal_widgets.dart';
import '../../library/widgets/item_image.dart';
import '../../settings/appearance.dart';
import '../home_components.dart';
import 'preview.dart';

/// Depth's shelf ("shelf"): each item a narrow spine (its picture tinted,
/// the title running up it, the episode at the top, a dot in its colour at
/// the bottom). The one pointed at (the first, until then) slides out and
/// lifts, its spine swinging away as its cover swings in: a picture with
/// the episode playing muted, the episode, title and a play button. On a
/// phone the row is swiped: the case that comes to the left edge opens (the
/// row snaps to one), a tap on a spine slides to it, and a tap on the open
/// one plays it; its preview starts once the row has come to rest.
class ShelfRow extends StatefulWidget {
  const ShelfRow({super.key, required this.data, this.kicker});

  final LibraryRowData data;
  final String? kicker;

  @override
  State<ShelfRow> createState() => _ShelfRowState();
}

class _ShelfRowState extends State<ShelfRow> {
  /// Under the mouse or focus; null: the first stays open.
  int? _pointed;

  /// A phone's open case: the one swiped (or tapped) to the left edge.
  int _current = 0;

  /// A phone: the row at rest (previews wait for it).
  bool _resting = true;

  final _scroll = ScrollController();

  /// A phone: one step of the swipe, a spine and its gap. With case i
  /// open the ones before it are spines, so at `i * slot` it sits at the
  /// edge: which one is open follows from how far the row is swiped, never
  /// from where the cases are drawn (that moves as they open).
  double _slot = 72;
  int _count = 0;

  static const _gap = 10.0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_follow);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _follow() {
    if (_count == 0 || !_scroll.hasClients) return;
    final at = (_scroll.offset / _slot).round().clamp(0, _count - 1);
    if (at != _current) setState(() => _current = at);
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification && _resting) setState(() => _resting = false);
    if (n is ScrollEndNotification && !_resting) setState(() => _resting = true);
    return false;
  }

  void _slideTo(int i) {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      (i * _slot).clamp(0.0, _scroll.position.maxScrollExtent),
      duration: Duration(milliseconds: animationsOn(context) ? 450 : 1),
      curve: const Cubic(0.2, 0.8, 0.2, 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.data.items.value;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
    final layout = context.layout;
    final phone = layout.formFactor == FormFactor.phone;
    final tv = layout.formFactor == FormFactor.tv;
    // The design's sizes: spines 92 opening to 300 (a phone 62 → 228, a TV
    // 120 → 420), 360 tall.
    final spine = phone ? 62.0 : (tv ? 120.0 : 92.0);
    final open = phone ? 228.0 : (tv ? 420.0 : 300.0);
    final height = phone ? 300.0 : (tv ? 480.0 : 360.0);
    _slot = spine + _gap;
    _count = items.length;
    return Padding(
      padding: EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: layout.gutter),
            child: KickerHeading(
              kicker: widget.kicker ?? 'Your queue',
              title: Text(widget.data.title, style: CardLook.headingStyle(context)),
            ),
          ),
          SizedBox(
            height: height + 46,
            child: MouseRegion(
              onExit: (_) => setState(() => _pointed = null),
              child: LayoutBuilder(
                builder: (context, box) => NotificationListener<ScrollNotification>(
                  onNotification: phone ? _onScroll : null,
                  child: _list(context, items, box.maxWidth, spine, open, height, phone),
                ),
              ),
            ),
          ),
          // The shelf board, catching a little violet light.
          Padding(
            padding: EdgeInsets.symmetric(horizontal: layout.gutter),
            child: Container(
              height: 10,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF1A1D29), Color(0xFF0B0C12)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.22),
                    blurRadius: 28,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(
    BuildContext context,
    List<BaseItem> items,
    double width,
    double spine,
    double open,
    double height,
    bool phone,
  ) {
    final layout = context.layout;
    final openIndex = phone ? math.min(_current, items.length - 1) : (_pointed ?? 0);
    return ListView.separated(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      // A phone: room after the last case so it too can reach the edge.
      padding: EdgeInsets.fromLTRB(
        layout.gutter,
        30,
        phone ? math.max(layout.gutter, width - layout.gutter - open) : layout.gutter,
        0,
      ),
      physics: phone ? _SnapPhysics(slot: _slot) : null,
      clipBehavior: Clip.none,
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(width: _gap),
      itemBuilder: (context, i) => Align(
        alignment: Alignment.bottomCenter,
        child: _Case(
          item: items[i],
          open: i == openIndex,
          spineWidth: spine,
          openWidth: open,
          height: height,
          phone: phone,
          resting: _resting,
          onPoint: (on) => setState(() => _pointed = on ? i : (_pointed == i ? null : _pointed)),
          onTap: () {
            if (phone && _current != i) {
              _slideTo(i);
            } else {
              widget.data.onItemPressed(items[i]);
            }
          },
          onTitle: widget.data.onItemTitlePressed == null ? null : () => widget.data.onItemTitlePressed!(items[i]),
        ),
      ),
    );
  }
}

/// One case: its spine, or (open) its cover.
class _Case extends ConsumerStatefulWidget {
  const _Case({
    required this.item,
    required this.open,
    required this.spineWidth,
    required this.openWidth,
    required this.height,
    required this.phone,
    required this.resting,
    required this.onPoint,
    required this.onTap,
    required this.onTitle,
  });

  final BaseItem item;
  final bool open;
  final double spineWidth;
  final double openWidth;
  final double height;
  final bool phone;
  final bool resting;
  final void Function(bool pointed) onPoint;
  final VoidCallback onTap;
  final VoidCallback? onTitle;

  @override
  ConsumerState<_Case> createState() => _CaseState();
}

class _CaseState extends ConsumerState<_Case> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final moving = animationsOn(context);
    final art = item.posterImage ?? item.landscapeImage;
    final dot = art == null ? null : ref.watch(artColorProvider(art)).value;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onPoint(true);
        BackdropArt.show(item, ProviderScope.containerOf(context, listen: false));
      },
      onExit: (_) => setState(() => _hover = false),
      child: Focus(
        onFocusChange: (f) => widget.onPoint(f),
        child: GestureDetector(
          onTap: widget.onTap,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: widget.open ? 1 : 0),
            duration: Duration(milliseconds: moving ? 750 : 0),
            curve: const Cubic(0.2, 0.8, 0.2, 1),
            builder: (context, t, _) {
              final width = widget.spineWidth + (widget.openWidth - widget.spineWidth) * t;
              return Transform.translate(
                offset: Offset(0, -16 * t),
                child: SizedBox(
                  width: width,
                  height: widget.height,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // The spine swings away on its right edge...
                      if (t < 0.99)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: widget.spineWidth,
                          child: Opacity(
                            opacity: (1 - t * 1.6).clamp(0.0, 1.0),
                            child: Transform(
                              alignment: Alignment.centerRight,
                              transform: Matrix4.identity()
                                ..setEntry(3, 2, 1 / 1400)
                                ..rotateY(depthOf(context) * -math.pi / 2 * t),
                              child: _Spine(item: item, dot: dot, phone: widget.phone),
                            ),
                          ),
                        ),
                      // ...as the cover swings in on its left.
                      if (t > 0.01)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: widget.openWidth,
                          child: Opacity(
                            opacity: (t * 2.2).clamp(0.0, 1.0),
                            child: Transform(
                              alignment: Alignment.centerLeft,
                              transform: Matrix4.identity()
                                ..setEntry(3, 2, 1 / 1400)
                                ..rotateY(depthOf(context) * 96 * math.pi / 180 * (1 - t)),
                              child: _Cover(
                                item: item,
                                glow: dot,
                                // Text once it faces you: no letters redrawn
                                // at every angle.
                                settled: t > 0.97,
                                // A phone: by itself once the row rests.
                                preview: widget.open && (widget.phone ? widget.resting : _hover),
                                phone: widget.phone,
                                onTitle: widget.onTitle,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Spine extends StatelessWidget {
  const _Spine({required this.item, required this.dot, required this.phone});

  final BaseItem item;
  final Color? dot;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final tint = dot ?? const Color(0xFF2A2440);
    final code = item.episodeLabel;
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [BoxShadow(color: Color(0xE6000000), blurRadius: 30, spreadRadius: -18, offset: Offset(0, 20))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // (No colour filter for the design's desaturation: a layer per
              // spine; the tint over it does the work.)
              ItemImage(image: item.posterImage ?? item.landscapeImage, maxWidth: 120),
              // Tinted in its own colour, darker across the middle.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      tint.withValues(alpha: 0.82),
                      const Color(0xFF06070B).withValues(alpha: 0.55 * 0.82),
                      tint.withValues(alpha: 0.82),
                    ],
                  ),
                ),
              ),
              // Its edges: lit on the left, shadowed on the right.
              const DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: Color(0x24FFFFFF), width: 2)),
                  gradient: LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    stops: [0, 0.18],
                    colors: [Color(0x66000000), Color(0x00000000)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 14),
                child: Column(
                  children: [
                    if (code != null)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0x8006070B),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          child: FittedBox(
                            child: Text(
                              code,
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Text(
                          _title(item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: phone ? 15 : 20,
                                letterSpacing: -0.2,
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: phone ? 18 : 26,
                      height: phone ? 18 : 26,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withValues(alpha: 0.9)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({
    required this.item,
    required this.glow,
    required this.settled,
    required this.preview,
    required this.phone,
    required this.onTitle,
  });

  final BaseItem item;
  final Color? glow;
  final bool settled;
  final bool preview;
  final bool phone;
  final VoidCallback? onTitle;

  @override
  Widget build(BuildContext context) {
    final cyan = context.tokens.accent2 ?? Theme.of(context).colorScheme.secondary;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: context.tokens.surface ?? const Color(0xFF0E1018),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: (glow ?? Colors.black).withValues(alpha: 0.4),
            blurRadius: 60,
            spreadRadius: -24,
            offset: const Offset(0, 28),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(19),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 62,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    child: ItemImage(image: item.landscapeImage ?? item.backdropImage ?? item.posterImage, maxWidth: 420),
                  ),
                  EpisodePreview(item: item, active: preview),
                  if (settled) MalScoreBadge(item: item),
                ],
              ),
            ),
            Expanded(
              flex: 38,
              child: settled
                  ? Padding(
                      padding: EdgeInsets.fromLTRB(phone ? 14 : 18, phone ? 10 : 14, phone ? 14 : 18, phone ? 10 : 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (item.episodeLabel case final code?)
                            Text(code, style: TextStyle(color: cyan, fontSize: 12, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          GestureDetector(
                            onTap: onTitle,
                            child: Text(
                              _title(item),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                height: 1.2,
                              ),
                            ),
                          ),
                          if (item.type == ItemType.episode)
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.tokens.textMuted ?? const Color(0xFF9AA0B2),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          // The play button in the room left (a phone's
                          // short cover, large text: smaller, not cut off).
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomRight,
                              child: FittedBox(
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFF2F0FF)),
                                  child: const Icon(Icons.play_arrow_rounded, color: Color(0xFF0B0C12)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

String _title(BaseItem item) => item.type == ItemType.episode ? item.seriesName ?? item.name : item.name;

/// A phone's shelf: lands with a case at the left edge. Its steps are narrow
/// (a spine's width), so it's slowed down: the finger moves it at [_drag] of
/// its own speed, a flick carries it on by at most [_mostPerFlick] cases, and
/// it settles gently.
class _SnapPhysics extends ScrollPhysics {
  const _SnapPhysics({required this.slot, super.parent});

  final double slot;

  static const _drag = 0.6;
  static const _mostPerFlick = 2;

  /// Faster than this, a flick always moves on, however short.
  static const _flick = 200.0;
  static final _settle = SpringDescription.withDampingRatio(mass: 0.5, stiffness: 60, ratio: 1.1);

  @override
  _SnapPhysics applyTo(ScrollPhysics? ancestor) => _SnapPhysics(slot: slot, parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      super.applyPhysicsToUserOffset(position, offset * _drag);

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final speed = velocity * _drag;
    // Where a free flick would come to rest; then the case nearest that.
    final lands = super.createBallisticSimulation(position, speed)?.x(double.infinity) ?? position.pixels;
    final from = position.pixels / slot;
    var to = (lands / slot).round();
    if (velocity > _flick) to = to.clamp(from.floor() + 1, from.floor() + _mostPerFlick);
    if (velocity < -_flick) to = to.clamp(from.ceil() - _mostPerFlick, from.ceil() - 1);
    final target = (to * slot).clamp(position.minScrollExtent, position.maxScrollExtent);
    final tolerance = toleranceFor(position);
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(_settle, position.pixels, target, speed, tolerance: tolerance);
  }
}
