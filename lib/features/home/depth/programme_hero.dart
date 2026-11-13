import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../app/layout.dart';
import '../../../core/jellyfin/items.dart';
import '../../../theme/app_tokens.dart';
import '../../library/library_providers.dart';
import '../../library/widgets/item_image.dart';
import '../../settings/appearance.dart';
import 'deck_hero.dart';

/// Depth's header on a PC ("programme"): the featured shows as a numbered
/// list on the left, the current one opened up with its details, and one
/// trailer frame on the right that crossfades between shows (nothing moves
/// in 3D: the deck stuttered on large screens). A large outlined number
/// overlaps the frame's corner.
///
/// The header's state (which show, the trailer, the timer) is HomeHeader's;
/// this only draws it.
class ProgrammeView extends StatelessWidget {
  const ProgrammeView({
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
    required this.onPick,
    required this.onMute,
    required this.onPause,
    required this.onHover,
  });

  /// At most five.
  final List<BaseItem> items;
  final int index;

  /// Through the current show, 0..1.
  final double progress;
  final VideoController? video;
  final bool trailerShowing;
  final bool trailer;
  final bool muted;
  final bool paused;
  final String chip;
  final void Function(int index) onPick;
  final VoidCallback onMute;
  final VoidCallback onPause;
  final void Function(bool hovered) onHover;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final stacked = size.width < 1100;
    // The same side margins as Home's rows, so the list lines up with them.
    final side = context.layout.gutter;
    final gap = (size.width * 0.03).clamp(24.0, 48.0);
    final top = statusBarHeight(context) + 120;
    // The frame in the trailer's own shape (16:9), as wide as its column
    // allows, but low enough for the first row to peek below it.
    final content = size.width - 2 * side;
    final column = stacked ? content : (content - gap) * 7 / 12;
    final frameWidth = math.max(320.0, math.min(column, (size.height - top - 150) * 16 / 9));
    final frameHeight = frameWidth * 9 / 16;
    final list = _Programme(items: items, index: index, progress: progress, onPick: onPick);
    final stage = _Stage(
      items: items,
      index: index,
      video: video,
      trailerShowing: trailerShowing,
      trailer: trailer,
      muted: muted,
      paused: paused,
      chip: chip,
      onMute: onMute,
      onPause: onPause,
      // The design's 240 on its 600-tall frame, in step with this one.
      numberSize: (frameHeight * 0.4).clamp(110.0, 240.0),
    );
    // Only over the list and the video does the pointer hold the show here:
    // resting it in the space around them mustn't stop the clock.
    Widget holding(Widget child) => MouseRegion(
          onEnter: (_) => onHover(true),
          onExit: (_) => onHover(false),
          child: child,
        );
    return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(side, top, side, 30),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    holding(list),
                    SizedBox(height: gap),
                    Center(
                      child: holding(SizedBox(width: frameWidth, height: frameHeight, child: stage)),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: holding(list)),
                    SizedBox(width: gap),
                    holding(SizedBox(width: frameWidth, height: frameHeight, child: stage)),
                  ],
                ),
        ),
    );
  }
}

/// "FEATURED TONIGHT", then the numbered list; the current show opened up.
class _Programme extends StatelessWidget {
  const _Programme({required this.items, required this.index, required this.progress, required this.onPick});

  final List<BaseItem> items;
  final int index;
  final double progress;
  final void Function(int index) onPick;

  @override
  Widget build(BuildContext context) {
    final muted = context.tokens.textMuted ?? const Color(0xFF9AA0B2);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            children: [
              Text(
                'FEATURED TONIGHT',
                style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 2.6),
              ),
              const SizedBox(width: 12),
              Expanded(child: Container(height: 1, color: Colors.white.withValues(alpha: 0.1))),
              const SizedBox(width: 12),
              Text(
                '${_two(index + 1)} / ${_two(items.length)}',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: const Color(0xFFC4C7D4),
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        for (final (i, item) in items.indexed)
          _Entry(item: item, number: i + 1, active: i == index, progress: progress, onPick: () => onPick(i)),
      ],
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

/// [base]'s font, drawn as an outline in [color] (a style can't have both a
/// colour and an outline paint, so it starts afresh).
TextStyle _outlined(
  TextStyle? base, {
  required double size,
  required double width,
  required Color color,
  double letterSpacing = 0,
  double height = 1.2,
}) => TextStyle(
  fontFamily: base?.fontFamily,
  fontFamilyFallback: base?.fontFamilyFallback,
  fontSize: size,
  fontWeight: FontWeight.w800,
  height: height,
  letterSpacing: letterSpacing,
  foreground: Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..color = color,
);

/// One show in the list: its outlined number and title; the current one
/// with a cyan number, a larger title, the time to the next as a line along
/// its top, and its details.
class _Entry extends StatefulWidget {
  const _Entry({
    required this.item,
    required this.number,
    required this.active,
    required this.progress,
    required this.onPick,
  });

  final BaseItem item;
  final int number;
  final bool active;
  final double progress;
  final VoidCallback onPick;

  @override
  State<_Entry> createState() => _EntryState();
}

class _EntryState extends State<_Entry> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyan = context.tokens.accent2 ?? theme.colorScheme.secondary;
    final active = widget.active;
    final color = active ? Colors.white : (_hover ? const Color(0xFFD4D6E0) : const Color(0xFF7D8396));
    final display = theme.textTheme.headlineSmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            Container(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            if (active)
              // The time to the next show, filling along the top edge.
              Transform(
                alignment: Alignment.centerLeft,
                transform: Matrix4.diagonal3Values(widget.progress.clamp(0.0, 1.0), 1, 1),
                child: Container(height: 2, color: cyan),
              ),
          ],
        ),
        InkWell(
          onTap: widget.onPick,
          onHover: (h) => setState(() => _hover = h),
          onFocusChange: (f) => setState(() => _hover = f),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 52,
                  child: Text(
                    _two(widget.number),
                    // Outlined; filled cyan when current.
                    style: active
                        ? display?.copyWith(fontSize: 22, fontWeight: FontWeight.w800, height: 1.2, color: cyan)
                        : _outlined(display, size: 22, width: 1, color: color),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    widget.item.name,
                    maxLines: active ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: display?.copyWith(
                      fontSize: active ? 34 : 22,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      height: 1.2,
                      letterSpacing: -0.2,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (active)
          Padding(
            padding: const EdgeInsets.fromLTRB(66, 0, 0, 22),
            child: _Details(key: ValueKey('pd-${widget.item.id}'), item: widget.item),
          ),
      ],
    );
  }
}

/// ★ score · year · seasons · age, three lines of overview, and the buttons,
/// rising in one after another.
class _Details extends ConsumerWidget {
  const _Details({super.key, required this.item});

  final BaseItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final series = item.type == ItemType.series;
    final next = series ? ref.watch(nextUpForSeriesProvider(item.id)).value : null;
    final meta = theme.textTheme.labelLarge?.copyWith(color: const Color(0xFFE8E9F0), fontWeight: FontWeight.w700);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RiseIn(
          delay: 0,
          child: Wrap(
            spacing: 14,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (item.communityRating case final r?)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_rounded, size: 16, color: context.tokens.star),
                    const SizedBox(width: 4),
                    Text(r.toStringAsFixed(1), style: meta),
                  ],
                ),
              if (item.productionYear case final y?) Text('$y', style: meta),
              if (series && (item.childCount ?? 0) > 0)
                Text('${item.childCount} season${item.childCount == 1 ? '' : 's'}', style: meta),
              if (item.type == ItemType.movie && item.runTimeTicks != null)
                Text('${item.runTimeTicks! ~/ 600000000} min', style: meta),
              if (item.officialRating case final age?)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    child: Text(age, style: meta?.copyWith(fontSize: 12)),
                  ),
                ),
            ],
          ),
        ),
        if (item.overview case final overview? when overview.isNotEmpty) ...[
          const SizedBox(height: 12),
          RiseIn(
            delay: 150,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(
                overview,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFFB9BDCC), fontSize: 15, height: 1.6),
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        RiseIn(
          delay: 300,
          child: HeroButtons(item: item, next: next, phone: false, roundFavorite: true),
        ),
      ],
    );
  }
}

/// The trailer frame: the current show's backdrop (and trailer), crossfading
/// from the last one; pause, mute and the "Now playing" chip at the top
/// left, the genres down the right edge; the big outlined number over the
/// bottom-left corner.
class _Stage extends StatefulWidget {
  const _Stage({
    required this.items,
    required this.index,
    required this.video,
    required this.trailerShowing,
    required this.trailer,
    required this.muted,
    required this.paused,
    required this.chip,
    required this.onMute,
    required this.onPause,
    required this.numberSize,
  });

  final List<BaseItem> items;
  final int index;
  final VideoController? video;
  final bool trailerShowing;
  final bool trailer;
  final bool muted;
  final bool paused;
  final String chip;
  final VoidCallback onMute;
  final VoidCallback onPause;

  /// The big number's size.
  final double numberSize;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100), value: 1);
  BaseItem? _previous;

  @override
  void didUpdateWidget(_Stage old) {
    super.didUpdateWidget(old);
    final was = old.items.isEmpty ? null : old.items[old.index % old.items.length];
    final now = widget.items[widget.index % widget.items.length];
    if (was != null && was.id != now.id) {
      // Only two scenes: the one coming in over the one going.
      _previous = was;
      _fade.forward(from: animationsOn(context) ? 0 : 1).whenComplete(() {
        if (mounted) setState(() => _previous = null);
      });
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[widget.index % widget.items.length];
    final violet = Theme.of(context).colorScheme.primary;
    final number = _two(widget.index % widget.items.length + 1);
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        // The soft violet shadow: its own static layer.
        RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: violet.withValues(alpha: 0.55),
                  blurRadius: 90,
                  spreadRadius: -40,
                  offset: const Offset(0, 40),
                ),
              ],
            ),
          ),
        ),
        RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                if (_previous case final previous?) RepaintBoundary(child: _Scene(item: previous)),
                FadeTransition(
                  opacity: _fade,
                  child: RepaintBoundary(
                    child: _Scene(
                      key: ValueKey('scene-${item.id}'),
                      item: item,
                      video: widget.video,
                      trailerShowing: widget.trailerShowing,
                    ),
                  ),
                ),
                const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(-0.34, -0.94),
                        end: Alignment(0.34, 0.94),
                        stops: [0.4, 1],
                        colors: [Color(0x0006070B), Color(0x8C06070B)],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  top: 20,
                  child: Row(
                    children: [
                      // Lite has no trailers to pause or mute.
                      if (effectsOf(context).playsTrailers) ...[
                        GlassRound(
                          tooltip: widget.paused ? 'Play' : 'Pause',
                          icon: Icon(widget.paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                          onPressed: widget.onPause,
                        ),
                        const SizedBox(width: 8),
                        GlassRound(
                          tooltip: widget.muted ? 'Unmute' : 'Mute',
                          icon: Icon(widget.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
                          onPressed: widget.trailer ? widget.onMute : null,
                        ),
                        const SizedBox(width: 8),
                      ],
                      NowPlayingChip(trailerLabel: widget.chip),
                    ],
                  ),
                ),
                if (item.genres.isNotEmpty)
                  Positioned(
                    right: 20,
                    top: 24,
                    bottom: 24,
                    child: Center(
                      child: RotatedBox(
                        quarterTurns: 1,
                        child: Text(
                          item.genres.take(3).join(' · ').toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 3.8,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // The number, rising in over the corner with each show.
        Positioned(
          left: -6,
          bottom: -widget.numberSize * 0.19,
          child: IgnorePointer(
            child: RiseIn(
              key: ValueKey('num-$number'),
              delay: 0,
              child: Text(
                number,
                style: _outlined(
                  Theme.of(context).textTheme.displayLarge,
                  size: widget.numberSize,
                  width: 2,
                  color: const Color(0xD9F2F0FF),
                  letterSpacing: widget.numberSize * -0.06,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One show in the frame: its backdrop (slightly enlarged), and its trailer
/// once frames come.
class _Scene extends StatelessWidget {
  const _Scene({super.key, required this.item, this.video, this.trailerShowing = false});

  final BaseItem item;
  final VideoController? video;
  final bool trailerShowing;

  @override
  Widget build(BuildContext context) {
    final width = math.min(1600 / MediaQuery.devicePixelRatioOf(context), MediaQuery.sizeOf(context).width * 0.6);
    return Transform.scale(
      scale: 1.04,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ItemImage(image: item.backdropImage ?? item.landscapeImage ?? item.posterImage, maxWidth: width),
          if (video != null)
            AnimatedOpacity(
              opacity: trailerShowing ? 1 : 0,
              duration: const Duration(milliseconds: 600),
              child: IgnorePointer(
                child: Video(controller: video!, fit: BoxFit.cover, controls: NoVideoControls),
              ),
            ),
        ],
      ),
    );
  }
}
