import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../app/glow_backdrop.dart';
import '../../../app/layout.dart';
import '../../../core/jellyfin/items.dart';
import '../../../theme/app_tokens.dart';
import '../../library/library_providers.dart';
import '../../library/navigation.dart';
import '../../library/widgets/card_actions.dart';
import '../../library/widgets/item_image.dart';
import '../../settings/appearance.dart';
import '../home_header.dart';

/// Depth's header ("deck"): the featured shows as panels stacked going back
/// into the screen. The front one plays its trailer (or slowly zooms over
/// its backdrop) under its details; the ones behind are dimmed. Moving on,
/// the front panel flies out past the viewer and the next comes forward.
/// Scrolling past tips the deck back and sinks it.
///
/// The header's state (which show, the trailer, the timer) is HomeHeader's;
/// this only draws it.
class DeckView extends ConsumerWidget {
  const DeckView({
    super.key,
    required this.items,
    required this.index,
    required this.progress,
    required this.slideLength,
    required this.video,
    required this.trailerShowing,
    required this.trailer,
    required this.muted,
    required this.paused,
    required this.scrolled,
    required this.chip,
    required this.onGo,
    required this.onMute,
    required this.onPause,
    required this.onHover,
  });

  final List<BaseItem> items;
  final int index;

  /// Through the current show, 0..1.
  final double progress;
  final Duration slideLength;
  final VideoController? video;
  final bool trailerShowing;

  /// The current show has a trailer (mute applies).
  final bool trailer;
  final bool muted;
  final bool paused;
  final ValueListenable<double> scrolled;

  /// The chip over the title ("Now playing · Trailer").
  final String chip;
  final void Function(int step) onGo;
  final VoidCallback onMute;
  final VoidCallback onPause;
  final void Function(bool hovered) onHover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = context.layout;
    final size = MediaQuery.sizeOf(context);
    final phone = layout.formFactor == FormFactor.phone;
    final tv = layout.formFactor == FormFactor.tv;
    // The design's panels: 1180×560 on a PC (growing with the window), 350×450
    // on a phone, 1520×660 on a TV (at 1920 wide), fitted to the screen.
    final top = statusBarHeight(context) + (phone ? 84.0 : (tv ? 96.0 : 110.0));
    final double width;
    final double height;
    if (phone) {
      width = math.min(350, size.width - 40);
      height = width * 450 / 350;
    } else if (tv) {
      width = size.width * 1520 / 1920;
      height = width * 660 / 1520;
    } else {
      // As wide as 90% of the window, as long as the panel (in the design's
      // shape) and a peek of the first row still fit on screen.
      final room = size.height - top - 150;
      width = math.max(math.min(size.width * 0.9, room / 0.475), math.min(size.width * 0.9, 760));
      height = math.max(380, width * 0.475);
    }
    final stage = top + height + (phone ? 64 : 56);
    // Each panel behind: how far its top shows above the one in front, and
    // how far back it sits.
    final step = phone ? (y: 26.0, z: 90.0) : (tv ? (y: 52.0, z: 170.0) : (y: 48.0, z: 150.0));

    // The panels: the one that just left, the front, and up to three behind.
    final n = items.length;
    final shown = math.min(n, 5);
    final panels = <({BaseItem item, int depth})>[
      for (var d = shown > 1 ? -1 : 0; d < shown - 1; d++) (item: items[(index + d) % n], depth: d),
    ];
    // Back to front, so the front panel paints last (the leaving one above all).
    panels.sort((a, b) => _order(b.depth).compareTo(_order(a.depth)));

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => onGo(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => onGo(1),
      },
      child: FocusTraversalGroup(
        child: MouseRegion(
          onEnter: (_) => onHover(true),
          onExit: (_) => onHover(false),
          child: ValueListenableBuilder<double>(
            valueListenable: scrolled,
            builder: (context, pixels, child) {
              // Scrolling past: tips back and sinks (the design's view() exit).
              // Sinking, and fading under a cover in the page's colour: tipping
              // and shrinking it (the design) redrew its text at every size.
              // Always the same widgets (a different wrapper once scrolled
              // rebuilt the deck from scratch: panels jumped, text vanished).
              final p = animationsOn(context) ? (pixels / stage).clamp(0.0, 1.0) : 0.0;
              return Transform.translate(
                offset: Offset(0, stage * 0.18 * p),
                child: Stack(
                  children: [
                    child!,
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(color: context.tokens.background.withValues(alpha: 0.85 * p)),
                      ),
                    ),
                  ],
                ),
              );
            },
            child: SizedBox(
              height: stage,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // The next show to join the back of the deck: its artwork,
                  // drawn tiny under the panels once the deck has settled, so
                  // it's on the graphics card before it appears (uploading a
                  // large image during the move stalled frames).
                  if (n > shown)
                    Positioned(
                      top: top + height / 2,
                      left: size.width / 2,
                      width: 2,
                      height: 2,
                      child: _Arrived(
                        key: ValueKey('pre-${items[(index + shown - 1) % n].id}'),
                        after: Duration(milliseconds: animationsOn(context) ? 1600 : 0),
                        child: ItemImage(
                        image: () {
                          final next = items[(index + shown - 1) % n];
                          return next.backdropImage ?? next.landscapeImage ?? next.posterImage;
                        }(),
                        maxWidth: _artWidth(context, width),
                      ),
                      ),
                    ),
                  for (final p in panels)
                    _Panel(
                      key: ValueKey('deck-${p.item.id}'),
                      item: p.item,
                      depth: p.depth,
                      top: top,
                      width: width,
                      height: height,
                      step: step,
                      phone: phone,
                      front: p.depth == 0,
                      slideLength: slideLength,
                      video: p.depth == 0 ? video : null,
                      trailerShowing: p.depth == 0 && trailerShowing,
                      onGo: onGo,
                    ),
                  // The front panel's text and controls, over it rather than
                  // in it: text drawn inside the moving 3D panel had every
                  // letter redrawn at a new size each frame (on Windows that
                  // stalled for a fifth of a second). The details come once
                  // the panel has arrived.
                  Positioned(
                    top: top,
                    left: (size.width - width) / 2,
                    width: width,
                    height: height,
                    child: Stack(
                      children: [
                        Positioned(
                          left: phone ? 20 : math.min(56, math.max(24, width * 0.04)),
                          right: phone ? 20 : 240,
                          bottom: phone ? 22 : 48,
                          child: _Arrived(
                            key: ValueKey('d-${items[index % n].id}'),
                            after: Duration(milliseconds: animationsOn(context) ? 900 : 0),
                            child: RepaintBoundary(
                              child: _Details(item: items[index % n], phone: phone, chip: chip),
                            ),
                          ),
                        ),
                        if (!phone)
                          Positioned(
                            right: math.min(40, math.max(20, width * 0.03)),
                            bottom: 48,
                            child: RepaintBoundary(
                              child: _Controls(
                                index: index,
                                count: n,
                                progress: progress,
                                trailer: trailer,
                                muted: muted,
                                paused: paused,
                                tv: tv,
                                onGo: onGo,
                                onMute: onMute,
                                onPause: onPause,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // A phone: progress segments and pause under the deck.
                  if (phone && n > 1)
                    Positioned(
                      top: top + height + 18,
                      left: (size.width - width) / 2,
                      width: width,
                      child: _PhoneControls(
                        index: index,
                        count: math.min(n, 10),
                        progress: progress,
                        paused: paused,
                        trailer: trailer,
                        muted: muted,
                        onPause: onPause,
                        onMute: onMute,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Paint order: the leaving panel on top, then front to back.
  static int _order(int depth) => depth < 0 ? -100 : depth;
}

/// One panel, gliding to its place in the deck as [depth] changes: 0 the
/// front, 1.. behind it, -1 flying out past the viewer.
class _Panel extends ConsumerWidget {
  const _Panel({
    super.key,
    required this.item,
    required this.depth,
    required this.top,
    required this.width,
    required this.height,
    required this.step,
    required this.phone,
    required this.front,
    required this.slideLength,
    required this.video,
    required this.trailerShowing,
    required this.onGo,
  });

  final BaseItem item;
  final int depth;
  final double top;
  final double width;
  final double height;
  final ({double y, double z}) step;
  final bool phone;
  final bool front;
  final Duration slideLength;
  final VideoController? video;
  final bool trailerShowing;
  final void Function(int step) onGo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final moving = animationsOn(context);
    final radius = context.tokens.radius.panel + (phone ? 4 : 4);
    final art = item.backdropImage ?? item.landscapeImage ?? item.posterImage;
    final glow = art == null ? null : ref.watch(artColorProvider(art)).value;
    return TweenAnimationBuilder<double>(
      // New panels come from further back.
      tween: Tween(begin: depth + 1.0, end: depth.toDouble()),
      duration: Duration(milliseconds: moving ? 1100 : 0),
      curve: const Cubic(0.2, 0.8, 0.2, 1),
      builder: (context, d, child) {
        final leaving = d < 0;
        final t = leaving ? -d : 0.0;
        final back = math.max(d, 0.0);
        // Positive is away from the viewer here (CSS: negative). The panel
        // leaving flies a shorter way than the design's and is gone by
        // halfway: a huge fading layer stuttered on large screens.
        final y = leaving ? 50 * t : 0.0;
        final z = leaving ? -160 * t : step.z * back;
        final tilt = leaving ? 8 * t : 0.0;
        // Behind: faded into the page by a cover in its colour, not by
        // opacity (an offscreen copy of each panel, every frame, stuttered
        // on large windows). Only the panel flying out fades.
        final opacity = back < 1 ? 1 - 0.15 * back : math.max(0.0, 0.85 - 0.22 * back);
        final shade = back < 1 ? 0.45 * back : math.min(0.9, 0.45 + 0.08 * (back - 1));
        final dim = leaving ? 0.0 : (1 - (1 - shade) * opacity).clamp(0.0, 1.0);
        final page = context.tokens.background;
        return Positioned(
          top: top,
          left: 0,
          right: 0,
          height: height,
          child: IgnorePointer(
            ignoring: depth != 0,
            // At 1 (every panel but the one leaving) this draws no layer.
            child: Opacity(
              opacity: leaving ? (1 - 2 * t).clamp(0.0, 1.0) : 1,
              // Up the stairs, in screen space: the depth shrinks each panel
              // about its middle, so its top is lifted back up as well.
              child: Transform.translate(
                offset: Offset(0, -step.y * back - height * (1 - _shrink(back, step.z)) / 2),
                child: Transform(
                alignment: const Alignment(0, -1.6),
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 1 / 1500)
                  ..translateByDouble(0, y, z, 1)
                  ..rotateX(tilt * math.pi / 180),
                  child: Center(
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        child!,
                        if (dim > 0)
                          IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: page.withValues(alpha: dim),
                                borderRadius: BorderRadius.circular(radius),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              ),
            ),
          ),
        );
      },
      // Drawn once and moved as a picture while the deck shifts.
      // In layers, each drawn once and moved as a picture: the shadow, the
      // artwork (zooming), the shading, and the text (rising in). Redrawing
      // all of it while the text moved stuttered on large screens.
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The front panel glows in its artwork's colour; the ones behind
          // are only dimmed (a shadow would show under the front).
          if (front)
            RepaintBoundary(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  boxShadow: [
                    BoxShadow(
                      color: (glow ?? Colors.black).withValues(alpha: glow == null ? 0.6 : 0.55),
                      blurRadius: 60,
                      spreadRadius: -24,
                      offset: const Offset(0, 40),
                    ),
                  ],
                ),
              ),
            ),
          ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: front ? Border.all(color: Colors.white.withValues(alpha: 0.18)) : null,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                RepaintBoundary(
                  child: _SlowZoom(active: front && moving, length: slideLength, child: ItemImage(image: art, maxWidth: _artWidth(context, width))),
                ),
                if (video != null)
                  AnimatedOpacity(
                    opacity: trailerShowing ? 1 : 0,
                    duration: const Duration(milliseconds: 600),
                    child: IgnorePointer(child: Video(controller: video!, fit: BoxFit.cover, controls: NoVideoControls)),
                  ),
                // Readable text: dark on the left and at the bottom.
                const RepaintBoundary(
                  child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        stops: [0, 0.45, 0.75],
                        colors: [Color(0xE006070B), Color(0x7306070B), Color(0x0006070B)],
                      ),
                    ),
                  ),
                ),
                ),
                const RepaintBoundary(
                  child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        stops: [0, 0.4],
                        colors: [Color(0xB306070B), Color(0x0006070B)],
                      ),
                    ),
                  ),
                ),
                ),
                if (front) ...[
                  // The picture opens the show; on a phone, the top corners
                  // go back and forward.
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) {
                        if (phone && d.localPosition.dy < height * 0.45) {
                          onGo(d.localPosition.dx < width / 2 ? -1 : 1);
                        } else {
                          openItem(context, item);
                        }
                      },
                      onHorizontalDragEnd: (d) {
                        final v = d.primaryVelocity ?? 0;
                        if (v.abs() > 300) onGo(v < 0 ? 1 : -1);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        ],
      ),
    );
  }
}

/// Panels' artwork width: the panel's, at most 1600 pixels (a backdrop is
/// rarely larger, and bigger uploads stalled frames).
double _artWidth(BuildContext context, double width) =>
    math.min(width, 1600 / MediaQuery.devicePixelRatioOf(context));

/// Shows [child] [after] a moment (the panel under it arriving).
class _Arrived extends StatefulWidget {
  const _Arrived({super.key, required this.after, required this.child});

  final Duration after;
  final Widget child;

  @override
  State<_Arrived> createState() => _ArrivedState();
}

class _ArrivedState extends State<_Arrived> {
  late bool _shown = widget.after == Duration.zero;
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    if (!_shown) _wait = Timer(widget.after, () => setState(() => _shown = true));
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _shown ? widget.child : const SizedBox.shrink();
}

/// How much smaller a panel [back] steps behind looks (as measured: the
/// deck's perspective, about its middle).
double _shrink(double back, double z) => 1 / (1 + back * z / 750);

/// A slow zoom-and-pan over the backdrop while [active].
class _SlowZoom extends StatelessWidget {
  const _SlowZoom({required this.active, required this.length, required this.child});

  final bool active;
  final Duration length;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: active ? 1 : 0),
        duration: active ? length + const Duration(seconds: 2) : Duration.zero,
        curve: Curves.easeInOut,
        child: child,
        builder: (context, t, child) => Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..translateByDouble(-0.03 * t * 400, -0.02 * t * 300, 0, 1)
            ..scaleByDouble(1.06 + 0.08 * t, 1.06 + 0.08 * t, 1, 1),
          child: child,
        ),
      );
}

/// The front panel's text: a "Now playing" chip, the title (or logo) coming
/// into focus, the details line, the overview, and the buttons, each rising
/// in a moment after the one before.
class _Details extends ConsumerWidget {
  const _Details({required this.item, required this.phone, required this.chip});

  final BaseItem item;
  final bool phone;
  final String chip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final series = item.type == ItemType.series;
    final next = series ? ref.watch(nextUpForSeriesProvider(item.id)).value : null;
    final meta = [
      if (item.productionYear case final y?) '$y',
      if (series && (item.childCount ?? 0) > 0) '${item.childCount} season${item.childCount == 1 ? '' : 's'}',
      if (item.type == ItemType.movie && item.runTimeTicks != null) '${item.runTimeTicks! ~/ 600000000} min',
    ];
    final logo = item.logoImage;
    final titleStyle = theme.textTheme.displayMedium?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w800,
      fontSize: phone ? 34 : 60,
      height: 1,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!phone) RiseIn(delay: 0, child: NowPlayingChip(trailerLabel: chip)),
          SizedBox(height: phone ? 0 : 20),
          _TitleIn(
            child: logo != null
                ? SizedBox(
                    height: phone ? 64 : 120,
                    width: phone ? 240 : 440,
                    child: ItemImage(
                      image: logo,
                      maxWidth: 440,
                      fit: BoxFit.contain,
                      alignment: Alignment.bottomLeft,
                      placeholder: Text(item.name, maxLines: 2, style: titleStyle),
                    ),
                  )
                : Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle),
          ),
          SizedBox(height: phone ? 12 : 18),
          RiseIn(
            delay: 150,
            child: Wrap(
              spacing: 16,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (item.communityRating case final r?)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_rounded, size: 16, color: tokens.star),
                      const SizedBox(width: 4),
                      Text(r.toStringAsFixed(1), style: _meta(theme)),
                    ],
                  ),
                for (final m in meta) Text(m, style: _meta(theme)),
                if (item.officialRating case final age?)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      child: Text(age, style: _meta(theme)?.copyWith(fontSize: 12)),
                    ),
                  ),
                if (item.genres.isNotEmpty && !phone)
                  Text(
                    item.genres.take(3).join(' · '),
                    style: _meta(theme)?.copyWith(color: const Color(0xFFA8ADBD), fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
          if (item.overview case final overview? when overview.isNotEmpty) ...[
            const SizedBox(height: 12),
            RiseIn(
              delay: 300,
              child: Text(
                overview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFFD4D6E0), height: 1.6),
              ),
            ),
          ],
          SizedBox(height: phone ? 18 : 24),
          RiseIn(delay: 450, child: HeroButtons(item: item, next: next, phone: phone)),
        ],
      ),
    );
  }

  static TextStyle? _meta(ThemeData theme) =>
      theme.textTheme.labelLarge?.copyWith(color: const Color(0xFFE8E9F0), fontWeight: FontWeight.w700);
}

/// The header's chip with no trailer playing.
const chipFeatured = 'Featured';
const chipPaused = 'Paused';

/// A label in a glass chip, with a little equaliser while something plays.
class NowPlayingChip extends StatelessWidget {
  const NowPlayingChip({super.key, required this.trailerLabel});

  final String trailerLabel;

  bool get _playing => trailerLabel != chipFeatured && trailerLabel != chipPaused;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x8C0A0B12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(_playing ? 12 : 14, 7, 14, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_playing) ...[
                Equaliser(color: context.tokens.accent2 ?? Theme.of(context).colorScheme.secondary),
                const SizedBox(width: 10),
              ],
              Text(
                trailerLabel.toUpperCase(),
                style: const TextStyle(
                  color: Color(0xFFCFD2DE),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.7,
                ),
              ),
            ],
          ),
        ),
      );
}

class Equaliser extends StatefulWidget {
  const Equaliser({super.key, required this.color});

  final Color color;

  @override
  State<Equaliser> createState() => EqualiserState();
}

class EqualiserState extends State<Equaliser> with SingleTickerProviderStateMixin {
  late final _beat = AnimationController(vsync: this, duration: const Duration(seconds: 1));

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final moving = animationsOn(context);
    if (moving && !_beat.isAnimating) _beat.repeat();
    if (!moving && _beat.isAnimating) _beat.stop();
    return SizedBox(
      height: 14,
      child: AnimatedBuilder(
        animation: _beat,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final delay in const [0.0, 0.2, 0.4, 0.1])
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Container(
                  width: 3,
                  height: 3 + 11 * (0.5 - 0.5 * math.cos(2 * math.pi * (_beat.value + delay))),
                  decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(2)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Rises into place a moment ([delay] ms) after the panel comes forward.
class RiseIn extends StatelessWidget {
  const RiseIn({super.key, required this.delay, required this.child});

  final int delay;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!animationsOn(context)) return child;
    const length = 900;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: length + delay),
      child: child,
      builder: (context, v, child) {
        final t = const Cubic(0.2, 0.7, 0.2, 1).transform(((v * (length + delay) - delay) / length).clamp(0.0, 1.0));
        return Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, 22 * (1 - t)), child: child),
        );
      },
    );
  }
}

/// The title coming in: fading up as it rises.
class _TitleIn extends StatelessWidget {
  const _TitleIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!animationsOn(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1500),
      curve: const Cubic(0.2, 0.7, 0.2, 1),
      child: child,
      // Rising, not zooming: text at a changing size stalls some renderers.
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
      ),
    );
  }
}

/// Play (or Resume) S1:E5, Favourite and Details: a light pill and two
/// glass ones (round on a phone).
class HeroButtons extends ConsumerWidget {
  const HeroButtons({super.key, required this.item, required this.next, required this.phone, this.roundFavorite = false});

  final BaseItem item;
  final BaseItem? next;
  final bool phone;

  /// Favourite as a round ♥ only (the programme hero).
  final bool roundFavorite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final series = item.type == ItemType.series;
    final label = switch ((series, next)) {
      (true, final BaseItem n) when n.userData.hasProgress => 'Resume ${n.episodeLabel ?? ''}',
      (true, final BaseItem n) => 'Play ${n.episodeLabel ?? ''}',
      (false, _) when item.userData.hasProgress => 'Resume',
      _ => 'Play',
    };
    final favorite = item.userData.isFavorite;
    final violet = Theme.of(context).colorScheme.primary;
    // A soft violet glow under it.
    final play = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: [BoxShadow(color: violet.withValues(alpha: 0.8), blurRadius: 40, spreadRadius: -8, offset: const Offset(0, 10))],
      ),
      child: FilledButton.icon(
        autofocus: ref.watch(isTvProvider),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFF2F0FF),
          foregroundColor: const Color(0xFF0B0C12),
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.fromLTRB(22, 0, 28, 0),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          elevation: 0,
        ),
        icon: const Icon(Icons.play_arrow_rounded, size: 22),
        label: Text(label.trim()),
        onPressed: () => openItem(context, next ?? item, play: next != null || !series),
      ),
    );
    Future<void> toggleFavorite() async {
      await CardActions(context).setFavorite(item, !favorite);
      ref.invalidate(headerFeaturedProvider);
    }

    if (phone) {
      return Row(
        children: [
          Expanded(child: play),
          const SizedBox(width: 10),
          GlassRound(
            tooltip: favorite ? 'Remove from favourites' : 'Add to favourites',
            icon: Icon(favorite ? Icons.favorite : Icons.favorite_border, color: favorite ? Colors.redAccent : null),
            onPressed: toggleFavorite,
            size: 50,
          ),
          const SizedBox(width: 10),
          GlassRound(
            tooltip: 'Details',
            icon: const Icon(Icons.info_outline),
            onPressed: () => openItem(context, item),
            size: 50,
          ),
        ],
      );
    }
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        play,
        if (roundFavorite)
          GlassRound(
            tooltip: favorite ? 'Remove from favourites' : 'Add to favourites',
            icon: Icon(favorite ? Icons.favorite : Icons.favorite_border, color: favorite ? Colors.redAccent : null),
            onPressed: toggleFavorite,
            size: 52,
          )
        else
          GlassPill(
            icon: Icon(favorite ? Icons.favorite : Icons.favorite_border, size: 18, color: favorite ? Colors.redAccent : null),
            label: favorite ? 'Favourite' : 'Favorite',
            onPressed: toggleFavorite,
          ),
        GlassPill(label: 'Details', onPressed: () => openItem(context, item)),
      ],
    );
  }
}

class GlassPill extends StatelessWidget {
  const GlassPill({super.key, this.icon, required this.label, required this.onPressed});

  final Widget? icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          backgroundColor: const Color(0x590A0B12),
          foregroundColor: const Color(0xFFF2F2F6),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        icon: icon,
        label: Text(label),
        onPressed: onPressed,
      );
}

class GlassRound extends StatelessWidget {
  const GlassRound({super.key, required this.tooltip, required this.icon, required this.onPressed, this.size = 46});

  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: IconButton(
          tooltip: tooltip,
          style: IconButton.styleFrom(
            backgroundColor: const Color(0x800A0B12),
            foregroundColor: const Color(0xFFE8E9F0),
            disabledForegroundColor: const Color(0x4DE8E9F0),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
            padding: EdgeInsets.zero,
          ),
          iconSize: size * 0.4,
          icon: icon,
          onPressed: onPressed,
        ),
      );
}

/// Pause, mute, previous, next; a progress bar and "1 / 5".
class _Controls extends StatelessWidget {
  const _Controls({
    required this.index,
    required this.count,
    required this.progress,
    required this.trailer,
    required this.muted,
    required this.paused,
    required this.tv,
    required this.onGo,
    required this.onMute,
    required this.onPause,
  });

  final int index;
  final int count;
  final double progress;
  final bool trailer;
  final bool muted;
  final bool paused;
  final bool tv;
  final void Function(int step) onGo;
  final VoidCallback onMute;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    final size = tv ? 56.0 : 46.0;
    // Lite has no trailers to pause or mute.
    final video = effectsOf(context).playsTrailers;
    final cyan = context.tokens.accent2 ?? Theme.of(context).colorScheme.secondary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (video) ...[
              GlassRound(
                tooltip: paused ? 'Play' : 'Pause',
                icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                onPressed: onPause,
                size: size,
              ),
              const SizedBox(width: 8),
              GlassRound(
                tooltip: muted ? 'Unmute' : 'Mute',
                icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
                onPressed: trailer ? onMute : null,
                size: size,
              ),
            ],
            if (count > 1) ...[
              if (video) const SizedBox(width: 8),
              GlassRound(
                tooltip: 'Previous',
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: () => onGo(-1),
                size: size,
              ),
              const SizedBox(width: 8),
              GlassRound(
                tooltip: 'Next',
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: () => onGo(1),
                size: size,
              ),
            ],
          ],
        ),
        if (count > 1) ...[
          const SizedBox(height: 14),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 180,
                height: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0, 1),
                    color: cyan,
                    backgroundColor: Colors.white.withValues(alpha: 0.2),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${index + 1} / $count',
                style: const TextStyle(
                  color: Color(0xFFC4C7D4),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A phone, under the deck: one segment per show (the current one filling)
/// and pause (and mute, with a trailer).
class _PhoneControls extends StatelessWidget {
  const _PhoneControls({
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
          if (trailer)
            GlassRound(
              tooltip: muted ? 'Unmute' : 'Mute',
              icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
              onPressed: onMute,
              size: 36,
            ),
          if (trailer) const SizedBox(width: 6),
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
