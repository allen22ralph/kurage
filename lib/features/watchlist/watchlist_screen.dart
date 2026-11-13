import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/backdrop.dart';
import '../../app/card_look.dart';
import '../../app/layout.dart';
import '../../app/providers.dart';
import '../../app/system_nav_bar.dart';
import '../../app/toast.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../../theme/components.dart';
import '../home/depth/deck_hero.dart' show GlassRound, RiseIn;
import '../home/depth/depth_top_bar.dart';
import '../home/depth/tab_nav.dart';
import '../home/home_actions.dart';
import '../home/home_components.dart';
import '../home/home_tabs.dart';
import '../library/depth/detail_parts.dart';
import '../library/item_detail_screen.dart' show formatRuntime;
import '../library/library_providers.dart';
import '../library/navigation.dart';
import '../library/widgets/card_actions.dart';
import '../library/widgets/item_image.dart';
import '../library/widgets/media_card.dart';
import '../library/widgets/selection.dart';
import '../settings/appearance.dart';
import 'watchlist_providers.dart';

part 'depth_watchlist.dart';

/// What the page shows: everything, or one kind.
enum WatchlistFilter {
  all('All'),
  shows('Shows'),
  episodes('Episodes'),
  movies('Movies');

  const WatchlistFilter(this.label);
  final String label;

  bool keeps(BaseItem item) => switch (this) {
    all => true,
    shows => isShow(item),
    episodes => item.type == ItemType.episode,
    movies => item.type == ItemType.movie,
  };
}

/// A show on the list: a whole series, or one of its seasons.
bool isShow(BaseItem item) =>
    item.type == ItemType.series || item.type == ItemType.season;

enum WatchlistSort {
  /// The user's own order (see [arrange]); [compare] doesn't apply.
  yours('Your order', 'Your order'),
  title('Title', 'Title'),
  released('Newest first', 'Newest');

  const WatchlistSort(this.label, this.short);
  final String label;

  /// For a narrow slot.
  final String short;

  int compare(BaseItem a, BaseItem b) => switch (this) {
    yours => 0,
    released => _newestFirst(a.premiereDate, b.premiereDate),
    title => _titleOf(a).toLowerCase().compareTo(_titleOf(b).toLowerCase()),
  };

  static int _newestFirst(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == null ? (b == null ? 0 : 1) : -1;
    return b.compareTo(a);
  }
}

/// An episode sorts and shows under its show's name.
String _titleOf(BaseItem item) =>
    item.type == ItemType.episode ? (item.seriesName ?? item.name) : item.name;

/// The line under a title: where it's at.
String watchlistSubline(BaseItem item) {
  final year = item.productionYear;
  final String state;
  if (isShow(item)) {
    final left = item.userData.unplayedItemCount;
    state = item.userData.played
        ? 'Watched'
        : left == null || left == 0
        ? 'Not started'
        : '$left unwatched';
  } else if (timeLeft(item) case final left?) {
    state = item.type == ItemType.episode && item.episodeLabel != null
        ? '${item.episodeLabel} · $left'
        : left;
  } else if (item.userData.played) {
    state = 'Watched';
  } else if (item.type == ItemType.episode) {
    state = item.episodeLabel ?? 'Episode';
  } else {
    state = item.runtime == null ? 'Not started' : formatRuntime(item.runtime!);
  }
  return [
    if (year != null && item.type != ItemType.episode) '$year',
    state,
  ].join(' · ');
}

/// The user's watchlist: shows, episodes and movies kept apart, as
/// KefinTweaks' web watchlist keeps them (both read the same list).
class WatchlistScreen extends ConsumerStatefulWidget {
  const WatchlistScreen({super.key});

  @override
  ConsumerState<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends ConsumerState<WatchlistScreen> {
  final _selection = Selection();
  var _filter = WatchlistFilter.all;
  var _sort = WatchlistSort.yours;
  var _list = false;

  /// Picking, after Select (the selection itself may still be empty).
  var _selecting = false;

  bool get _picking => _selecting || _selection.active;

  /// Depth: how far the page has scrolled (for the bar), its controller
  /// (for the selection bar), and whose art is behind it.
  final _scrolled = ValueNotifier<double>(0);
  final _scroll = ScrollController();
  String? _artFor;

  @override
  void initState() {
    super.initState();
    _selection.addListener(_changed);
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_changed)
      ..dispose();
    _scrolled.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// setState, for the Depth page's part of this state.
  void _update(VoidCallback change) => setState(change);

  void _changed() => setState(() {
    if (!_selection.active) _selecting = false;
  });

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(watchlistProvider);
    final all = items.value ?? const <BaseItem>[];
    final yours = ref.watch(watchlistOrderProvider).value ?? const <String>[];
    final kept = [
      for (final i in all)
        if (_filter.keeps(i)) i,
    ];
    final shown = _sort == WatchlistSort.yours
        ? arrange(kept, yours)
        : (kept..sort(_sort.compare));
    final order = [for (final i in shown) i.id];

    // A theme with pages of its own (Depth) draws this one too.
    if (ref.watch(componentStyleProvider(Slots.itemPage)).variant == 'feature' &&
        HomeComponents.fillsBar(ref.watch(componentStyleProvider(Slots.homeTopBar)))) {
      return _depthFrame(context, items, all, shown);
    }

    return Scaffold(
      appBar: _picking
          ? SelectionBar(
              selection: _selection,
              label: '${_selection.ids.length} selected',
              onSelectAll: () => _selection.setAll(order),
              actions: _bulkActions(all),
            )
          : AppBar(
              title: const Text('Watchlist'),
              actions: [
                if (all.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => setState(() => _selecting = true),
                    icon: const Icon(Icons.checklist),
                    label: const Text('Select'),
                  ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => ref.invalidate(watchlistProvider),
                ),
                const SizedBox(width: 8),
              ],
            ),
      body: SelectionShortcuts(
        selection: _selection,
        selectAll: () => _selection.setAll(order),
        autofocus: true,
        child: RefreshIndicator(
          onRefresh: () => ref.refresh(watchlistProvider.future),
          child: switch (items) {
            AsyncError(:final error) when items.value == null => _Message(
              title: "Couldn't load your watchlist",
              line: '$error',
              action: OutlinedButton(
                onPressed: () => ref.invalidate(watchlistProvider),
                child: const Text('Retry'),
              ),
            ),
            _ when items.value == null => const Center(
              child: CircularProgressIndicator(),
            ),
            _ => _page(context, all, shown, order),
          },
        ),
      ),
    );
  }

  List<Widget> _bulkActions(List<BaseItem> all) {
    final chosen = [
      for (final i in all)
        if (_selection.contains(i.id)) i,
    ];
    Future<void> watched(bool on) async {
      final api = ref.read(libraryApiProvider);
      _selection.clear();
      final what = chosen.length == 1
          ? chosen.single.name
          : '${chosen.length} items';
      try {
        for (final item in chosen) {
          await api.setPlayed(item.id, on);
        }
        showToast('Marked $what ${on ? 'watched' : 'unwatched'}');
      } on JellyfinException catch (e) {
        showToast(e.message);
      } finally {
        refreshWatchState(ref.invalidate);
      }
    }

    /// To the top of your order, keeping theirs among themselves.
    Future<void> toTop() async {
      _selection.clear();
      final mover = ref.read(watchlistOrderProvider.notifier);
      final yours = ref.read(watchlistOrderProvider).value ?? const <String>[];
      final picked = {for (final i in chosen) i.id};
      final inOrder = [for (final i in arrange(all, yours)) if (picked.contains(i.id)) i];
      // Each goes to the very top, last first.
      for (final item in inOrder.reversed) {
        await mover.move(all, item.id);
      }
      if (_sort != WatchlistSort.yours) setState(() => _sort = WatchlistSort.yours);
    }

    return [
      IconButton(
        tooltip: 'Move to top',
        icon: const Icon(Icons.vertical_align_top),
        onPressed: chosen.isEmpty ? null : toTop,
      ),
      IconButton(
        tooltip: 'Mark watched',
        icon: const Icon(Icons.check),
        onPressed: chosen.isEmpty ? null : () => watched(true),
      ),
      IconButton(
        tooltip: 'Mark unwatched',
        icon: const Icon(Icons.remove_done),
        onPressed: chosen.isEmpty ? null : () => watched(false),
      ),
      IconButton(
        tooltip: 'Remove from watchlist',
        icon: const Icon(Icons.bookmark_remove_outlined),
        onPressed: chosen.isEmpty
            ? null
            : () {
                unawaited(CardActions(context).setWatchlisted(chosen, false));
                _selection.clear();
              },
      ),
    ];
  }

  Widget _page(
    BuildContext context,
    List<BaseItem> all,
    List<BaseItem> shown,
    List<String> order,
  ) {
    final layout = context.layout;
    final theme = Theme.of(context);
    int count(WatchlistFilter f) => all.where(f.keeps).length;
    final counts = [
      '${all.length} ${all.length == 1 ? 'title' : 'titles'}',
      for (final f in [
        WatchlistFilter.shows,
        WatchlistFilter.episodes,
        WatchlistFilter.movies,
      ])
        if (count(f) > 0) '${count(f)} ${count(f) == 1 ? f.label.toLowerCase().substring(0, f.label.length - 1) : f.label.toLowerCase()}',
    ].join(' · ');

    // "All" keeps each kind in its own section; one kind is one grid.
    final sections = _filter == WatchlistFilter.all
        ? [
            for (final f in [
              WatchlistFilter.shows,
              WatchlistFilter.episodes,
              WatchlistFilter.movies,
            ])
              (
                f,
                [
                  for (final i in shown)
                    if (f.keeps(i)) i,
                ],
              ),
          ].where((s) => s.$2.isNotEmpty).toList()
        : [(_filter, shown)];

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(math.max(layout.gutter, 16.0), 8, math.max(layout.gutter, 16.0), 0),
            child: Text(
              counts,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(child: _toolbar(context, count)),
        if (shown.isEmpty)
          SliverToBoxAdapter(
            child: _Message(
              title: 'Nothing here yet',
              line: all.isEmpty
                  ? 'Use "Add to watchlist" on any show, episode or movie to add it.'
                  : 'Nothing on your watchlist is a ${_filter.label.toLowerCase().replaceAll(RegExp(r's$'), '')}.',
            ),
          )
        else
          for (final (kind, items) in sections) ...[
            if (_filter == WatchlistFilter.all)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    math.max(layout.gutter, 16.0),
                    20,
                    math.max(layout.gutter, 16.0),
                    0,
                  ),
                  child: Text(
                    '${kind.label} · ${items.length}',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ),
            if (_list)
              _listOf(context, items, order)
            else
              _grid(context, items, order, kind: kind),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  Widget _toolbar(BuildContext context, int Function(WatchlistFilter) count) {
    final layout = context.layout;
    return Padding(
      padding: EdgeInsets.fromLTRB(math.max(layout.gutter, 16.0), 16, math.max(layout.gutter, 16.0), 0),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<WatchlistFilter>(
            showSelectedIcon: false,
            segments: [
              for (final f in WatchlistFilter.values)
                ButtonSegment(value: f, label: Text('${f.label} ${count(f)}')),
            ],
            selected: {_filter},
            onSelectionChanged: (s) => setState(() => _filter = s.single),
          ),
          PopupMenuButton<WatchlistSort>(
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => [
              for (final s in WatchlistSort.values)
                PopupMenuItem(value: s, child: Text(s.label)),
            ],
            child: Chip(
              avatar: const Icon(Icons.sort, size: 18),
              label: Text(_sort.label),
            ),
          ),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.grid_view),
                tooltip: 'Grid',
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.view_list),
                tooltip: 'List',
              ),
            ],
            selected: {_list},
            onSelectionChanged: (s) => setState(() => _list = s.single),
          ),
          if (_sort == WatchlistSort.yours && !_list)
            Text(
              'List view lets you drag them into order',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  /// A click opens, unless it's picking (Ctrl/Shift, or while selecting).
  void _press(BaseItem item, List<String> order) {
    if (_selecting && !_selection.active) return _selection.toggle(item.id);
    if (_selection.tap(order, item.id)) return;
    openItem(context, item);
  }

  Widget _grid(
    BuildContext context,
    List<BaseItem> items,
    List<String> order, {
    required WatchlistFilter kind,
  }) {
    final layout = context.layout;
    final shape = kind == WatchlistFilter.episodes
        ? CardShape.landscape
        : CardShape.poster;
    final width = shape == CardShape.landscape
        ? layout.landscapeWidth
        : layout.posterWidth;
    return SliverPadding(
      padding: EdgeInsets.all(math.max(layout.gutter, 16.0)),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: width + 16,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: width / (width / shape.aspectRatio + 56),
        ),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          return DecoratedBox(
            decoration:
                selectedRowDecoration(
                  context,
                  selected: _selection.contains(item.id),
                ) ??
                const BoxDecoration(),
            child: LayoutBuilder(
              builder: (context, constraints) => MediaCard(
                item: item,
                width: constraints.maxWidth,
                shape: shape,
                subtitle: watchlistSubline(item),
                onPressed: () => _press(item, order),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _listOf(
    BuildContext context,
    List<BaseItem> items,
    List<String> order,
  ) {
    final layout = context.layout;
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final thumb = narrow ? 120.0 : 220.0;
    // Dragging only makes sense in the user's own order.
    final reorder =
        _sort == WatchlistSort.yours && !_picking && items.length > 1;

    Widget row(BuildContext context, int i) {
      final item = items[i];
      final fraction = watchedFraction(item);
      return Container(
        key: ValueKey(item.id),
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: selectedRowDecoration(
          context,
          selected: _selection.contains(item.id),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _press(item, order),
          onLongPress: () => _selection.toggle(item.id),
          onSecondaryTapUp: (e) =>
              showCardMenu(context, item, at: e.globalPosition),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: thumb,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ItemImage(
                            image:
                                item.landscapeImage ??
                                item.backdropImage ??
                                item.posterImage,
                            maxWidth: thumb,
                          ),
                          if (fraction > 0)
                            Align(
                              alignment: Alignment.bottomLeft,
                              child: FractionallySizedBox(
                                widthFactor: fraction,
                                child: Container(
                                  height: 4,
                                  color: theme.colorScheme.secondary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _titleOf(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      if (item.type == ItemType.episode ||
                          item.type == ItemType.season)
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      Text(
                        watchlistSubline(item),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (!narrow && item.overview != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          item.overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                if (!_picking)
                  IconButton(
                    tooltip: 'Remove from watchlist',
                    icon: const Icon(Icons.bookmark_remove_outlined),
                    onPressed: () =>
                        CardActions(context).setWatchlisted([item], false),
                  ),
                if (reorder)
                  ReorderableDragStartListener(
                    index: i,
                    child: const Tooltip(
                      message: 'Drag to move',
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: math.max(layout.gutter, 16.0), vertical: 8),
      sliver: reorder
          ? SliverReorderableList(
              itemCount: items.length,
              itemBuilder: row,
              onReorderItem: (from, to) => _moved(items, from, to),
            )
          : SliverList.builder(itemCount: items.length, itemBuilder: row),
    );
  }

  /// A row dragged from [from] to [to] (its index once moved) among [items],
  /// one section of the page.
  void _moved(List<BaseItem> items, int from, int to) {
    final list = [...items];
    final moved = list.removeAt(from);
    final at = to;
    list.insert(at, moved);
    if (at == from) return;
    final all = ref.read(watchlistProvider).value ?? items;
    final order = ref.read(watchlistOrderProvider.notifier);
    if (at + 1 < list.length) {
      unawaited(order.move(all, moved.id, before: list[at + 1].id));
    } else {
      unawaited(order.move(all, moved.id, after: list[at - 1].id));
    }
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.line, this.action});

  final String title;
  final String line;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                line,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}
