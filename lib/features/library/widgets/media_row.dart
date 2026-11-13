import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../../core/jellyfin/items.dart';
import 'card_actions.dart';
import 'media_card.dart';
import 'side_scroll.dart';
import '../../../app/animations.dart';

/// How the rows under it deal with failing to load. [hide]: they say nothing
/// (suggestions; or something above already says the server can't be
/// reached). [onRetry]: they offer to try again.
class RowErrors extends InheritedWidget {
  const RowErrors({super.key, this.hide = false, this.onRetry, required super.child});

  final bool hide;
  final VoidCallback? onRetry;

  static RowErrors? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<RowErrors>();

  @override
  bool updateShouldNotify(RowErrors old) => hide != old.hide || onRetry != old.onRetry;
}

/// A titled, horizontally scrolling row of item cards.
///
/// Hides itself when the data loads empty, so home only shows rows that
/// have something in them.
class MediaRow extends StatelessWidget {
  const MediaRow({
    super.key,
    required this.title,
    required this.items,
    required this.onItemPressed,
    this.shape = CardShape.poster,
    this.onTitlePressed,
    this.onItemTitlePressed,
    this.onItemSubtitlePressed,
    this.cardRow,
  });

  final String title;
  final AsyncValue<List<BaseItem>> items;
  final CardShape shape;
  final void Function(BaseItem item) onItemPressed;
  final VoidCallback? onTitlePressed;

  /// Make each card's caption lines links of their own (see [MediaCard]).
  final void Function(BaseItem item)? onItemTitlePressed;
  final void Function(BaseItem item)? onItemSubtitlePressed;

  /// Continue watching / Next up: their cards offer removing from the row.
  final CardRow? cardRow;

  @override
  Widget build(BuildContext context) {
    final layout = context.layout;
    final look = CardLook.of(context);
    // A theme's poster tiles: their own width, and room for the lift.
    final tiles = (look?.tiles ?? false) && shape == CardShape.poster;
    final cardWidth = tiles
        ? CardLook.tileWidth(context)
        : shape == CardShape.landscape
        ? layout.landscapeWidth
        : layout.posterWidth;
    // Card image + two caption lines + room for the focus scale.
    final rowHeight = cardWidth / shape.aspectRatio + (tiles ? 84 : 64);

    final Widget content = switch (items) {
      AsyncData(:final value) when value.isEmpty => const SizedBox.shrink(),
      AsyncData(:final value) => SizedBox(
        height: rowHeight,
        child: FocusTraversalGroup(
          child: SideScroll(
            pageable: true,
            builder: (controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(layout.gutter, tiles ? 16 : 8, layout.gutter, 8),
              clipBehavior: Clip.none,
              itemCount: value.length,
              separatorBuilder: (_, _) => SizedBox(width: tiles ? 20 : 16),
              itemBuilder: (context, i) => RowItem(
                index: i,
                child: MediaCard(
                  item: value[i],
                  width: cardWidth,
                  shape: shape,
                  row: cardRow,
                  onPressed: () => onItemPressed(value[i]),
                  onTitlePressed: onItemTitlePressed == null ? null : () => onItemTitlePressed!(value[i]),
                  onSubtitlePressed: onItemSubtitlePressed == null ? null : () => onItemSubtitlePressed!(value[i]),
                ),
              ),
            ),
          ),
        ),
      ),
      AsyncError() => Padding(
        padding: EdgeInsets.symmetric(horizontal: layout.gutter),
        child: Row(
          children: [
            Flexible(
              child: Text("Couldn't load this row", style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            if (RowErrors.of(context)?.onRetry case final retry?) TextButton(onPressed: retry, child: const Text('Retry')),
          ],
        ),
      ),
      // Loading: placeholder cards in the row's shape.
      _ => SizedBox(
        height: rowHeight,
        child: SkeletonRow(
          cardWidth: cardWidth,
          aspectRatio: shape.aspectRatio,
          padding: EdgeInsets.symmetric(horizontal: layout.gutter, vertical: 8),
        ),
      ),
    };

    if (items case AsyncData(:final value) when value.isEmpty) {
      return const SizedBox.shrink();
    }
    if (items is AsyncError && (RowErrors.of(context)?.hide ?? false)) return const SizedBox.shrink();

    // Long titles end in "…" on a narrow screen.
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: look?.kicker != null ? CardLook.headingStyle(context) : Theme.of(context).textTheme.titleLarge,
    );
    final heading = onTitlePressed == null
        ? titleText
        : InkWell(
            onTap: onTitlePressed,
            borderRadius: BorderRadius.circular(4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: titleText),
                const Icon(Icons.chevron_right),
              ],
            ),
          );
    // Paged rows (Settings > Appearance > Rows): ‹ › by the title.
    return RowScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(layout.gutter, 24, layout.gutter, 4),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: look?.kicker == null ? heading : KickerHeading(kicker: look!.kicker!, title: heading),
                  ),
                ),
                const RowPager(),
              ],
            ),
          ),
          content,
        ],
      ),
    );
  }
}
