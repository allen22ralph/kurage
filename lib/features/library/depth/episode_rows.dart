import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../../core/jellyfin/items.dart';
import '../../../theme/app_tokens.dart';
import '../../anime/widgets/mal_widgets.dart';
import '../../downloads/downloads_screen.dart';
import '../../settings/appearance.dart';
import '../item_detail_screen.dart';
import '../widgets/item_image.dart';
import '../widgets/selection.dart';
import '../widgets/episode_swipe.dart';
import '../widgets/side_scroll.dart';
import 'detail_parts.dart';

const _ease = Cubic(0.2, 0.8, 0.2, 1.15);
const _violet = Color(0xFF8F84FF);

/// A season's tabs, a light pill sliding between them. What doesn't fit
/// scrolls sideways; a phone's few share the width.
class SeasonTabs extends StatelessWidget {
  const SeasonTabs({super.key, required this.seasons, required this.selected, required this.onPick, this.trailing});

  final List<BaseItem> seasons;
  final BaseItem selected;
  final ValueChanged<BaseItem> onPick;
  final Widget? trailing;

  static const _slot = 120.0;

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final at = math.max(0, seasons.indexWhere((s) => s.id == selected.id));
    return LayoutBuilder(
      builder: (context, box) {
        const padding = 5.0;
        // (And the border's width each side.)
        final room = box.maxWidth - 2 * padding - 2;
        final shares = phone && seasons.length <= 4;
        final slot = shares ? room / seasons.length : _slot;
        final tabs = Container(
          padding: const EdgeInsets.all(padding),
          decoration: BoxDecoration(
            color: const Color(0xC70A0B12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: SizedBox(
            width: slot * seasons.length,
            height: phone ? 38 : 42,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: Duration(milliseconds: animationsOn(context) ? 550 : 0),
                  curve: _ease,
                  left: slot * at,
                  top: 0,
                  bottom: 0,
                  width: slot,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(color: Color(0xFFF2F0FF), borderRadius: BorderRadius.all(Radius.circular(999))),
                  ),
                ),
                Row(
                  children: [
                    for (final season in seasons)
                      SizedBox(
                        width: slot,
                        child: _Tab(
                          season: season,
                          on: season.id == selected.id,
                          onTap: () => onPick(season),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: [tabs, if (trailing != null) ...[const SizedBox(width: 8), trailing!]],
        );
        return SideScroll(
          builder: (controller) => SingleChildScrollView(
            controller: controller,
            scrollDirection: Axis.horizontal,
            child: row,
          ),
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.season, required this.on, required this.onTap});

  final BaseItem season;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: on,
        button: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onTap,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 350),
                  style: TextStyle(color: on ? const Color(0xFF0B0C12) : const Color(0xFFA8ADBD), fontSize: 14, fontWeight: FontWeight.w800),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (season.userData.played) ...[
                        Icon(
                          Icons.check_circle,
                          size: 14,
                          semanticLabel: 'Watched',
                          color: on ? const Color(0xFF0B0C12) : (context.tokens.accent2 ?? const Color(0xFF8EE6F5)),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Flexible(child: Text(season.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// A round button on an episode's row.
class RowIconButton extends StatelessWidget {
  const RowIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.on = false,
    this.small = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool on;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final cyan = context.tokens.accent2 ?? const Color(0xFF8EE6F5);
    final size = small ? 32.0 : 44.0;
    return SizedBox.square(
      dimension: size,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: on ? cyan.withValues(alpha: 0.16) : const Color(0x990A0B12),
          foregroundColor: on ? cyan : const Color(0xFFC4C7D4),
          side: BorderSide(color: on ? cyan.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.14)),
        ),
        icon: Icon(icon, size: small ? 16 : 18),
      ),
    );
  }
}

/// An episode's thumbnail: its still, how far it's been watched, and the
/// badge on the one to carry on with.
class EpisodeThumb extends StatelessWidget {
  const EpisodeThumb({super.key, required this.episode, required this.width, this.badge, this.dim = false, this.child});

  final BaseItem episode;
  final double width;
  final String? badge;
  final bool dim;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final cyan = context.tokens.accent2 ?? const Color(0xFF8EE6F5);
    final data = episode.userData;
    final seen = data.played ? 1.0 : watchedFraction(episode);
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF111111)),
        RepaintBoundary(child: ItemImage(image: episode.landscapeImage ?? episode.posterImage, maxWidth: width)),
        if (dim) const ColoredBox(color: Color(0x59000000)),
        if (seen > 0 && !data.played)
          Transform(
            alignment: Alignment.centerLeft,
            transform: Matrix4.diagonal3Values(seen, 1, 1),
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  stops: [0, 0.7, 1],
                  colors: [Color(0x008F84FF), Color(0x298F84FF), Color(0x008EE6F5)],
                ),
              ),
            ),
          ),
        if (seen > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 4,
            child: ColoredBox(
              color: Colors.white.withValues(alpha: 0.18),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(widthFactor: seen, heightFactor: 1, child: ColoredBox(color: cyan)),
              ),
            ),
          ),
        if (badge != null)
          Positioned(
            left: 10,
            top: 10,
            child: DecoratedBox(
              decoration: BoxDecoration(color: const Color(0xFFF2F0FF), borderRadius: BorderRadius.circular(999)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                child: Text(
                  badge!.toUpperCase(),
                  style: const TextStyle(color: Color(0xFF0B0C12), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                ),
              ),
            ),
          ),
        ?child,
      ],
    );
  }
}

/// An episode on Depth's series page.
class DepthEpisodeRow extends StatefulWidget {
  const DepthEpisodeRow({
    super.key,
    required this.episode,
    required this.index,
    required this.current,
    required this.selected,
    required this.played,
    required this.onOpen,
    required this.onPlay,
    required this.onThumb,
    required this.onHold,
    required this.onMenu,
    required this.onWatched,
    required this.swipes,
    required this.watchedButton,
  });

  final BaseItem episode;
  final int index;

  /// Watched, as just marked (the episode itself follows from the server).
  final bool played;

  /// On a phone, tapping the picture.
  final VoidCallback onThumb;

  /// Marks it the other way, by swiping; null while that's being saved.
  final VoidCallback? onWatched;

  /// It can be swiped (not while selecting).
  final bool swipes;

  /// The one to carry on with.
  final bool current;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onPlay;
  final VoidCallback onHold;
  final void Function(Offset? at) onMenu;
  final Widget watchedButton;

  @override
  State<DepthEpisodeRow> createState() => _DepthEpisodeRowState();
}

class _DepthEpisodeRowState extends State<DepthEpisodeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final phone = context.layout.formFactor == FormFactor.phone;
    final current = widget.current || episode.userData.hasProgress;
    final moving = animationsOn(context);
    final tilt = _hover && moving && effectsOf(context) != EffectsLevel.lite;
    final cyan = context.tokens.accent2 ?? const Color(0xFF8EE6F5);
    final played = widget.played;
    final at = episode.userData.hasProgress ? formatPosition(ticksToDuration(episode.userData.playbackPositionTicks)) : null;
    final thumbWidth = phone ? 132.0 : 260.0;
    final thumb = SizedBox(
      width: thumbWidth,
      height: phone ? 76 : 146,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: tilt ? 1 : 0),
        duration: const Duration(milliseconds: 500),
        curve: _ease,
        builder: (context, t, child) => t == 0
            ? child!
            : Transform(
                alignment: Alignment.center,
                filterQuality: FilterQuality.medium,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 1 / 700)
                  ..rotateY(-8 * math.pi / 180 * t)
                  ..scaleByDouble(1 + 0.03 * t, 1 + 0.03 * t, 1, 1),
                child: child,
              ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(phone ? 12 : 16),
          child: EpisodeThumb(
            episode: episode,
            width: thumbWidth,
            dim: played,
            badge: at == null ? null : (phone ? 'Resume' : 'Resume · $at'),
            child: phone
                ? const Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Color(0x8C0A0B12), shape: BoxShape.circle),
                      child: Padding(
                        padding: EdgeInsets.all(5),
                        child: Icon(Icons.play_arrow_rounded, size: 22, color: Colors.white),
                      ),
                    ),
                  )
                : AnimatedOpacity(
                    opacity: _hover ? 1 : 0,
                    duration: const Duration(milliseconds: 300),
                    child: Center(
                      child: SizedBox.square(
                        dimension: 52,
                        child: IconButton(
                          tooltip: 'Play ${episode.name}',
                          padding: EdgeInsets.zero,
                          onPressed: widget.onPlay,
                          style: IconButton.styleFrom(backgroundColor: const Color(0xF2F2F0FF), foregroundColor: const Color(0xFF0B0C12)),
                          icon: const Icon(Icons.play_arrow_rounded, size: 26),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
    final number = episode.indexNumber;
    final display = CardLook.headingStyle(context) ?? const TextStyle();
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (number != null) ...[
              Text(
                '$number',
                style: display.copyWith(
                  fontSize: phone ? 18 : 30,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = phone ? 1 : 1.2
                    ..color = current ? cyan : Colors.white.withValues(alpha: 0.7),
                ),
              ),
              SizedBox(width: phone ? 8 : 14),
            ],
            Expanded(
              child: Consumer(
                builder: (context, ref, _) => Text(
                  preferredEpisodeTitle(ref, episode, episode.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: phone
                      ? const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)
                      : display.copyWith(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: phone ? 3 : 6),
        DefaultTextStyle.merge(
          style: TextStyle(color: const Color(0xFFC4C7D4), fontSize: phone ? 11 : 13, fontWeight: FontWeight.w700),
          child: Wrap(
            spacing: phone ? 10 : 14,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (episode.runtime case final r?) Text(formatRuntime(r)),
              MalEpisodeScore(episode: episode),
              if (played) Text('Watched', style: TextStyle(color: cyan)),
            ],
          ),
        ),
        if (episode.overview case final overview? when overview.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: phone ? 2 : 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Text(
                splitOverview(overview).body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: phone ? const Color(0xFF9AA0B2) : const Color(0xFFB9BDCC), fontSize: phone ? 12 : 14, height: phone ? 1.45 : 1.6),
              ),
            ),
          ),
      ],
    );
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!phone) ...[
          IconTheme.merge(
            data: const IconThemeData(color: Color(0xFFC4C7D4), size: 20),
            child: EpisodeDownloadButton(episode: episode),
          ),
          const SizedBox(width: 8),
        ],
        widget.watchedButton,
      ],
    );
    final body = AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      padding: EdgeInsets.all(phone ? 6 : 14),
      decoration: selectedRowDecoration(context, selected: widget.selected) ??
          BoxDecoration(
            borderRadius: BorderRadius.circular(phone ? 16 : 22),
            color: current
                ? _violet.withValues(alpha: 0.07)
                : (_hover ? const Color(0xD90E1018) : Colors.transparent),
            border: Border.all(
              color: current ? _violet.withValues(alpha: 0.3) : (_hover ? Colors.white.withValues(alpha: 0.08) : Colors.transparent),
            ),
          ),
      child: Row(
        crossAxisAlignment: phone ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          // A phone has no hover to show a play button: the picture plays,
          // and the rest of the row opens the episode.
          if (phone)
            Semantics(
              button: true,
              label: 'Play ${episode.name}',
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onThumb, child: thumb),
            )
          else
            thumb,
          SizedBox(width: phone ? 10 : 24),
          Expanded(child: texts),
          SizedBox(width: phone ? 4 : 24),
          buttons,
        ],
      ),
    );
    final tappable = CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.contextMenu): () => widget.onMenu(null)},
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            hoverColor: Colors.transparent,
            onTap: widget.onOpen,
            onLongPress: widget.onHold,
            onSecondaryTapUp: (d) => widget.onMenu(d.globalPosition),
            child: AnimatedSlide(
              offset: Offset(moving && _hover && !phone ? 0.006 : 0, 0),
              duration: const Duration(milliseconds: 450),
              curve: _ease,
              child: body,
            ),
          ),
        ),
      ),
    );
    final row = EpisodeSwipe(episode: episode, played: played, onWatched: widget.onWatched, enabled: widget.swipes, child: tappable);
    // Rising in, one after another, when the season changes (the first few:
    // the rest are off screen).
    return Padding(
      padding: EdgeInsets.only(bottom: phone ? 4 : 6),
      child: !moving || effectsOf(context) == EffectsLevel.lite
          ? row
          : TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: 600 + 40 * math.min(widget.index, 7)),
              child: row,
              builder: (context, v, child) {
                final lead = (40 * math.min(widget.index, 7)) / (600 + 40 * math.min(widget.index, 7));
                final t = const Cubic(0.2, 0.8, 0.2, 1).transform(((v - lead) / (1 - lead)).clamp(0.0, 1.0));
                if (t == 1) return child!;
                return Opacity(
                  opacity: t,
                  child: Transform.translate(offset: Offset(0, 18 * (1 - t)), child: child),
                );
              },
            ),
    );
  }
}
