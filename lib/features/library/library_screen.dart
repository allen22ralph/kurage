import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/layout.dart';
import '../../app/smooth_wheel.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../../core/jellyfin/library_api.dart';
import '../anime/anime_providers.dart';
import '../home/home_tabs.dart';
import 'library_providers.dart';
import 'navigation.dart';
import 'widgets/add_to_playlist.dart';
import 'widgets/media_card.dart';

/// Paged, sortable, filterable grid of a library's items.
///
/// With [viewId] null it shows favorites across all libraries; with [allOf],
/// everything of that kind across them, as a page inside Home's tabs; with
/// [genre], the shows and films of that genre across them.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key, required this.viewId, this.allOf, this.title, this.genre});

  final String? viewId;
  final ItemType? allOf;
  final String? title;
  final String? genre;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  static const _pageSize = 100;

  ItemQuery? _query;
  final _items = <BaseItem>[];
  int _total = 0;
  bool _loading = false;
  String? _error;

  /// Bumped on every query change so stale page responses are dropped.
  int _generation = 0;

  bool get _hasMore => _items.length < _total;

  /// The favorites page: sectioned by kind, so it loads all of them.
  bool get _favorites => widget.viewId == null && widget.allOf == null && widget.genre == null;

  // Sorting/filtering by MyAnimeList score happens here, not on the
  // server: it needs every item, and each one's score from MAL.
  bool _malSort = false;
  bool _malAscending = false;
  double? _malMin;
  final _scores = <String, double?>{}; // item ID -> score; null = none
  Timer? _rebuild;

  bool get _malMode => _malSort || _malMin != null;

  /// The items to show: as loaded, or ordered/filtered by MAL score.
  List<BaseItem> get _shown {
    if (!_malMode) return _items;
    var list = [..._items];
    if (_malMin case final min?) {
      list = list.where((i) => (_scores[i.id] ?? -1) >= min).toList();
    }
    if (_malSort) {
      // Stable: equal or unknown scores keep the server's order.
      final order = {for (var i = 0; i < _items.length; i++) _items[i].id: i};
      list.sort((a, b) {
        final sa = _scores[a.id], sb = _scores[b.id];
        if (sa == null || sb == null) {
          if (sa != sb) return sa == null ? 1 : -1;
          return order[a.id]!.compareTo(order[b.id]!);
        }
        final c = _malAscending ? sa.compareTo(sb) : sb.compareTo(sa);
        return c != 0 ? c : order[a.id]!.compareTo(order[b.id]!);
      });
    }
    return list;
  }

  int get _scored => _items.where((i) => _scores.containsKey(i.id)).length;

  void _setMal({bool? sort, bool? ascending, double? min, bool clearMin = false}) {
    final wasOn = _malMode;
    setState(() {
      _malSort = sort ?? _malSort;
      _malAscending = ascending ?? _malAscending;
      if (clearMin) {
        _malMin = null;
      } else if (min != null) {
        _malMin = min;
      }
    });
    if (_malMode && !wasOn) {
      _fetchScores(_items);
      _loadMore();
    }
  }

  /// Looks up MAL scores for [items] (matching is local; scores come from
  /// cache or Jikan at its rate limit). Rebuilds in batches as they land.
  void _fetchScores(List<BaseItem> items) {
    final generation = _generation;
    for (final item in items) {
      if (_scores.containsKey(item.id)) continue;
      ref.read(animeForItemProvider(animeKeyOf(item)).future).then(
        (a) => a?.info?.score,
        onError: (Object _) => null,
      ).then((score) {
        if (!mounted || generation != _generation) return;
        _scores[item.id] = score;
        _rebuild ??= Timer(const Duration(milliseconds: 300), () {
          _rebuild = null;
          if (mounted) setState(() {});
        });
      });
    }
  }

  @override
  void dispose() {
    _rebuild?.cancel();
    playlistsChanged.removeListener(_playlistsChanged);
    super.dispose();
  }

  /// The playlists library: a playlist was made or deleted, so load again.
  void _playlistsChanged() {
    final query = _query;
    if (mounted && query != null && _isPlaylists(query)) _setQuery(query);
  }

  static bool _isPlaylists(ItemQuery query) =>
      query.includeItemTypes.length == 1 && query.includeItemTypes.single == ItemType.playlist;

  @override
  void initState() {
    super.initState();
    playlistsChanged.addListener(_playlistsChanged);
    if (widget.allOf case final type?) {
      _setQuery(ItemQuery(includeItemTypes: [type]));
    } else if (widget.genre case final genre?) {
      _setQuery(ItemQuery(includeItemTypes: const [ItemType.movie, ItemType.series], genres: [genre]));
    } else if (widget.viewId == null) {
      _setQuery(const ItemQuery(
        favoritesOnly: true,
        includeItemTypes: [ItemType.movie, ItemType.series, ItemType.episode],
      ));
    }
  }

  void _setQuery(ItemQuery query) {
    _generation++;
    setState(() {
      _query = query;
      _items.clear();
      _scores.clear();
      _total = 0;
      _error = null;
      _loading = false;
    });
    _loadMore();
  }

  Future<void> _loadMore() async {
    final query = _query;
    // Nothing left once the first page is in and everything is loaded.
    if (query == null || _loading || (_items.isNotEmpty && !_hasMore)) return;
    final generation = _generation;
    setState(() => _loading = true);
    try {
      final page = await ref
          .read(libraryApiProvider)
          .getItems(query, startIndex: _items.length, limit: _pageSize);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.totalCount;
        _loading = false;
      });
      // MAL mode needs the whole library: keep loading, scoring as we go.
      if (_malMode) {
        _fetchScores(page.items);
        if (_hasMore) unawaited(_loadMore());
      } else if (_favorites && _hasMore) {
        // Sectioned: a section's end isn't the list's, so all of them load.
        unawaited(_loadMore());
      }
    } on JellyfinException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewId = widget.viewId;
    if (viewId != null && _query == null) {
      // Need the view's collection type to know what to list.
      final view = ref.watch(itemProvider(viewId));
      return switch (view) {
        AsyncData(:final value) => _startWithView(value),
        AsyncError(:final error) => Scaffold(
            appBar: AppBar(),
            body: Center(child: Text('Couldn\'t load library: $error')),
          ),
        _ => Scaffold(
            appBar: AppBar(),
            body: const Center(child: CircularProgressIndicator()),
          ),
      };
    }

    final allOf = widget.allOf;
    final title = widget.title ?? (viewId == null
        ? 'Favorites'
        : ref.watch(itemProvider(viewId)).value?.name ?? '');
    final layout = context.layout;
    final query = _query!;
    final shown = _shown;
    // A tab's page: the top bar's Refresh loads it again.
    if (allOf != null) ref.listen(homeTabRefreshProvider, (_, _) => _setQuery(_query!));

    // Read here, as the page builds, not in the wheel's builder below.
    final genres = allOf != null
        ? ref.watch(genresOfTypeProvider(allOf))
        : viewId == null
        ? null
        : ref.watch(genresProvider(viewId));
    // Focus starts in the first section there is, at the top of the page.
    final firstKind = [ItemType.series, ItemType.movie, ItemType.episode].where((k) => shown.any((i) => i.type == k)).firstOrNull;
    final page = SmoothWheel(
      builder: (_, wheel) => CustomScrollView(
        controller: wheel,
        physics: allOf == null ? null : const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (allOf != null)
            SliverToBoxAdapter(
              child: Padding(
                // (Under the bar floating over the page.)
                padding: EdgeInsets.fromLTRB(layout.gutter, MediaQuery.paddingOf(context).top + 8, layout.gutter, 4),
                child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
              ),
            ),
          SliverToBoxAdapter(
            child: _Toolbar(
              query: query,
              total: _total,
              genres: genres,
              showFavorites: query.parentId != null || allOf != null || widget.genre != null,
              onChanged: (q) {
                // A server sort replaces the MAL sort.
                if (q.sortBy != query.sortBy) _malSort = false;
                _setQuery(q);
              },
              padding: layout.gutter,
              malSort: _malSort,
              malAscending: _malAscending,
              malMin: _malMin,
              malProgress: _malMode && (_scored < _items.length || _hasMore)
                  ? 'MAL scores: $_scored / ${_hasMore ? _total : _items.length}'
                  : null,
              onMalSort: () => _setMal(sort: true),
              onMalDirection: () => _setMal(ascending: !_malAscending),
              onMalMin: (min) => min == null ? _setMal(clearMin: true) : _setMal(min: min),
              onNewPlaylist: _isPlaylists(query) ? () => showNewPlaylist(context) : null,
            ),
          ),
          // Favorites: each kind in its own section; anything else, one grid.
          if (_favorites)
            for (final (label, type, shape) in const [
              ('Series', ItemType.series, CardShape.poster),
              ('Movies', ItemType.movie, CardShape.poster),
              ('Episodes', ItemType.episode, CardShape.landscape),
            ]) ...() {
              final items = [for (final item in shown) if (item.type == type) item];
              return [
                if (items.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(layout.gutter, 20, layout.gutter, 0),
                      child: Text('$label · ${items.length}', style: Theme.of(context).textTheme.titleLarge),
                    ),
                  ),
                  _grid(layout, items, shape: shape, autofocus: type == firstKind),
                ],
              ];
            }()
          else
            _grid(layout, shown, autofocus: allOf == null, pages: true),
          SliverToBoxAdapter(child: _footer(context)),
        ],
      ),
    );
    if (allOf != null) {
      return RefreshIndicator(onRefresh: () async => _setQuery(_query!), child: page);
    }
    return Scaffold(appBar: AppBar(title: Text(title)), body: page);
  }

  /// A grid of [items]. With [pages], reaching the end loads the next page.
  Widget _grid(LayoutSpec layout, List<BaseItem> items, {CardShape shape = CardShape.poster, bool autofocus = false, bool pages = false}) {
    final width = shape == CardShape.landscape ? layout.landscapeWidth : layout.posterWidth;
    return SliverPadding(
      padding: EdgeInsets.all(layout.gutter),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: width + 16,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: width / (width / shape.aspectRatio + 56),
        ),
        itemCount: items.length,
        itemBuilder: (context, i) {
          if (pages && !_malMode && _hasMore && i >= _items.length - 20) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
          }
          return LayoutBuilder(
            builder: (context, constraints) => MediaCard(
              item: items[i],
              width: constraints.maxWidth,
              shape: shape,
              // (A tab's page leaves the focus on its tab.)
              autofocus: i == 0 && autofocus,
              onPressed: () => openItem(context, items[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _startWithView(BaseItem view) {
    // Defer: setQuery calls setState, which can't happen during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _query == null) {
        _setQuery(ItemQuery(
          parentId: view.id,
          includeItemTypes: itemTypesForCollection(view.collectionType),
        ));
      }
    });
    return Scaffold(
      appBar: AppBar(title: Text(view.name)),
      body: const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _footer(BuildContext context) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _loadMore, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: Text('Nothing here yet.')),
      );
    }
    return const SizedBox(height: 48);
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.query,
    required this.total,
    required this.genres,
    required this.showFavorites,
    required this.onChanged,
    required this.padding,
    required this.malSort,
    required this.malAscending,
    required this.malMin,
    required this.malProgress,
    required this.onMalSort,
    required this.onMalDirection,
    required this.onMalMin,
    this.onNewPlaylist,
  });

  final ItemQuery query;
  final int total;
  final AsyncValue<List<String>>? genres;
  final bool showFavorites;
  final ValueChanged<ItemQuery> onChanged;
  final double padding;
  final bool malSort;
  final bool malAscending;
  final double? malMin;
  final String? malProgress;
  final VoidCallback onMalSort;
  final VoidCallback onMalDirection;
  final ValueChanged<double?> onMalMin;

  /// Set on the playlists library: its button, and only the filters that
  /// make sense for playlists (no MAL score, watched state or genres).
  final VoidCallback? onNewPlaylist;

  bool get _playlists => onNewPlaylist != null;

  static const _minScores = [6.0, 7.0, 8.0, 9.0];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(padding, 8, padding, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_playlists)
            FilledButton.tonalIcon(
              onPressed: onNewPlaylist,
              icon: const Icon(Icons.playlist_add),
              label: const Text('New playlist'),
            ),
          MenuAnchor(
            builder: (context, controller, _) => ActionChip(
              avatar: const Icon(Icons.sort, size: 18),
              label: Text(malSort ? 'MAL score' : query.sortBy.label),
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
            ),
            menuChildren: [
              for (final field in SortField.values)
                MenuItemButton(
                  leadingIcon: Icon(
                    !malSort && field == query.sortBy ? Icons.check : null,
                    size: 18,
                  ),
                  onPressed: () => onChanged(query.copyWith(
                    sortBy: field,
                    // Newest/highest first is what people usually want.
                    descending: field != SortField.name,
                  )),
                  child: Text(field.label),
                ),
              if (!_playlists)
                MenuItemButton(
                  leadingIcon: Icon(malSort ? Icons.check : null, size: 18),
                  onPressed: onMalSort,
                  child: const Text('MAL score'),
                ),
            ],
          ),
          ActionChip(
            avatar: Icon(
              (malSort ? !malAscending : query.descending) ? Icons.arrow_downward : Icons.arrow_upward,
              size: 18,
            ),
            label: Text((malSort ? !malAscending : query.descending) ? 'Descending' : 'Ascending'),
            onPressed: malSort
                ? onMalDirection
                : () => onChanged(query.copyWith(descending: !query.descending)),
          ),
          if (!_playlists) MenuAnchor(
            builder: (context, controller, _) => FilterChip(
              label: Text(malMin == null ? 'MAL score' : 'MAL ≥ ${malMin!.toStringAsFixed(0)}'),
              selected: malMin != null,
              onSelected: (_) => controller.isOpen ? controller.close() : controller.open(),
            ),
            menuChildren: [
              MenuItemButton(
                leadingIcon: Icon(malMin == null ? Icons.check : null, size: 18),
                onPressed: () => onMalMin(null),
                child: const Text('Any score'),
              ),
              for (final min in _minScores)
                MenuItemButton(
                  leadingIcon: Icon(malMin == min ? Icons.check : null, size: 18),
                  onPressed: () => onMalMin(min),
                  child: Text('${min.toStringAsFixed(0)} and up'),
                ),
            ],
          ),
          if (!_playlists)
            FilterChip(
              label: const Text('Unwatched'),
              selected: query.unplayedOnly,
              onSelected: (v) => onChanged(query.copyWith(unplayedOnly: v)),
            ),
          if (showFavorites)
            FilterChip(
              label: const Text('Favorites'),
              selected: query.favoritesOnly,
              onSelected: (v) => onChanged(query.copyWith(favoritesOnly: v)),
            ),
          if (genres?.value case final list? when list.isNotEmpty && !_playlists)
            ActionChip(
              avatar: const Icon(Icons.category_outlined, size: 18),
              label: Text(
                query.genres.isEmpty ? 'Genre' : query.genres.join(', '),
              ),
              onPressed: () async {
                final picked = await _pickGenres(context, list, query.genres);
                if (picked != null) onChanged(query.copyWith(genres: picked));
              },
            ),
          if (malProgress != null)
            Text(
              malProgress!,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
            ),
          if (total > 0)
            Text(
              '$total items',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Future<List<String>?> _pickGenres(
    BuildContext context,
    List<String> all,
    List<String> selected,
  ) {
    final chosen = {...selected};
    return showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Genres'),
          content: SizedBox(
            width: 400,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final genre in all)
                  CheckboxListTile(
                    title: Text(genre),
                    value: chosen.contains(genre),
                    onChanged: (v) => setState(() {
                      v == true ? chosen.add(genre) : chosen.remove(genre);
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, <String>[]),
              child: const Text('Clear'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, chosen.toList()),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }
}
