import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/backdrop.dart';
import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../../core/jellyfin/items.dart';
import '../../../theme/app_tokens.dart';
import '../../anime/widgets/mal_widgets.dart';
import '../../library/navigation.dart';
import '../../library/widgets/item_image.dart';
import '../home_components.dart';
import 'deck_hero.dart';
import 'preview.dart';

/// Depth's Continue watching ("stage"): a list of what's in progress on the
/// left, each row softly filled to how far it was watched (no bar, no
/// number), and a large stage for the one picked: its picture shaded to the
/// stopping point (a faint tint before it, darker after, a soft cyan glow
/// at it), its title, episode, time left, Resume and Start over. The
/// episode itself fades in, muted, from just before that point: after a
/// moment's hover on a PC, by itself on a phone.
class ResumeStage extends StatefulWidget {
  const ResumeStage({super.key, required this.data});

  final LibraryRowData data;

  @override
  State<ResumeStage> createState() => _ResumeStageState();
}

class _ResumeStageState extends State<ResumeStage> {
  int _selected = 0;
  bool _hover = false;

  void _pick(int i, BaseItem item) {
    setState(() => _selected = i);
    BackdropArt.show(item, ProviderScope.containerOf(context, listen: false));
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.data.items.value;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
    final layout = context.layout;
    final width = MediaQuery.sizeOf(context).width - 2 * layout.gutter;
    final phone = layout.formFactor == FormFactor.phone;
    final tv = layout.formFactor == FormFactor.tv;
    final side = width >= 900 && !phone;
    final shown = items.take(phone ? 5 : 6).toList();
    final selected = math.min(_selected, shown.length - 1);
    final item = shown[selected];
    final playsBySelf = previewsPlayBySelf(context);

    final stage = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: _Stage(
        key: ValueKey('stage-${item.id}'),
        item: item,
        compact: phone,
        preview: playsBySelf || _hover,
        onResume: () => openItem(context, item, play: true),
        onStartOver: () => context.push('/play/${item.id}?fromStart=1'),
        // The episode's own page (a film's), not the show's.
        onTitle: () => item.type == ItemType.episode ? openEpisode(context, item) : openItem(context, item),
      ),
    );
    final list = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, it) in shown.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            // Beside the stage the picked one steps out a little; full width
            // (a phone) it would step off the edge.
            child: _Pick(item: it, selected: i == selected, steps: side, onTap: () => _pick(i, it)),
          ),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(layout.gutter, 32, layout.gutter, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KickerHeading(
            kicker: 'Pick up where you left off',
            title: Text(widget.data.title, style: CardLook.headingStyle(context)),
          ),
          const SizedBox(height: 24),
          if (side)
            // As tall as the list (each row 72 + 8), at least the design's.
            SizedBox(
              height: math.max(tv ? 470.0 : 400.0, shown.length * 80.0 - 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: tv ? 520 : 320, child: list),
                  const SizedBox(width: 28),
                  Expanded(child: stage),
                ],
              ),
            )
          else ...[
            SizedBox(height: phone ? 230 : 340, child: stage),
            const SizedBox(height: 12),
            list,
          ],
        ],
      ),
    );
  }
}

/// One row of the list: thumbnail, title, time left; its background filled
/// from the left to how far it was watched, fading out at the edge.
class _Pick extends StatefulWidget {
  const _Pick({required this.item, required this.selected, required this.steps, required this.onTap});

  final BaseItem item;
  final bool selected;
  final bool steps;
  final VoidCallback onTap;

  @override
  State<_Pick> createState() => _PickState();
}

class _PickState extends State<_Pick> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final violet = Theme.of(context).colorScheme.primary;
    final cyan = tokens.accent2 ?? Theme.of(context).colorScheme.secondary;
    final item = widget.item;
    final watched = (item.userData.playedPercentage ?? 0) / 100;
    final selected = widget.selected;
    final text = selected ? Colors.white : (_hover ? const Color(0xFFE8E9F0) : const Color(0xFFA8ADBD));
    return Semantics(
      button: true,
      selected: selected,
      label: '${_title(item)}, ${(watched * 100).round()}% watched, ${_left(item) ?? ''}',
      child: AnimatedSlide(
        offset: Offset(selected && widget.steps ? 10 / 320 : 0, 0),
        duration: const Duration(milliseconds: 500),
        curve: const Cubic(0.2, 0.8, 0.2, 1.2),
        child: Material(
          color: const Color(0xFF0B0D14),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: selected
                  ? violet.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: _hover ? 0.16 : 0.06),
            ),
          ),
          child: InkWell(
            onTap: widget.onTap,
            onHover: (h) => setState(() => _hover = h),
            onFocusChange: (f) {
              // A remote: focusing a row picks it.
              if (f) widget.onTap();
            },
            child: Stack(
              children: [
                // How far it was watched: a faint tint, its edge fading out.
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: watched.clamp(0.0, 1.0),
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final fade = box.maxWidth <= 40 ? 0.0 : 1 - 40 / box.maxWidth;
                        final a = selected ? 1.6 : 1.0;
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              stops: [0, fade * 0.7, fade, 1],
                              colors: [
                                violet.withValues(alpha: 0.03 * a),
                                violet.withValues(alpha: 0.09 * a),
                                cyan.withValues(alpha: 0.12 * a),
                                cyan.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 76,
                          height: 48,
                          child: ItemImage(image: item.landscapeImage ?? item.posterImage, maxWidth: 76),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _title(item),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: text, fontSize: 15, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _left(item) ?? item.episodeLabel ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: tokens.textMuted ?? const Color(0xFF9AA0B2),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The picked show, large: its picture shaded to where it stopped, the
/// episode fading in over it, and its details and buttons.
class _Stage extends StatelessWidget {
  const _Stage({
    super.key,
    required this.item,
    required this.compact,
    required this.preview,
    required this.onResume,
    required this.onStartOver,
    required this.onTitle,
  });

  final BaseItem item;

  /// A phone: a shorter card, smaller text.
  final bool compact;

  /// The episode plays (muted) over the picture.
  final bool preview;
  final VoidCallback onResume;
  final VoidCallback onStartOver;
  final VoidCallback onTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final violet = theme.colorScheme.primary;
    final cyan = tokens.accent2 ?? theme.colorScheme.secondary;
    final page = tokens.background;
    final watched = ((item.userData.playedPercentage ?? 0) / 100).clamp(0.0, 1.0);
    final radius = BorderRadius.circular(compact ? 22 : 30);
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
      child: ClipRRect(
        borderRadius: radius,
        child: LayoutBuilder(
          builder: (context, box) {
            final at = box.maxWidth * watched;
            return Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                RepaintBoundary(
                  child: ItemImage(
                    image: item.backdropImage ?? item.landscapeImage ?? item.posterImage,
                    maxWidth: math.min(box.maxWidth, 1600 / MediaQuery.devicePixelRatioOf(context)),
                  ),
                ),
                EpisodePreview(item: item, active: preview),
                // Watched: a faint tint, fading out over its last 160px.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: at,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          stops: [0, at <= 160 ? 0 : (1 - 160 / at) * 0.6, at <= 160 ? 0 : 1 - 160 / at, 1],
                          colors: [
                            violet.withValues(alpha: 0),
                            violet.withValues(alpha: 0.06),
                            cyan.withValues(alpha: 0.1),
                            cyan.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // Not yet watched: darker, gradually.
                Positioned(
                  left: at,
                  top: 0,
                  bottom: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          stops: [0, box.maxWidth - at <= 200 ? 1 : 200 / (box.maxWidth - at), 1],
                          colors: [
                            page.withValues(alpha: 0),
                            page.withValues(alpha: 0.38),
                            page.withValues(alpha: 0.42),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // A soft cyan glow at the stopping point, low down.
                Positioned(
                  left: at - 160,
                  width: 180,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0.76, 1),
                          radius: 0.7,
                          colors: [cyan.withValues(alpha: 0.14), cyan.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
                ),
                // Readable text on the left.
                const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        stops: [0, 0.55, 1],
                        colors: [Color(0xB306070B), Color(0x2606070B), Color(0x0006070B)],
                      ),
                    ),
                  ),
                ),
                // The picture opens the episode's page too (over the picture
                // and shading, under the text and buttons).
                Positioned.fill(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTitle),
                  ),
                ),
                // Only over a preview that's really playing: not over a
                // still (previews off, or none of it loaded yet).
                if (!previewsPlayBySelf(context))
                  ValueListenableBuilder<String?>(
                    valueListenable: Preview.showing,
                    builder: (context, showing, _) => showing != item.id
                        ? const SizedBox.shrink()
                        : const Positioned(
                            right: 24,
                            top: 24,
                            child: RiseIn(delay: 0, child: NowPlayingChip(trailerLabel: 'Preview')),
                          ),
                  ),
                Positioned(
                  left: compact ? 18 : 40,
                  right: compact ? 18 : 40,
                  top: compact ? 14 : 24,
                  bottom: compact ? 16 : 40,
                  // Shrunk to fit rather than cut off at the top (large
                  // system text on a phone).
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.bottomLeft,
                    child: SizedBox(
                      width: math.max(0, box.maxWidth - (compact ? 36 : 80)),
                      child: _StageText(
                        item: item,
                        compact: compact,
                        onResume: onResume,
                        onStartOver: onStartOver,
                        onTitle: onTitle,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StageText extends StatelessWidget {
  const _StageText({
    required this.item,
    required this.compact,
    required this.onResume,
    required this.onStartOver,
    required this.onTitle,
  });

  final BaseItem item;
  final bool compact;
  final VoidCallback onResume;
  final VoidCallback onStartOver;
  final VoidCallback onTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyan = context.tokens.accent2 ?? theme.colorScheme.secondary;
    final subtitle = item.type == ItemType.episode
        ? [?item.episodeLabel, item.name].join(' · ')
        : [?item.productionYear?.toString()].join();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The score, as the cards show it (MyAnimeList's, when there is one).
          if (!compact) SizedBox(height: 30, width: 120, child: Stack(children: [MalScoreBadge(item: item)])),
          RiseIn(
            delay: 0,
            child: GestureDetector(
              onTap: onTitle,
              child: Text(
                _title(item),
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.displaySmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: compact ? 20 : 46,
                  height: 1,
                ),
              ),
            ),
          ),
          if (subtitle.isNotEmpty) ...[
            SizedBox(height: compact ? 6 : 12),
            RiseIn(
              delay: 150,
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color(0xFFD4D6E0),
                  fontSize: compact ? 13 : 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (_left(item) case final left?) ...[
            const SizedBox(height: 6),
            RiseIn(
              delay: 150,
              child: Text(left, style: TextStyle(color: cyan, fontSize: compact ? 12 : 14, fontWeight: FontWeight.w700)),
            ),
          ],
          SizedBox(height: compact ? 12 : 22),
          RiseIn(
            delay: 300,
            // A phone: one line, Start over as a round button.
            child: Wrap(
              spacing: compact ? 10 : 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF2F0FF),
                    foregroundColor: const Color(0xFF0B0C12),
                    minimumSize: Size(0, compact ? 42 : 52),
                    padding: compact ? const EdgeInsets.fromLTRB(16, 0, 20, 0) : const EdgeInsets.fromLTRB(22, 0, 28, 0),
                    textStyle: TextStyle(fontSize: compact ? 14 : 15, fontWeight: FontWeight.w800),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 22),
                  label: const Text('Resume'),
                  onPressed: onResume,
                ),
                if (compact)
                  GlassRound(
                    tooltip: 'Start over',
                    icon: const Icon(Icons.replay_rounded, size: 20),
                    onPressed: onStartOver,
                    size: 42,
                  )
                else
                  GlassPill(icon: const Icon(Icons.replay_rounded, size: 18), label: 'Start over', onPressed: onStartOver),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The show's name for an episode, else the item's.
String _title(BaseItem item) => item.type == ItemType.episode ? item.seriesName ?? item.name : item.name;

/// "21m left" (or "1h 4m left"); null when it can't be told.
String? _left(BaseItem item) {
  final total = item.runTimeTicks;
  if (total == null || total <= 0) return null;
  final minutes = ((total - item.userData.playbackPositionTicks) / 600000000).ceil();
  if (minutes <= 0) return null;
  return minutes >= 60 ? '${minutes ~/ 60}h ${minutes % 60}m left' : '${minutes}m left';
}
