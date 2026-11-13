import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/system_nav_bar.dart';
import '../../app/toast.dart';
import '../../theme/components.dart';
import '../home/depth/depth_top_bar.dart';
import '../home/depth/tab_nav.dart';
import '../home/home_actions.dart';
import '../home/home_components.dart';
import '../home/home_tabs.dart';
import 'depth/detail_parts.dart';
import 'depth/episode_rows.dart';
import 'depth/episode_page.dart';
import 'depth/playlist_page.dart';
import 'depth/series_page.dart';
import '../../app/layout.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../../core/jellyfin/library_api.dart';
import '../anime/anime_settings.dart';
import '../anime/mal_account.dart';
import '../anime/widgets/mal_widgets.dart';
import '../downloads/downloads.dart';
import '../downloads/downloads_screen.dart';
import 'library_providers.dart';
import 'navigation.dart';
import 'widgets/action_menu.dart';
import 'widgets/add_to_playlist.dart';
import 'widgets/episode_swipe.dart';
import 'widgets/item_image.dart';
import 'widgets/selection.dart';
import 'widgets/media_card.dart';
import 'widgets/media_row.dart';
import 'widgets/side_scroll.dart';
import '../seerr/missing_seasons.dart';
import '../watchlist/watchlist_providers.dart';
import '../../app/backdrop.dart';

/// What a theme's item page draws.
typedef ItemPageData = ({BaseItem item, String? seasonId});

/// The styles a series, film or episode's page can be drawn in. Anything
/// else (a collection, a playlist) stays Classic's.
final itemPages = Variants<ItemPageData>(
  Slots.itemPage,
  classic: (context, d, style) => _Details(item: d.item, seasonId: d.seasonId),
)..register(
    'feature',
    (context, d, style) => switch (d.item.type) {
      ItemType.series || ItemType.movie => DepthSeriesPage(key: ValueKey(d.item.id), item: d.item, seasonId: d.seasonId),
      ItemType.episode => DepthEpisodePage(key: ValueKey(d.item.id), item: d.item),
      ItemType.playlist => DepthPlaylistPage(key: ValueKey(d.item.id), playlist: d.item),
      _ => _Details(item: d.item, seasonId: d.seasonId),
    },
  );

/// Details for a movie, series, episode, or collection.
class ItemDetailScreen extends ConsumerStatefulWidget {
  const ItemDetailScreen({super.key, required this.itemId, this.seasonId});

  final String itemId;

  /// For series: the season to show first (e.g. when opened from a season).
  final String? seasonId;

  @override
  ConsumerState<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends ConsumerState<ItemDetailScreen> {
  /// The top bar slides away while scrolling down and comes back on any
  /// scroll up (or at the top), so it doesn't sit over the page.
  bool _barShown = true;

  /// The item whose artwork was last put behind the page.
  String? _artFor;

  /// How far the page has scrolled, for a bar that follows it.
  final _scrolled = ValueNotifier<double>(0);

  /// Heading down the page, when the status bar is hidden.
  final _goingDown = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _scrolled.dispose();
    _goingDown.dispose();
    super.dispose();
  }

  /// The page changed size (entries taken out, say) and may have jumped
  /// back without a scroll: the bar follows where it is now.
  bool _onResize(ScrollMetricsNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    _scrolled.value = n.metrics.pixels;
    if (n.metrics.pixels <= 0) {
      _goingDown.value = false;
      if (!_barShown) setState(() => _barShown = true);
    }
    return false;
  }

  bool _onScroll(ScrollUpdateNotification n) {
    // The page itself, not the horizontal rows inside it.
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    _scrolled.value = n.metrics.pixels;
    final delta = n.scrollDelta ?? 0;
    if (n.metrics.pixels <= 0) {
      _goingDown.value = false;
    } else if (delta != 0) {
      _goingDown.value = delta > 0;
    }
    final show = n.metrics.pixels <= 0 || (delta < 0 ? true : (delta > 0 ? false : _barShown));
    if (show != _barShown) setState(() => _barShown = show);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(itemProvider(widget.itemId));
    // Appearance > Background > Show artwork: this show's (once loaded).
    if (item.value case final value? when _artFor != value.id) {
      _artFor = value.id;
      final container = ProviderScope.containerOf(context, listen: false);
      WidgetsBinding.instance.addPostFrameCallback((_) => BackdropArt.show(value, container));
    }
    // A theme's page of its own has Home's bar and tabs, when it has them.
    final type = item.value?.type;
    final barStyle = ref.watch(componentStyleProvider(Slots.homeTopBar));
    if (ref.watch(componentStyleProvider(Slots.itemPage)).variant == 'feature' &&
        HomeComponents.fillsBar(barStyle) &&
        (type == null || type == ItemType.series || type == ItemType.movie || type == ItemType.episode || type == ItemType.playlist)) {
      return _withHomeBar(context, item, barStyle);
    }
    return ArtworkBackground(
      child: Scaffold(
      backgroundColor: ArtworkBackground.pageColor(ref),
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: IgnorePointer(
          ignoring: !_barShown,
          child: AnimatedSlide(
            offset: _barShown ? Offset.zero : const Offset(0, -1),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: AppBar(
              backgroundColor: Colors.transparent,
              // Readable over any artwork: a dark round backing + shadow.
              leading: Navigator.canPop(context)
                  ? Padding(
                      padding: const EdgeInsets.all(6),
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
                        child: IconButton(
                          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                          color: Colors.white,
                          icon: const Icon(Icons.arrow_back, shadows: [Shadow(blurRadius: 6, color: Colors.black87)]),
                          onPressed: () => Navigator.maybePop(context),
                        ),
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ),
      body: HidesStatusBar(
        child: Stack(
          children: [
            Positioned.fill(
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: _onResize,
                child: NotificationListener<ScrollUpdateNotification>(
                  onNotification: _onScroll,
                  child: _page(item),
                ),
              ),
            ),
            ?_statusBand(statusBarHeight(context)),
          ],
        ),
      ),
      ),
    );
  }

  Widget _page(AsyncValue<BaseItem> item) {
    // Reloading keeps the page, and where it had scrolled to.
    if (item.hasValue) {
      return itemPages.build(
        context,
        (item: item.requireValue, seasonId: widget.seasonId),
        ref.watch(componentStyleProvider(Slots.itemPage)),
      );
    }
    return switch (item) {
      AsyncError(:final error) => Center(child: Text(error is JellyfinException ? error.message : "Couldn't load this")),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  void _refresh() {
    final id = widget.itemId;
    refreshWatchState(ref.invalidate);
    ref.invalidate(itemProvider(id));
    ref.invalidate(similarProvider(id));
    ref.invalidate(localTrailersProvider(id));
    ref.invalidate(seasonsProvider);
    ref.invalidate(episodesProvider);
  }

  Widget? _statusBand(double statusBar) {
    if (statusBar <= 0) return null;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: statusBar + 18,
      child: StatusBand(scrolled: _scrolled, goingDown: _goingDown),
    );
  }

  /// Home's bar over the page, with a Back button, and its tabs (along the
  /// bottom on a phone).
  Widget _withHomeBar(BuildContext context, AsyncValue<BaseItem> item, ComponentStyle barStyle) {
    final session = ref.watch(currentSessionProvider);
    final phone = context.layout.formFactor == FormFactor.phone;
    final tabs = (ref.watch(homeBarSettingsProvider).value ?? const HomeBarSettings()).tabs;
    final extras = homeTabExtras(context, ref, onRefresh: _refresh);
    // A playlist is none of the tabs.
    final tab = switch (item.value?.type) {
      ItemType.movie => HomeTab.movies,
      ItemType.playlist => null,
      _ => HomeTab.shows,
    };
    void onTab(HomeTab to) {
      ref.read(homeTabProvider.notifier).select(to);
      context.go('/');
    }

    final statusBar = statusBarHeight(context);
    final bar = HomeComponents.topBarActions.build(
      context,
      HomeTopBarData(
        tab: tab,
        onTab: onTab,
        tabs: tabs,
        extras: extras,
        serverName: session.serverName,
        host: session.baseUrl.host,
        title: Text(session.serverName),
        leading: Navigator.canPop(context) ? PillBackButton(onPressed: () => Navigator.maybePop(context)) : null,
        actions: homeActions(context, ref, onRefresh: _refresh),
        scrolled: _scrolled,
      ),
      barStyle,
    );
    return ArtworkBackground(
      child: Scaffold(
        backgroundColor: ArtworkBackground.pageColor(ref),
        bottomNavigationBar: phone && tabs.length + extras.length > 1 ? HomeBottomNav(tab: tab, onTab: onTab, tabs: tabs, extras: extras) : null,
        body: HidesStatusBar(
          child: Stack(
            children: [
              Positioned.fill(
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: _onResize,
                  child: NotificationListener<ScrollUpdateNotification>(
                    onNotification: _onScroll,
                    child: _page(item),
                  ),
                ),
              ),
              ?_statusBand(statusBar),
              Positioned(top: statusBar, left: 0, right: 0, child: bar),
            ],
          ),
        ),
      ),
    );
  }
}

/// A dark band behind the status bar, so what passes under stays out of the
/// clock's way: once the page has scrolled, and only while that bar is showing
/// (scrolling down hides it, and the band goes with it).
class StatusBand extends StatelessWidget {
  const StatusBand({super.key, required this.scrolled, required this.goingDown});

  final ValueListenable<double> scrolled;
  final ValueListenable<bool> goingDown;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ValueListenableBuilder<bool>(
          valueListenable: goingDown,
          builder: (context, down, child) => AnimatedOpacity(
            opacity: down ? 0 : 1,
            duration: const Duration(milliseconds: 180),
            child: child,
          ),
          child: ValueListenableBuilder<double>(
            valueListenable: scrolled,
            builder: (context, pixels, child) => Opacity(opacity: (pixels / 120).clamp(0.0, 1.0), child: child),
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.7, 1],
                  colors: [Color(0xF20C0D14), Color(0xE60C0D14), Color(0x000C0D14)],
                ),
              ),
            ),
          ),
        ),
      );
}

class _Details extends ConsumerWidget {
  const _Details({required this.item, this.seasonId});

  final BaseItem item;
  final String? seasonId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = context.layout;
    final size = MediaQuery.sizeOf(context);
    final headerHeight = (size.height * 0.55).clamp(280.0, 620.0);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        SizedBox(
          height: headerHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ItemImage(
                image: item.backdropImage ?? item.landscapeImage,
                maxWidth: size.width,
                alignment: Alignment.topCenter,
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Theme.of(context).scaffoldBackgroundColor],
                    stops: const [0.35, 1],
                  ),
                ),
              ),
              Positioned(
                left: layout.gutter,
                right: layout.gutter,
                bottom: 16,
                child: _TitleBlock(item: item),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: layout.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Actions(item: item),
              MalDetails(item: item),
              if (item.taglines.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  item.taglines.first,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontStyle: FontStyle.italic),
                ),
              ],
              if (item.overview case final overview? when overview.isNotEmpty) ...[
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Text(overview, style: Theme.of(context).textTheme.bodyLarge),
                ),
              ],
              if (item.genres.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [for (final g in item.genres) Chip(label: Text(g))]),
              ],
              if (item.studios.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(item.studios.join(', '), style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (item.type == ItemType.series) SeasonsAndEpisodes(series: item, initialSeasonId: seasonId),
        if (item.type == ItemType.boxSet)
          MediaRow(
            title: 'Items',
            items: ref.watch(_childrenProvider(item.id)),
            onItemPressed: (child) => openItem(context, child),
          ),
        if (item.type == ItemType.playlist)
          PlaylistScope(
            playlist: item,
            onRemoved: () => ref.invalidate(playlistItemsProvider(item.id)),
            child: MediaRow(
              title: 'Items',
              items: ref.watch(playlistItemsProvider(item.id)),
              onItemPressed: (child) => openItem(context, child),
            ),
          ),
        if (item.people.isNotEmpty) _CastRow(people: item.people),
        if (item.type != ItemType.episode)
          MediaRow(
            title: 'More like this',
            items: ref.watch(similarProvider(item.id)),
            onItemPressed: (other) => openItem(context, other),
          ),
        const SizedBox(height: 48),
      ],
    );
  }
}

final _childrenProvider = FutureProvider.autoDispose.family<List<BaseItem>, String>((ref, id) async {
  final page = await ref.watch(libraryApiProvider).getItems(ItemQuery(parentId: id, recursive: false), limit: 200);
  return page.items;
});

class _TitleBlock extends ConsumerWidget {
  const _TitleBlock({required this.item});

  final BaseItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final logo = item.logoImage;
    final meta = [
      ?item.episodeLabel,
      ?item.yearLabel,
      ?item.officialRating,
      if (item.runtime case final r? when item.type != ItemType.series) formatRuntime(r),
      if (item.communityRating case final r?) '★ ${r.toStringAsFixed(1)}',
      if (item.type == ItemType.series && item.status == 'Ended') 'Ended',
    ];
    final showsLogo = logo != null && item.type != ItemType.episode;
    // The MyAnimeList title in the chosen language (the server's otherwise).
    final title = preferredAnimeTitle(ref, item, item.name);
    final chosen =
        (ref.watch(animeSettingsProvider).value?.titleLanguage ?? TitleLanguage.server) != TitleLanguage.server;
    // Under the logo or title: with a title language chosen, that title
    // (under a logo, which is just artwork) and nothing else; otherwise the
    // server's original title as before.
    final secondLine = chosen
        ? (showsLogo ? title : null)
        : switch (item.originalTitle) {
            final o? when o.isNotEmpty && o != item.name => o,
            _ => null,
          };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.type == ItemType.episode && item.seriesName != null)
          TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => context.push('/item/${item.seriesId}'),
            // An episode's MAL titles are its show's.
            child: Text(title == item.name ? item.seriesName! : title, style: theme.textTheme.titleLarge),
          ),
        if (showsLogo)
          SizedBox(
            height: 100,
            width: 400,
            child: ItemImage(
              image: logo,
              maxWidth: 400,
              fit: BoxFit.contain,
              alignment: Alignment.bottomLeft,
              placeholder: Text(title, style: theme.textTheme.displaySmall),
            ),
          )
        else if (item.type == ItemType.episode)
          Text(preferredEpisodeTitle(ref, item, item.name), style: theme.textTheme.displaySmall)
        else
          Text(title, style: theme.textTheme.displaySmall),
        if (secondLine != null) Text(secondLine, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(meta.join('   ·   '), style: theme.textTheme.bodyLarge),
      ],
    );
  }
}

String formatRuntime(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

/// The second line under a page's logo or title: with a title language chosen,
/// that title (under a logo, which is just artwork) and nothing else; otherwise
/// the server's original title.
String? detailSecondLine(WidgetRef ref, BaseItem item, {required bool showsLogo}) {
  final title = preferredAnimeTitle(ref, item, item.name);
  final chosen = (ref.watch(animeSettingsProvider).value?.titleLanguage ?? TitleLanguage.server) != TitleLanguage.server;
  if (chosen) return showsLogo ? title : null;
  return switch (item.originalTitle) {
    final o? when o.isNotEmpty && o != item.name => o,
    _ => null,
  };
}

/// Watched and favorite for an item's page: shown at once, put back with a
/// message if the server refuses.
mixin ItemToggles<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  BaseItem get togglesItem;

  late UserItemData _toggleData = togglesItem.userData;
  String _toggleFor = '';
  bool _busy = false;

  /// The item's state, as last changed here.
  UserItemData get toggleData {
    if (_toggleFor != togglesItem.id) {
      _toggleFor = togglesItem.id;
      _toggleData = togglesItem.userData;
    }
    return _toggleData;
  }

  /// The server's newer state replaces what's shown.
  void syncToggles() => _toggleData = togglesItem.userData;

  Future<void> toggleItem({bool? played, bool? favorite, bool? watchlist}) async {
    if (_busy) return;
    final before = toggleData;
    setState(() {
      _busy = true;
      _toggleData = before.copyWith(played: played, isFavorite: favorite, likes: watchlist);
    });
    final api = ref.read(libraryApiProvider);
    try {
      if (played != null) await api.setPlayed(togglesItem.id, played);
      if (favorite != null) await api.setFavorite(togglesItem.id, favorite);
      if (watchlist != null) {
        await api.setWatchlisted(togglesItem.id, watchlist);
        ref.invalidate(watchlistProvider);
      }
      if (played != null) refreshWatchState(ref.invalidate);
      if (played != null && togglesItem.type == ItemType.episode) {
        unawaited(ref.read(malSyncServiceProvider).markedWatched(togglesItem, watched: played));
      }
    } on JellyfinException catch (e) {
      if (!mounted) return;
      setState(() => _toggleData = before);
      showToast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Play/resume, watched and favorite toggles.
class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.item});

  final BaseItem item;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> with ItemToggles {
  @override
  BaseItem get togglesItem => widget.item;

  UserItemData get _userData => toggleData;

  @override
  void didUpdateWidget(_Actions old) {
    super.didUpdateWidget(old);
    if (old.item != widget.item) syncToggles();
  }

  Future<void> _toggle({bool? played, bool? favorite}) => toggleItem(played: played, favorite: favorite);

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final resume = _userData.hasProgress ? ticksToDuration(_userData.playbackPositionTicks) : null;
    final action = item.type == ItemType.series ? seriesMainAction(ref, item.id) : null;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (item.type.isPlayable)
          FilledButton.icon(
            autofocus: true,
            onPressed: () => openItem(context, item, play: true),
            icon: const Icon(Icons.play_arrow),
            label: Text(resume == null ? 'Play' : 'Resume from ${formatPosition(resume)}'),
          ),
        if (item.type.isPlayable && resume != null)
          OutlinedButton.icon(
            onPressed: () => context.push('/play/${item.id}?fromStart=1'),
            icon: const Icon(Icons.replay),
            label: const Text('From start'),
          ),
        // (Only when there's one: even an empty child takes a gap in a Wrap.)
        if (action != null) _SeriesPlayButton(episode: action.episode, verb: action.verb),
        if (item.type.isPlayable || item.type == ItemType.series)
          OutlinedButton.icon(
            onPressed: () => _toggle(played: !_userData.played),
            icon: Icon(_userData.played ? Icons.check_circle : Icons.check_circle_outline),
            label: Text(switch ((item.type == ItemType.series, _userData.played)) {
              (true, true) => 'Series watched',
              (true, false) => 'Mark series watched',
              (false, true) => 'Watched',
              (false, false) => 'Mark watched',
            }),
          ),
        if (canWatchlist(item))
          IconButton.outlined(
            tooltip: _userData.likes ? 'Remove from watchlist' : 'Add to watchlist',
            onPressed: () => toggleItem(watchlist: !_userData.likes),
            icon: Icon(_userData.likes ? Icons.bookmark : Icons.bookmark_border),
          ),
        IconButton.outlined(
          tooltip: _userData.isFavorite ? 'Remove from favorites' : 'Add to favorites',
          onPressed: () => _toggle(favorite: !_userData.isFavorite),
          icon: Icon(
            _userData.isFavorite ? Icons.favorite : Icons.favorite_border,
            color: _userData.isFavorite ? Colors.redAccent : null,
          ),
        ),
        if (canDownload(widget.item)) DownloadButton(item: widget.item),
        if (canAddToPlaylist(item))
          OutlinedButton.icon(
            onPressed: () => showAddToPlaylist(context, [item]),
            icon: const Icon(Icons.playlist_add),
            label: const Text('Add to playlist'),
          ),
        // Seasons not on the server, through Seerr (#98).
        if (item.type == ItemType.series) SeriesRequestButton(series: item),
      ],
    );
  }
}

String formatPosition(Duration d) {
  final h = d.inHours;
  final m = (d.inMinutes % 60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// A show's main button, see [seriesMainAction].
class _SeriesPlayButton extends StatelessWidget {
  const _SeriesPlayButton({required this.episode, required this.verb});

  final BaseItem episode;
  final String verb;

  @override
  Widget build(BuildContext context) {
    final data = episode.userData;
    final at = data.hasProgress ? ' · ${formatPosition(ticksToDuration(data.playbackPositionTicks))}' : '';
    return FilledButton.icon(
      autofocus: true,
      onPressed: () => openItem(context, episode, play: true),
      icon: const Icon(Icons.play_arrow),
      label: Text('$verb ${episode.episodeLabel ?? episode.name}$at'),
    );
  }
}

/// A series' seasons and episodes, with choosing several for a batch action.
class SeasonsAndEpisodes extends ConsumerStatefulWidget {
  const SeasonsAndEpisodes({super.key, required this.series, this.initialSeasonId, this.depth = false, this.seasonLabel});

  final BaseItem series;
  final String? initialSeasonId;

  /// Drawn as on Depth's page.
  final bool depth;

  /// Told the season picked: "S1", "SP".
  final ValueNotifier<String?>? seasonLabel;

  @override
  ConsumerState<SeasonsAndEpisodes> createState() => _SeasonsAndEpisodesState();
}

class _SeasonsAndEpisodesState extends ConsumerState<SeasonsAndEpisodes> with AutomaticKeepAliveClientMixin {
  String? _seasonId;

  // The page builds lazily: a selection survives scrolling far away.
  @override
  bool get wantKeepAlive => true;

  /// Episodes picked for a batch action (download, watched).
  final _selection = Selection();

  @override
  void initState() {
    super.initState();
    _seasonId = widget.initialSeasonId;
    _selection.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  void setSeason(String id) => setState(() => _seasonId = id);

  List<BaseItem> _chosen(List<BaseItem> episodes) => [
    for (final e in episodes)
      if (_selection.contains(e.id)) e,
  ];

  Future<void> _downloadChosen(List<BaseItem> episodes) async {
    final chosen = _chosen(episodes);
    _selection.clear();
    for (final e in chosen) {
      await startDownload(context, e);
      if (!mounted) return;
    }
  }

  Future<void> _deleteChosenDownloads(List<BaseItem> episodes) async {
    final chosen = _chosen(episodes);
    _selection.clear();
    final downloads = ref.read(downloadsProvider.notifier);
    for (final e in chosen) {
      await downloads.remove(e.id);
    }
    showToast('Deleted ${chosen.length} download${chosen.length == 1 ? '' : 's'}');
  }

  Future<void> _markChosen(List<BaseItem> episodes, {required bool watched}) async {
    final chosen = _chosen(episodes);
    _selection.clear();
    final api = ref.read(libraryApiProvider);
    final mal = ref.read(malSyncServiceProvider);
    try {
      for (final e in chosen) {
        await api.setPlayed(e.id, watched);
        // MyAnimeList follows, as for one episode.
        unawaited(mal.markedWatched(e, watched: watched));
      }
      showToast('Marked ${chosen.length} episode${chosen.length == 1 ? '' : 's'} ${watched ? 'watched' : 'unwatched'}');
    } on JellyfinException catch (e) {
      showToast(e.message);
    }
    refreshWatchState(ref.invalidate);
  }

  /// Long press, right-click (a popup at [at]) or the menu key on an
  /// episode.
  void _episodeMenu(BaseItem episode, List<BaseItem> episodes, {Offset? at}) {
    final ids = [for (final e in episodes) e.id];
    final selected = _selection.contains(episode.id);
    final played = episode.userData.played;
    showActionMenu(
      context,
      at: at,
      title: episode.name,
      subtitle: episode.episodeLabel,
      entries: [
        MenuEntry(
          icon: Icons.check_box_outlined,
          label: selected ? 'Deselect' : 'Select',
          onSelected: () => _selection.toggle(episode.id),
        ),
        MenuEntry(
          icon: Icons.playlist_add_check,
          label: 'Select from here to the end',
          onSelected: () => _selection.setAll(ids.sublist(ids.indexOf(episode.id))),
        ),
        MenuEntry(icon: Icons.play_arrow, label: 'Play', onSelected: () => openItem(context, episode, play: true)),
        MenuEntry(icon: Icons.info_outline, label: 'Details', onSelected: () => openItem(context, episode)),
        MenuEntry(icon: Icons.playlist_add, label: 'Add to playlist', onSelected: () => showAddToPlaylist(context, [episode])),
        MenuEntry(
          icon: played ? Icons.remove_done : Icons.check,
          label: played ? 'Mark unwatched' : 'Mark watched',
          onSelected: () {
            _selection
              ..clear()
              ..toggle(episode.id);
            _markChosen(episodes, watched: !played);
          },
        ),
        ?downloadMenuEntry(context, episode),
      ],
    );
  }

  /// The floating bar's actions while selecting.
  List<Widget> _selectionActions(List<BaseItem> episodes) {
    final chosen = _chosen(episodes);
    final downloads = ref.watch(downloadsProvider).value;
    final anyDownloaded = chosen.any((e) => downloads?[e.id] != null);
    final anyNot = chosen.any((e) => downloads?[e.id] == null);
    return [
      TextButton.icon(
        onPressed: () => _selection.setAll([for (final e in episodes) e.id]),
        icon: const Icon(Icons.select_all),
        label: const Text('Select all'),
      ),
      if (anyNot)
        TextButton.icon(
          onPressed: () => _downloadChosen(episodes),
          icon: const Icon(Icons.download_outlined),
          label: const Text('Download'),
        ),
      if (anyDownloaded)
        TextButton.icon(
          onPressed: () => _deleteChosenDownloads(episodes),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Delete download'),
        ),
      TextButton.icon(
        onPressed: () => showAddToPlaylist(context, chosen),
        icon: const Icon(Icons.playlist_add),
        label: const Text('Add to playlist'),
      ),
      TextButton.icon(
        onPressed: () => _markChosen(episodes, watched: true),
        icon: const Icon(Icons.check_circle_outline),
        label: const Text('Mark watched'),
      ),
      TextButton.icon(
        onPressed: () => _markChosen(episodes, watched: false),
        icon: const Icon(Icons.remove_done),
        label: const Text('Mark unwatched'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final layout = context.layout;
    final seasons = ref.watch(seasonsProvider(widget.series.id)).value;
    if (seasons == null || seasons.isEmpty) return const SizedBox.shrink();

    // Default to the first season with unwatched episodes, skipping specials.
    final selected = seasons.firstWhere(
      (s) => s.id == _seasonId,
      orElse: () =>
          seasons.firstWhere((s) => !s.userData.played && (s.indexNumber ?? 0) > 0, orElse: () => seasons.first),
    );
    final episodes = ref.watch(episodesProvider((seriesId: widget.series.id, seasonId: selected.id)));
    if (widget.depth) return _depth(seasons, selected, episodes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(layout.gutter, 32, layout.gutter, 8),
          child: SideScroll(
            builder: (controller) => SingleChildScrollView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final season in seasons)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        // Watched seasons carry a check; the selected one is
                        // shown by its fill (a selection tick would read as
                        // "watched").
                        showCheckmark: false,
                        avatar: season.userData.played
                            ? Icon(
                                Icons.check_circle,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                                semanticLabel: 'Watched',
                              )
                            : null,
                        label: Text(season.name),
                        tooltip: season.userData.played ? '${season.name} · watched' : null,
                        selected: season.id == selected.id,
                        onSelected: (_) => setState(() => _seasonId = season.id),
                      ),
                    ),
                  SeasonsNotOnServer(
                    series: widget.series,
                    onServer: {for (final s in seasons) ?s.indexNumber},
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: layout.gutter),
          // Later seasons are usually their own MAL entry.
          child: MalDetails(
            key: ValueKey('mal-${selected.id}'),
            item: selected,
            label: selected.name,
            unlessSameAs: widget.series,
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: layout.gutter),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _WatchedToggle(
                key: ValueKey(selected.id),
                item: selected,
                played: selected.userData.played,
                builder: (played, onPressed) => TextButton.icon(
                  onPressed: onPressed,
                  icon: Icon(played ? Icons.check_circle : Icons.check_circle_outline),
                  label: Text(played ? 'Mark season unwatched' : 'Mark season watched'),
                ),
              ),
              DownloadButton(key: ValueKey('dl-${selected.id}'), item: selected),
            ],
          ),
        ),
        if (episodes case AsyncData(:final value))
          Padding(
            padding: EdgeInsets.symmetric(horizontal: layout.gutter),
            child: MissingEpisodesNote(
              series: widget.series,
              seasonNumber: selected.indexNumber,
              onServer: value.where((e) => !e.isVirtual).length,
            ),
          ),
        switch (episodes) {
          AsyncData(:final value) => SelectionShortcuts(
            selection: _selection,
            selectAll: () => _selection.setAll([for (final e in value) e.id]),
            child: FloatingSelectionBar(
              selection: _selection,
              label: '${_chosen(value).length} selected',
              actions: _selectionActions(value),
              alwaysShown: ref.watch(isTvProvider),
              child: Column(
                children: [
                  for (final episode in value)
                    _WatchedToggle(
                      key: ValueKey(episode.id),
                      item: episode,
                      played: episode.userData.played,
                      builder: (played, onPressed) => _EpisodeTile(
                        episode: episode,
                        played: played,
                        onWatched: onPressed,
                        gutter: layout.gutter,
                        selection: _selection,
                        order: [for (final e in value) e.id],
                        onMenu: (at) => _episodeMenu(episode, value, at: at),
                      ),
                    ),
                  // Room for the floating bar under the last episode.
                  if (_selection.active) const SizedBox(height: 88),
                ],
              ),
            ),
          ),
          AsyncError(:final error) => Padding(
            padding: EdgeInsets.all(layout.gutter),
            child: Text(error is JellyfinException ? error.message : "Couldn't load the episodes"),
          ),
          _ => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        },
      ],
    );
  }
}

extension on _SeasonsAndEpisodesState {
  /// Depth's page: a heading with the season's actions, tabs and how much is
  /// watched, and its rows. What choosing several does is the same.
  Widget _depth(List<BaseItem> seasons, BaseItem selected, AsyncValue<List<BaseItem>> episodes) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final label = selected.indexNumber == 0 ? 'SP' : 'S${selected.indexNumber ?? ''}';
    if (widget.seasonLabel case final notifier? when notifier.value != label) {
      WidgetsBinding.instance.addPostFrameCallback((_) => notifier.value = label);
    }
    final list = episodes.value;
    final count = list?.where((e) => !e.isVirtual).length;
    final kick = [selected.name, if (count != null) '$count episode${count == 1 ? '' : 's'}'].join(' · ');
    final current = ref.watch(nextUpForSeriesProvider(widget.series.id)).value?.id;
    final actions = GhostTheme(
      height: phone ? 38 : 46,
      child: Wrap(
        spacing: phone ? 8 : 10,
        runSpacing: 8,
        children: [
          _WatchedToggle(
            key: ValueKey(selected.id),
            item: selected,
            played: selected.userData.played,
            builder: (played, onPressed) => GhostButton(
              icon: played ? Icons.check_circle : Icons.check_circle_outline,
              label: played ? 'Mark season unwatched' : 'Mark season watched',
              on: played,
              height: phone ? 38 : 46,
              onPressed: onPressed,
            ),
          ),
          DownloadButton(key: ValueKey('dl-${selected.id}'), item: selected),
        ],
      ),
    );
    final heading = SectionHeading(kick: kick, title: 'Episodes');
    final tabs = SeasonTabs(
      seasons: seasons,
      selected: selected,
      onPick: (season) => setSeason(season.id),
      trailing: SeasonsNotOnServer(series: widget.series, onServer: {for (final s in seasons) ?s.indexNumber}),
    );
    final watched = Text(
      list == null ? '' : SeasonStrip.countOf(list),
      style: TextStyle(color: const Color(0xFF9AA0B2), fontSize: phone ? 11 : 13, fontWeight: FontWeight.w700),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (phone) ...[
          heading,
          const SizedBox(height: 12),
          tabs,
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: SeasonStrip(episodes: list ?? const [], height: 6)),
              const SizedBox(width: 10),
              watched,
            ],
          ),
          const SizedBox(height: 10),
          actions,
        ] else ...[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 18,
            runSpacing: 12,
            children: [heading, actions],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Flexible(flex: 3, child: tabs),
              const SizedBox(width: 18),
              Expanded(flex: 2, child: SeasonStrip(episodes: list ?? const [])),
              const SizedBox(width: 18),
              watched,
            ],
          ),
        ],
        MalDetails(key: ValueKey('mal-${selected.id}'), item: selected, label: selected.name, unlessSameAs: widget.series),
        if (list != null)
          MissingEpisodesNote(series: widget.series, seasonNumber: selected.indexNumber, onServer: list.where((e) => !e.isVirtual).length),
        SizedBox(height: phone ? 10 : 18),
        switch (episodes) {
          AsyncData(:final value) => SelectionShortcuts(
            selection: _selection,
            selectAll: () => _selection.setAll([for (final e in value) e.id]),
            child: FloatingSelectionBar(
              selection: _selection,
              label: '${_chosen(value).length} selected',
              actions: _selectionActions(value),
              alwaysShown: ref.watch(isTvProvider),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, episode) in value.indexed)
                    _WatchedToggle(
                      key: ValueKey('${selected.id}-${episode.id}'),
                      item: episode,
                      played: episode.userData.played,
                      builder: (played, onPressed) => DepthEpisodeRow(
                        episode: episode,
                        index: i,
                        current: episode.id == current,
                        selected: _selection.contains(episode.id),
                        played: played,
                        onOpen: () {
                          if (!_selection.tap([for (final e in value) e.id], episode.id)) openEpisode(context, episode);
                        },
                        onPlay: () => openItem(context, episode, play: true),
                        onThumb: () {
                          if (!_selection.tap([for (final e in value) e.id], episode.id)) openItem(context, episode, play: true);
                        },
                        onHold: () => _selection.active ? _episodeMenu(episode, value) : _selection.toggle(episode.id),
                        onMenu: (at) => _episodeMenu(episode, value, at: at),
                        onWatched: onPressed,
                        swipes: !_selection.active,
                        watchedButton: RowIconButton(
                          icon: played ? Icons.check_circle : Icons.check_circle_outline,
                          tooltip: played ? 'Mark unwatched' : 'Mark watched',
                          on: played,
                          onPressed: onPressed,
                          small: phone,
                        ),
                      ),
                    ),
                  if (_selection.active) const SizedBox(height: 88),
                ],
              ),
            ),
          ),
          AsyncError(:final error) => Padding(padding: const EdgeInsets.all(16), child: Text(error is JellyfinException ? error.message : "Couldn't load the episodes")),
          _ => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        },
      ],
    );
  }
}

/// Marks an item (episode, season) watched or unwatched on the server.
/// Shows the new state at once, reverts with a message if the server
/// refuses, then refreshes watch state everywhere (progress, home rows).
class _WatchedToggle extends ConsumerStatefulWidget {
  const _WatchedToggle({super.key, required this.item, required this.played, required this.builder});

  final BaseItem item;
  final bool played;
  final Widget Function(bool played, VoidCallback? onPressed) builder;

  @override
  ConsumerState<_WatchedToggle> createState() => _WatchedToggleState();
}

class _WatchedToggleState extends ConsumerState<_WatchedToggle> {
  late bool _played = widget.played;
  bool _busy = false;

  @override
  void didUpdateWidget(_WatchedToggle old) {
    super.didUpdateWidget(old);
    if (!_busy && old.played != widget.played) _played = widget.played;
  }

  Future<void> _toggle() async {
    final target = !_played;
    setState(() {
      _busy = true;
      _played = target;
    });
    try {
      await ref.read(libraryApiProvider).setPlayed(widget.item.id, target);
      refreshWatchState(ref.invalidate);
      // MyAnimeList follows: forward when watched, back when unwatched.
      unawaited(ref.read(malSyncServiceProvider).markedWatched(widget.item, watched: target));
    } on JellyfinException catch (e) {
      if (!mounted) return;
      setState(() => _played = !target);
      showToast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(_played, _busy ? null : _toggle);
}

class _EpisodeTile extends StatefulWidget {
  const _EpisodeTile({
    required this.episode,
    required this.played,
    required this.onWatched,
    required this.gutter,
    required this.selection,
    required this.order,
    required this.onMenu,
  });

  final BaseItem episode;

  /// Watched, as just marked.
  final bool played;
  final VoidCallback? onWatched;
  final double gutter;
  final Selection selection;

  /// The season's episode ids in order, for Shift+click ranges.
  final List<String> order;

  /// The episode's menu: at a point (right-click), else as a sheet.
  final void Function(Offset? at) onMenu;

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final gutter = widget.gutter;
    final selection = widget.selection;
    final selected = selection.contains(episode.id);
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final thumbWidth = narrow ? 140.0 : 240.0;
    final number = episode.indexNumber;

    return EpisodeSwipe(
      episode: episode,
      played: widget.played,
      onWatched: widget.onWatched,
      enabled: !selection.active,
      child: CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.contextMenu): () => widget.onMenu(null)},
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: EdgeInsets.symmetric(horizontal: selected ? gutter / 2 : 0),
        decoration: selectedRowDecoration(context, selected: selected),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              if (!selection.tap(widget.order, episode.id)) openItem(context, episode, play: true);
            },
            // Long press selects (and starts selecting); while selecting, the
            // menu (Details, Select from here to the end) without right-click.
            onLongPress: () => selection.active ? widget.onMenu(null) : selection.toggle(episode.id),
            onSecondaryTapUp: (d) => widget.onMenu(d.globalPosition),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: selected ? gutter / 2 : gutter, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: thumbWidth,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ItemImage(image: episode.landscapeImage, maxWidth: thumbWidth),
                            if (episode.userData.hasProgress && episode.userData.playedPercentage != null)
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: LinearProgressIndicator(
                                  value: episode.userData.playedPercentage! / 100,
                                  minHeight: 3,
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
                        Consumer(
                          builder: (context, ref, _) {
                            final name = preferredEpisodeTitle(ref, episode, episode.name);
                            final title = Text(
                              number == null ? name : '$number. $name',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            );
                            // The row plays; its title opens the episode. Not on
                            // Android, where the title is most of what's left to tap.
                            if (Platform.isAndroid) return title;
                            return MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () {
                                  if (!selection.tap(widget.order, episode.id)) openEpisode(context, episode);
                                },
                                child: title,
                              ),
                            );
                          },
                        ),
                        Wrap(
                          spacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (episode.runtime case final r?) Text(formatRuntime(r), style: theme.textTheme.bodySmall),
                            MalEpisodeScore(episode: episode),
                          ],
                        ),
                        if (episode.overview case final o? when !narrow) ...[
                          const SizedBox(height: 4),
                          Text(
                            o,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Compact where room is short, so the title keeps its share.
                  IconButtonTheme(
                    data: IconButtonThemeData(style: narrow ? IconButton.styleFrom(visualDensity: VisualDensity.compact) : null),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                      EpisodeDownloadButton(episode: episode),
                      IconButton(
                        tooltip: widget.played ? 'Mark unwatched' : 'Mark watched',
                        onPressed: widget.onWatched,
                        icon: Icon(
                          widget.played ? Icons.check_circle : Icons.check_circle_outline,
                          color: widget.played ? theme.colorScheme.primary : null,
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
      ),
      ),
    );
  }
}

class _CastRow extends ConsumerWidget {
  const _CastRow({required this.people});

  final List<PersonInfo> people;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = context.layout;
    final width = layout.posterWidth * 0.8;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(layout.gutter, 32, layout.gutter, 8),
          child: Text('Cast & crew', style: theme.textTheme.titleLarge),
        ),
        SizedBox(
          height: width / CardShape.poster.aspectRatio + 56,
          child: SideScroll(
            builder: (controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: layout.gutter),
              itemCount: people.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final person = people[i];
                return SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: CardShape.poster.aspectRatio,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: ItemImage(
                            image: person.primaryImageTag == null
                                ? null
                                : ImageRef(person.id, 'Primary', person.primaryImageTag!),
                            maxWidth: width,
                            placeholder: const ColoredBox(color: Colors.white10, child: Icon(Icons.person, size: 48)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(person.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        person.role?.isNotEmpty == true ? person.role! : person.type ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
