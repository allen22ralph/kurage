import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/jellyfin/items.dart';
import '../../anime/widgets/mal_widgets.dart';
import 'action_menu.dart';
import 'card_actions.dart';
import 'item_image.dart';
import '../../settings/appearance.dart';
import '../../../app/backdrop.dart';
import '../../../app/card_look.dart';
import '../../../theme/app_tokens.dart';
import 'side_scroll.dart';

enum CardShape {
  poster(2 / 3),
  landscape(16 / 9),
  square(1);

  const CardShape(this.aspectRatio);

  final double aspectRatio;
}

/// A focusable item card: artwork, progress/watched badges, and a caption.
///
/// Grows and gets an outline when focused, and scrolls itself into view,
/// so it works with arrow keys and a TV remote as well as mouse and touch.
class MediaCard extends StatefulWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.width,
    required this.onPressed,
    this.shape = CardShape.poster,
    this.title,
    this.subtitle,
    this.onTitlePressed,
    this.onSubtitlePressed,
    this.autofocus = false,
    this.actions = true,
    this.row,
  });

  final BaseItem item;
  final double width;
  final CardShape shape;
  final VoidCallback onPressed;

  /// Defaults to the item name (or series name for episodes).
  final String? title;
  final String? subtitle;

  /// When set, the caption's lines are separate links (e.g. the show and
  /// the episode) instead of repeating [onPressed].
  final VoidCallback? onTitlePressed;
  final VoidCallback? onSubtitlePressed;

  final bool autofocus;

  /// Quick actions: hover buttons (desktop), long press / menu key menu.
  final bool actions;

  /// The home row the card is in (Continue watching / Next up), for its
  /// "remove from this row" action.
  final CardRow? row;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _focused = false;
  bool _hover = false;

  void _onFocusChange(bool focused) {
    setState(() => _focused = focused);
    if (focused) {
      BackdropArt.show(widget.item, ProviderScope.containerOf(context, listen: false));
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 150),
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    }
  }

  /// The card's menu, from the card itself (its hover buttons go away when
  /// the menu opens over them); [at]: a right-click, a popup there.
  void _showMenu({Offset? at}) => showCardMenu(context, widget.item, row: widget.row, at: at);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;
    final image = widget.shape == CardShape.landscape ? item.landscapeImage ?? item.posterImage : item.posterImage;
    final (title, subtitle) = _caption(item);
    // Paged rows (Settings > Appearance > Rows, on Home): cards lift under
    // the mouse instead of growing; Continue watching glows and shows play
    // and the time left, the others tilt with a shine.
    final paged = RowScope.of(context) != null &&
        ProviderScope.containerOf(context, listen: false).read(appearanceProvider).value?.rowStyle == RowStyle.paged;
    final moving = animationsOn(context);
    final resume = widget.row == CardRow.continueWatching;
    final lifted = paged && _hover && moving;
    // A theme's poster tiles (Depth): lift and tilt with a shine, under the
    // mouse or focus, instead of growing.
    final tiles = CardLook.of(context)?.tiles ?? false;
    final tilted = tiles && (_hover || _focused) && moving;
    final radius = tiles ? context.tokens.radius.card : 8.0;

    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedScale(
            // Focused (remote, keyboard), or under the mouse with animations on.
            scale: tiles ? 1 : (_focused ? 1.06 : (_hover && moving && !paged ? 1.04 : 1)),
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            child: TiltMotion(
              tilted: tilted,
              child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              transformAlignment: Alignment.center,
              // Tiles tilt with TiltMotion (around this).
              transform: tiles
                  ? Matrix4.identity()
                  : lifted
                  ? (Matrix4.translationValues(0, resume ? -6 : -8, 0)..rotateZ(resume ? 0 : -0.017))
                  : Matrix4.identity(),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: tiles
                    ? Border.all(
                        color: _focused
                            ? const Color(0xFFF2F0FF)
                            : Colors.white.withValues(alpha: _hover ? 0.25 : 0.08),
                        width: _focused ? 3 : 1,
                      )
                    : null,
                boxShadow: [
                  if ((lifted && resume) || (tiles && (_hover || _focused)))
                    tiles
                        ? BoxShadow(
                            color: theme.colorScheme.primary.withValues(alpha: 0.6),
                            blurRadius: 50,
                            spreadRadius: -24,
                            offset: const Offset(0, 30),
                          )
                        : BoxShadow(
                            color: theme.colorScheme.primary.withValues(alpha: 0.45),
                            blurRadius: 24,
                            spreadRadius: 1,
                          ),
                ],
              ),
              child: AspectRatio(
              aspectRatio: widget.shape.aspectRatio,
              child: Material(
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(tiles ? radius - 1 : radius),
                  side: _focused && !tiles ? BorderSide(color: theme.colorScheme.primary, width: 3) : BorderSide.none,
                ),
                child: CallbackShortcuts(
                  // TV remotes' menu key / a keyboard's menu key.
                  bindings: {if (widget.actions) const SingleActivator(LogicalKeyboardKey.contextMenu): _showMenu},
                  child: MouseRegion(
                    onEnter: (_) {
                      setState(() => _hover = true);
                      BackdropArt.show(widget.item, ProviderScope.containerOf(context, listen: false));
                    },
                    onExit: (_) => setState(() => _hover = false),
                    child: InkWell(
                      autofocus: widget.autofocus,
                      onTap: widget.onPressed,
                      onLongPress: widget.actions && holdOpensMenu ? _showMenu : null,
                      onSecondaryTapUp: widget.actions ? (d) => _showMenu(at: d.globalPosition) : null,
                      onFocusChange: _onFocusChange,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ItemImage(image: image, maxWidth: widget.width, placeholder: _TitlePlaceholder(item.name)),
                          _Badges(item: item),
                          MalScoreBadge(item: item),
                          if (item.userData.hasProgress && item.userData.playedPercentage != null)
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: LinearProgressIndicator(
                                value: item.userData.playedPercentage! / 100,
                                minHeight: 4,
                                backgroundColor: Colors.black54,
                              ),
                            ),
                          if (paged && resume) ?_TimeLeft.of(item),
                          if (lifted && resume)
                            const IgnorePointer(
                              child: Center(
                                child: Icon(
                                  Icons.play_circle_fill,
                                  size: 46,
                                  color: Colors.white,
                                  shadows: [Shadow(blurRadius: 12, color: Colors.black54)],
                                ),
                              ),
                            ),
                          if (tilted) const TileShine() else if (lifted && !resume) const _Shine(),
                          if (widget.actions && _hover)
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: CardHoverActions(item: item, onMenu: _showMenu),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ),
            ),
          ),
          const SizedBox(height: 8),
          // The caption is clickable too, but not a separate focus stop.
          GestureDetector(
            onTap: widget.onPressed,
            onLongPress: widget.actions && holdOpensMenu ? _showMenu : null,
            onSecondaryTapUp: widget.actions ? (d) => _showMenu(at: d.globalPosition) : null,
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Consumer(
                  builder: (context, ref, _) => _CaptionLine(
                    // Explicit titles stay; the default follows the
                    // MyAnimeList title-language setting.
                    text: widget.title ?? preferredAnimeTitle(ref, item, title),
                    style: theme.textTheme.bodyMedium,
                    onPressed: widget.onTitlePressed,
                  ),
                ),
                if (subtitle != null)
                  Consumer(
                    builder: (context, ref, _) => _CaptionLine(
                      // An episode's own name follows the title language too.
                      text: widget.title == null && item.type == ItemType.episode
                          ? [?item.episodeLabel, preferredEpisodeTitle(ref, item, item.name)].join(' · ')
                          : subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      onPressed: widget.onSubtitlePressed,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  (String, String?) _caption(BaseItem item) {
    if (widget.title != null) return (widget.title!, widget.subtitle);
    if (item.type == ItemType.episode) {
      final label = item.episodeLabel;
      return (item.seriesName ?? item.name, [?label, item.name].join(' · '));
    }
    return (item.name, widget.subtitle ?? item.yearLabel);
  }
}

/// One caption line; with [onPressed] it's a link of its own, underlined
/// on hover, otherwise taps fall through to the card's action.
class _CaptionLine extends StatefulWidget {
  const _CaptionLine({required this.text, this.style, this.onPressed});

  final String text;
  final TextStyle? style;
  final VoidCallback? onPressed;

  @override
  State<_CaptionLine> createState() => _CaptionLineState();
}

class _CaptionLineState extends State<_CaptionLine> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      widget.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _hover ? widget.style?.copyWith(decoration: TextDecoration.underline) : widget.style,
    );
    final onPressed = widget.onPressed;
    if (onPressed == null) return text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: onPressed, behavior: HitTestBehavior.opaque, child: text),
    );
  }
}

/// Watched check or unwatched-episode count in the top-right corner.
class _Badges extends StatelessWidget {
  const _Badges({required this.item});

  final BaseItem item;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final unplayed = item.userData.unplayedItemCount;
    final Widget? badge;
    if (item.userData.played) {
      badge = Icon(Icons.check, size: 16, color: colors.onPrimary);
    } else if (unplayed != null && unplayed > 0 && item.type != ItemType.episode) {
      badge = Text(
        '$unplayed',
        style: TextStyle(color: colors.onPrimary, fontSize: 12, fontWeight: FontWeight.w600),
      );
    } else {
      badge = null;
    }
    if (badge == null) return const Positioned(top: 0, right: 0, child: SizedBox.shrink());

    // Positioned keeps the badge its own size; a Container with `alignment`
    // would otherwise expand to cover the whole card.
    return Positioned(
      top: 6,
      right: 6,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
        decoration: BoxDecoration(color: colors.primary, borderRadius: BorderRadius.circular(11)),
        child: Center(widthFactor: 1, heightFactor: 1, child: badge),
      ),
    );
  }
}

class _TitlePlaceholder extends StatelessWidget {
  const _TitlePlaceholder(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
        ),
      ),
    );
  }
}

/// "24m left" at the top right of a Continue watching card (Paged rows).
class _TimeLeft extends StatelessWidget {
  const _TimeLeft(this.minutes);

  final int minutes;

  static Widget? of(BaseItem item) {
    final total = item.runTimeTicks;
    if (total == null || !item.userData.hasProgress) return null;
    final left = ((total - item.userData.playbackPositionTicks) / 600000000).ceil();
    return left > 0 ? _TimeLeft(left) : null;
  }

  @override
  Widget build(BuildContext context) => Positioned(
        top: 6,
        right: 6,
        child: DecoratedBox(
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(11)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            child: Text(
              minutes >= 60 ? '${minutes ~/ 60}h ${minutes % 60}m left' : '${minutes}m left',
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
}

/// A light sweeping across a card once as the mouse arrives (Paged rows).
class _Shine extends StatelessWidget {
  const _Shine();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: -1.6, end: 1.6),
          duration: const Duration(milliseconds: 750),
          curve: Curves.easeInOut,
          builder: (context, x, _) => Align(
            alignment: Alignment(x, 0),
            child: FractionallySizedBox(
              widthFactor: 0.4,
              heightFactor: 1.6,
              child: Transform.rotate(
                angle: 0.35,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.transparent, Color(0x33FFFFFF), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
