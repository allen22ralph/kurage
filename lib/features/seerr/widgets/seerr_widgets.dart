import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../../core/seerr/seerr_api.dart';
import '../request_window.dart';
import '../seerr_providers.dart';
import '../../library/widgets/action_menu.dart';
import '../../library/widgets/item_image.dart';
import '../../library/widgets/side_scroll.dart';
import '../../../theme/app_tokens.dart';

/// Opens the library item for a title that's on the server ([serverItemId],
/// see serverItemFor), otherwise its Seerr page (to request it).
void openSeerrMedia(BuildContext context, SeerrMedia media, {String? serverItemId}) {
  final id = serverItemId ?? (media.status == SeerrMediaStatus.available ? media.jellyfinId : null);
  if (id != null && media.status != SeerrMediaStatus.partiallyAvailable) {
    context.push('/item/$id');
  } else {
    context.push('/seerr/${media.type.name}/${media.tmdbId}');
  }
}

/// "On your server", for titles found in the library by TMDB id that
/// Seerr itself doesn't mark available.
class _OnServerBadge extends StatelessWidget {
  const _OnServerBadge();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: context.tokens.status.available, borderRadius: BorderRadius.circular(10)),
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text(
        'On your server',
        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

/// "Available" / "Requested" / … as a small coloured label.
class SeerrStatusBadge extends StatelessWidget {
  const SeerrStatusBadge({super.key, required this.status});

  final SeerrMediaStatus status;

  @override
  Widget build(BuildContext context) {
    if (status == SeerrMediaStatus.unknown) return const SizedBox.shrink();
    final colors = context.tokens.status;
    final color = switch (status) {
      SeerrMediaStatus.available => colors.available,
      SeerrMediaStatus.partiallyAvailable => colors.partiallyAvailable,
      SeerrMediaStatus.processing => colors.processing,
      SeerrMediaStatus.pending => colors.pending,
      SeerrMediaStatus.blocklisted => colors.blocked,
      _ => Colors.grey.shade700,
    };
    return DecoratedBox(
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          status.label,
          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// A tile's status pill: what Seerr says, or "On server" for a library
/// match; nothing for titles no one asked for (trending).
class _TileStatus extends StatelessWidget {
  const _TileStatus({required this.media, required this.onServer});

  final SeerrMedia media;
  final bool onServer;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.status;
    if (onServer) return StatusPill(label: 'On server', color: colors.available);
    final color = switch (media.status) {
      SeerrMediaStatus.available => colors.available,
      SeerrMediaStatus.partiallyAvailable => colors.partiallyAvailable,
      SeerrMediaStatus.pending => colors.pending,
      SeerrMediaStatus.processing => colors.processing,
      SeerrMediaStatus.blocklisted => colors.blocked,
      _ => null,
    };
    return color == null ? const SizedBox.shrink() : StatusPill(label: media.status.label, color: color);
  }
}

/// A TMDB poster card for a Seerr title; focusable like library cards.
class SeerrCard extends ConsumerStatefulWidget {
  const SeerrCard({super.key, required this.media, required this.width});

  final SeerrMedia media;
  final double width;

  @override
  ConsumerState<SeerrCard> createState() => _SeerrCardState();
}

class _SeerrCardState extends ConsumerState<SeerrCard> {
  bool _focused = false;
  bool _hover = false;

  /// The card's artwork on screen, for the request window to grow from.
  Rect? get _rect {
    final box = context.findRenderObject() as RenderBox?;
    return box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  void _request() => showSeerrRequest(context, widget.media, from: _rect);

  /// Partly on the server: what's asked for is the missing seasons.
  String get _requestLabel => widget.media.status == SeerrMediaStatus.partiallyAvailable ? 'Request more' : 'Request';

  /// Long press, right-click (a popup at [at]) or a remote's menu key.
  void _menu(VoidCallback open, bool requestable, {Offset? at}) => showActionMenu(
    context,
    at: at,
    title: widget.media.title,
    subtitle: [
      ?widget.media.year?.toString(),
      widget.media.type == SeerrMediaType.movie ? 'Movie' : 'Series',
    ].join(' · '),
    entries: [
      if (requestable) MenuEntry(icon: Icons.add_circle_outline, label: '$_requestLabel…', onSelected: _request),
      MenuEntry(icon: Icons.info_outline, label: 'Details', onSelected: open),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = widget.media;
    final poster = media.poster();
    final serverItem = serverItemFor(media, ref.watch(libraryTmdbIndexProvider).value);
    // Seerr's own status when it knows; else our library match.
    final onServerOnly =
        serverItem != null &&
        media.status != SeerrMediaStatus.available &&
        media.status != SeerrMediaStatus.partiallyAvailable;
    void open() => openSeerrMedia(context, media, serverItemId: onServerOnly ? serverItem : null);
    // Hidden once it's requested or on the server (the badge says which).
    final requestable = !onServerOnly && canRequestFromCard(ref, media);
    // A theme's poster tiles (Depth): lift and tilt instead of growing.
    final tiles = CardLook.of(context)?.tiles ?? false;
    final radius = tiles ? context.tokens.radius.card : 8.0;
    Widget frame(Widget poster) => tiles
        ? TiltTile(lifted: _hover || _focused, focused: _focused, radius: radius, child: poster)
        : AnimatedScale(scale: _focused ? 1.06 : 1, duration: const Duration(milliseconds: 120), child: poster);
    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          frame(
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Material(
                clipBehavior: Clip.antiAlias,
                color: theme.colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(tiles ? radius - 1 : radius),
                  side: _focused && !tiles ? BorderSide(color: theme.colorScheme.primary, width: 3) : BorderSide.none,
                ),
                child: CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.contextMenu): () => _menu(open, requestable)},
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _hover = true),
                    onExit: (_) => setState(() => _hover = false),
                    child: InkWell(
                      onTap: open,
                      onLongPress: holdOpensMenu ? () => _menu(open, requestable) : null,
                      onSecondaryTapUp: (d) => _menu(open, requestable, at: d.globalPosition),
                      onFocusChange: (f) {
                        setState(() => _focused = f);
                        if (f) {
                          Scrollable.ensureVisible(
                            context,
                            alignment: 0.5,
                            duration: const Duration(milliseconds: 150),
                            alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
                          );
                        }
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (poster != null)
                            ref.watch(networkImageBuilderProvider)(
                              poster.toString(),
                              fit: BoxFit.cover,
                              alignment: Alignment.center,
                              fallback: const SizedBox.shrink(),
                            ),
                          if (tiles)
                            Positioned(top: 10, left: 10, child: _TileStatus(media: media, onServer: onServerOnly))
                          else
                            Positioned(
                              top: 6,
                              right: 6,
                              child: onServerOnly ? const _OnServerBadge() : SeerrStatusBadge(status: media.status),
                            ),
                          if (_hover && requestable)
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                // Mouse only: keyboard / D-pad focus stays on the card.
                                child: ExcludeFocus(
                                  // One line, always "Request" (the badge says
                                  // what's there); just ⊕ on narrow cards.
                                  child: Tooltip(
                                    message: widget.media.status == SeerrMediaStatus.partiallyAvailable
                                        ? 'Request the missing seasons'
                                        : 'Request',
                                    child: widget.width < 130
                                        ? IconButton.filledTonal(
                                            onPressed: _request,
                                            icon: const Icon(Icons.add_circle_outline, size: 18),
                                          )
                                        : FilledButton.tonalIcon(
                                            style: FilledButton.styleFrom(
                                              visualDensity: VisualDensity.compact,
                                              padding: const EdgeInsets.symmetric(horizontal: 12),
                                              textStyle: Theme.of(context).textTheme.labelMedium,
                                            ),
                                            onPressed: _request,
                                            icon: const Icon(Icons.add_circle_outline, size: 16),
                                            label: const Text('Request', maxLines: 1),
                                          ),
                                  ),
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
          const SizedBox(height: 8),
          // The caption opens it too, like library cards (not a focus stop).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: open,
            onLongPress: holdOpensMenu ? () => _menu(open, requestable) : null,
            onSecondaryTapUp: (d) => _menu(open, requestable, at: d.globalPosition),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (tiles) const SizedBox(height: 4),
                Text(
                  media.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tiles
                      ? theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)
                      : theme.textTheme.bodyMedium,
                ),
                Text(
                  // Tiles: the year only (no description).
                  tiles
                      ? media.year?.toString() ?? ''
                      : media.note ??
                          [?media.year?.toString(), media.type == SeerrMediaType.movie ? 'Movie' : 'Series'].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled row of Seerr titles; hidden while loading or empty, a short
/// note on errors (rather than silently nothing).
class SeerrMediaRow extends StatelessWidget {
  const SeerrMediaRow({super.key, required this.title, required this.items, this.subtitle});

  final String title;
  final AsyncValue<List<SeerrMedia>> items;

  /// A line under the title, e.g. why the row was picked.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final layout = context.layout;
    if (items case AsyncError(:final error) when !items.hasValue) {
      return Padding(
        padding: EdgeInsets.fromLTRB(layout.gutter, 24, layout.gutter, 8),
        child: Text(
          '$title: ${error is SeerrException ? error.message : "Seerr didn't answer."}',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    final list = items.value;
    if (list == null || list.isEmpty) return const SizedBox.shrink();
    final look = CardLook.of(context);
    final tiles = look?.tiles ?? false;
    final width = tiles ? CardLook.tileWidth(context) : layout.posterWidth;
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: look?.kicker != null ? CardLook.headingStyle(context) : Theme.of(context).textTheme.titleLarge,
    );
    return RowScope(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(layout.gutter, 24, layout.gutter, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: look?.kicker != null
                        ? KickerHeading(kicker: look!.kicker!, title: titleText)
                        : Row(
                            children: [
                              Flexible(child: titleText),
                              const SizedBox(width: 8),
                              Text('Seerr', style: Theme.of(context).textTheme.labelSmall),
                            ],
                          ),
                  ),
                  const RowPager(),
                ],
              ),
              if (subtitle case final s?)
                Text(
                  s,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
        SizedBox(
          // Poster + two caption lines + the focus scale (tiles: their lift).
          height: width * 1.5 + (tiles ? 96 : 80),
          child: FocusTraversalGroup(
            child: SideScroll(
              pageable: true,
              builder: (controller) => ListView.separated(
                controller: controller,
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                itemCount: list.length,
                padding: EdgeInsets.fromLTRB(layout.gutter, tiles ? 16 : 8, layout.gutter, 8),
                separatorBuilder: (_, _) => SizedBox(width: tiles ? 20 : 16),
                itemBuilder: (context, i) => RowItem(index: i, child: SeerrCard(media: list[i], width: width)),
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }
}
