import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../app/layout.dart';
import '../../../core/jellyfin/items.dart';
import '../../../theme/app_tokens.dart';
import '../../library/library_providers.dart';
import '../../library/navigation.dart';
import '../../library/widgets/card_actions.dart';
import '../../library/widgets/item_image.dart';
import '../../settings/appearance.dart';
import '../home_header.dart';
import 'deck_hero.dart';

/// Depth's header on a phone: the featured shows as portrait cards stacked
/// to the side. The next ones step out to the right, each a little smaller;
/// the one before peeks in at the left edge. The front card follows a swipe
/// and moves on past a quarter of its width (or a flick); the cards then
/// slide into their new places.
///
/// The header's state (which show, the trailer, the timer) is HomeHeader's;
/// this only draws it.
class SideDeck extends StatefulWidget {
  const SideDeck({
    super.key,
    required this.items,
    required this.index,
    required this.progress,
    required this.video,
    required this.trailerShowing,
    required this.trailer,
    required this.muted,
    required this.paused,
    required this.chip,
    required this.onGo,
    required this.onMute,
    required this.onPause,
  });

  final List<BaseItem> items;
  final int index;
  final double progress;
  final VideoController? video;
  final bool trailerShowing;
  final bool trailer;
  final bool muted;
  final bool paused;
  final String chip;
  final void Function(int step) onGo;
  final VoidCallback onMute;
  final VoidCallback onPause;

  @override
  State<SideDeck> createState() => _SideDeckState();
}

class _SideDeckState extends State<SideDeck> {
  /// How far the front card has been dragged (negative: towards the next).
  double _drag = 0;
  bool _dragging = false;

  void _end(DragEndDetails d, double width) {
    final v = d.primaryVelocity ?? 0;
    final step = _drag < -width / 4 || v < -600
        ? 1
        : _drag > width / 4 || v > 600
        ? -1
        : 0;
    setState(() {
      _dragging = false;
      _drag = 0;
    });
    if (step != 0 && widget.items.length > 1) widget.onGo(step);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final n = widget.items.length;
    final top = statusBarHeight(context) + 76;
    // The front card: most of the width, a poster's shape (shorter on a
    // short screen); the stack to its right shows in the space left.
    const left = 24.0;
    final width = size.width - left - 52;
    final height = math.min(width * 1.42, size.height * 0.6);
    final moving = animationsOn(context);
    final duration = Duration(milliseconds: _dragging || !moving ? 0 : 420);
    const curve = Cubic(0.2, 0.8, 0.2, 1);

    // Where a card [depth] steps from the front sits: its box.
    Rect slot(int depth) {
      if (depth < 0) {
        // The one before: just its right edge, at the left of the screen.
        final s = 0.9;
        return Rect.fromLTWH(left - width * s + 12, top + height * (1 - s) / 2, width * s, height * s);
      }
      final s = math.pow(0.9, depth).toDouble();
      final h = height * s;
      // Right edges stepping out 22px at a time.
      final right = left + width + 22 * depth;
      return Rect.fromLTWH(right - width * s, top + (height - h) / 2, width * s, h);
    }

    // Each show once: the one before (with three or more), the front one,
    // and up to three behind.
    final before = n > 2;
    final behind = math.min(3, n - 1 - (before ? 1 : 0));
    final cards = <({BaseItem item, int depth})>[
      for (var d = before ? -1 : 0; d <= behind; d++) (item: widget.items[(widget.index + d) % n], depth: d),
    ];
    // Back to front.
    cards.sort((a, b) => (b.depth < 0 ? 0.5 : b.depth.toDouble()).compareTo(a.depth < 0 ? 0.5 : a.depth.toDouble()));

    return SizedBox(
      height: top + height + 52,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => setState(() => _drag += d.delta.dx),
        onHorizontalDragEnd: (d) => _end(d, width),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final c in cards)
              () {
                final box = slot(c.depth);
                final front = c.depth == 0;
                return AnimatedPositioned(
                  key: ValueKey('side-${c.item.id}'),
                  duration: duration,
                  curve: curve,
                  left: box.left + (front ? _drag : 0),
                  top: box.top,
                  width: box.width,
                  height: box.height,
                  child: _Card(
                    item: c.item,
                    front: front,
                    // The ones behind dim with distance.
                    dim: front ? 0 : (c.depth < 0 ? 0.55 : math.min(0.75, 0.35 + 0.15 * c.depth)),
                    video: front ? widget.video : null,
                    trailerShowing: front && widget.trailerShowing,
                    chip: widget.chip,
                    settleAfter: duration + const Duration(milliseconds: 60),
                  ),
                );
              }(),
            // Progress, one segment a show; pause (and mute) beside it.
            if (n > 1)
              Positioned(
                left: left,
                width: width,
                top: top + height + 18,
                child: _Progress(
                  index: widget.index,
                  count: math.min(n, 10),
                  progress: widget.progress,
                  paused: widget.paused,
                  trailer: widget.trailer,
                  muted: widget.muted,
                  onPause: widget.onPause,
                  onMute: widget.onMute,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One card: the show's poster (the trailer over it on the front card) and,
/// once the front card has settled, its details.
class _Card extends ConsumerWidget {
  const _Card({
    required this.item,
    required this.front,
    required this.dim,
    required this.video,
    required this.trailerShowing,
    required this.chip,
    required this.settleAfter,
  });

  final BaseItem item;
  final bool front;
  final double dim;
  final VideoController? video;
  final bool trailerShowing;
  final String chip;
  final Duration settleAfter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final radius = BorderRadius.circular(context.tokens.radius.panel + 6);
    final page = context.tokens.background;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 24, offset: Offset(0, 10))],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            RepaintBoundary(
              child: ItemImage(image: item.posterImage ?? item.backdropImage, maxWidth: 420),
            ),
            if (video != null)
              AnimatedOpacity(
                opacity: trailerShowing ? 1 : 0,
                duration: const Duration(milliseconds: 600),
                child: IgnorePointer(child: Video(controller: video!, fit: BoxFit.cover, controls: NoVideoControls)),
              ),
            // Readable text at the bottom.
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    stops: [0, 0.42],
                    colors: [Color(0xE606070B), Color(0x0006070B)],
                  ),
                ),
              ),
            ),
            if (dim > 0) IgnorePointer(child: ColoredBox(color: page.withValues(alpha: dim))),
            if (front) ...[
              Positioned.fill(
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => openItem(context, item)),
              ),
              Positioned.fill(
                child: _Settled(
                  key: ValueKey('settled-${item.id}'),
                  after: settleAfter,
                  child: _Front(item: item, chip: chip),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The front card's text: the chip at the top; the details line, Play and
/// ♥ at the bottom.
class _Front extends ConsumerWidget {
  const _Front({required this.item, required this.chip});

  final BaseItem item;
  final String chip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final series = item.type == ItemType.series;
    final next = series ? ref.watch(nextUpForSeriesProvider(item.id)).value : null;
    final details = [
      if (item.productionYear case final y?) '$y',
      if (series && (item.childCount ?? 0) > 0) '${item.childCount} season${item.childCount == 1 ? '' : 's'}',
      if (item.type == ItemType.movie && item.runTimeTicks != null) '${item.runTimeTicks! ~/ 600000000} min',
      ...item.genres.take(2),
    ];
    final favorite = item.userData.isFavorite;
    final label = switch ((series, next)) {
      (true, final BaseItem n) when n.userData.hasProgress => 'Resume ${n.episodeLabel ?? ''}',
      (true, final BaseItem n) => 'Play ${n.episodeLabel ?? ''}',
      (false, _) when item.userData.hasProgress => 'Resume',
      _ => 'Play',
    };
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RiseIn(delay: 0, child: NowPlayingChip(trailerLabel: chip)),
          const Spacer(),
          RiseIn(
            delay: 100,
            child: Text(
              details.join('  •  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(color: const Color(0xFFC4C7D4), fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 12),
          RiseIn(
            delay: 200,
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFF2F0FF),
                      foregroundColor: const Color(0xFF0B0C12),
                      minimumSize: const Size(0, 50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 24),
                    label: Text(label.trim(), maxLines: 1, overflow: TextOverflow.ellipsis),
                    onPressed: () => openItem(context, next ?? item, play: next != null || !series),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox.square(
                  dimension: 50,
                  child: IconButton(
                    tooltip: favorite ? 'Remove from favourites' : 'Add to favourites',
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0x99FFFFFF).withValues(alpha: 0.16),
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: Icon(favorite ? Icons.favorite : Icons.favorite_border, color: favorite ? Colors.redAccent : null),
                    onPressed: () async {
                      await CardActions(context).setFavorite(item, !favorite);
                      ref.invalidate(headerFeaturedProvider);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows [child] once the card has settled ([after]).
class _Settled extends StatefulWidget {
  const _Settled({super.key, required this.after, required this.child});

  final Duration after;
  final Widget child;

  @override
  State<_Settled> createState() => _SettledState();
}

class _SettledState extends State<_Settled> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(widget.after, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) => _shown ? widget.child : const SizedBox.shrink();
}

/// One segment a show (the current one filling), pause, and mute with a
/// trailer.
class _Progress extends StatelessWidget {
  const _Progress({
    required this.index,
    required this.count,
    required this.progress,
    required this.paused,
    required this.trailer,
    required this.muted,
    required this.onPause,
    required this.onMute,
  });

  final int index;
  final int count;
  final double progress;
  final bool paused;
  final bool trailer;
  final bool muted;
  final VoidCallback onPause;
  final VoidCallback onMute;

  @override
  Widget build(BuildContext context) {
    final cyan = context.tokens.accent2 ?? Theme.of(context).colorScheme.secondary;
    final current = index % count;
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              for (var i = 0; i < count; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        value: i < current ? 1 : (i == current ? progress.clamp(0, 1) : 0),
                        color: cyan,
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // Lite has no trailers to pause or mute.
        if (effectsOf(context).playsTrailers) ...[
          const SizedBox(width: 10),
          if (trailer) ...[
            GlassRound(
              tooltip: muted ? 'Unmute' : 'Mute',
              icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
              onPressed: onMute,
              size: 36,
            ),
            const SizedBox(width: 6),
          ],
          GlassRound(
            tooltip: paused ? 'Play' : 'Pause',
            icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
            onPressed: onPause,
            size: 36,
          ),
        ],
      ],
    );
  }
}
