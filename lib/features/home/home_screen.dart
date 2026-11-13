import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'recommendations.dart';
import '../settings/keybindings.dart';
import '../../app/toast.dart';
import '../../app/layout.dart';
import '../../app/providers.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../seerr/seerr_health.dart';
import '../seerr/seerr_providers.dart';
import '../seerr/widgets/seerr_widgets.dart';
import '../settings/series_tracks.dart';
import '../anime/mal_account.dart';
import '../../app/smooth_wheel.dart';
import '../library/library_providers.dart';
import '../library/navigation.dart';
import '../library/widgets/card_actions.dart';
import '../library/widgets/media_card.dart';
import '../library/widgets/media_row.dart';
import '../settings/playback_settings.dart';
import '../downloads/downloads.dart';
import 'home_layout.dart';
import 'more_for_you.dart';
import '../../app/backdrop.dart';
import 'home_actions.dart';
import 'home_components.dart';
import '../../theme/components.dart';
import 'home_header.dart';
import 'home_header_settings.dart';
import 'home_tabs.dart';
import 'depth/tab_nav.dart';
import 'this_week.dart';

/// Reloads everything on Home: the Jellyfin rows, the Seerr rows (trying
/// Seerr again if it was unreachable), and More for you. Completes once the
/// libraries load; throws if they can't.
Future<void> refreshHome(WidgetRef ref) async {
    ref.invalidate(viewsProvider);
    ref.invalidate(libraryBackdropsProvider);
    ref.invalidate(homeGenresProvider);
    refreshWatchState(ref.invalidate);
    ref.invalidate(seerrRowProvider);
    ref.invalidate(seerrHomeRowProvider);
    ref.invalidate(jellyfinRowProvider);
    ref.invalidate(tasteProfileProvider);
    ref.invalidate(moreForYouIdeasProvider);
    ref.invalidate(moreLibraryIdeaProvider);
    ref.invalidate(headerFeaturedProvider);
    ref.invalidate(thisWeekProvider);
    ref.read(homeTabRefreshProvider.notifier).bump();
    await ref.read(viewsProvider.future);
}

/// Signed-in landing screen: continue watching, next up, libraries, and
/// recently added per library.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _refresh(WidgetRef ref) => refreshHome(ref);

  /// One home row; Seerr rows only while signed in to Seerr.
  Widget _row(
    BuildContext context,
    WidgetRef ref,
    HomeRow row, {
    required AsyncValue<List<BaseItem>> views,
    required bool seerrSignedIn,
  }) =>
      // Each in the active theme's style for its kind of row (Classic:
      // the rows the app has always had).
      switch (row) {
        BuiltInRow(kind: BuiltInKind.continueWatching) || BuiltInRow(kind: BuiltInKind.nextUp) => libraryRow(
            context,
            ref,
            row.kind == BuiltInKind.continueWatching ? Slots.continueWatching : Slots.nextUp,
            LibraryRowData(
              title: row.title,
              items: ref.watch(row.kind == BuiltInKind.continueWatching ? resumeProvider : visibleNextUpProvider),
              shape: CardShape.landscape,
              cardRow: row.kind == BuiltInKind.continueWatching ? CardRow.continueWatching : CardRow.nextUp,
              // Artwork plays; the caption opens the show or the episode.
              onItemPressed: (item) => openItem(context, item, play: true),
              onItemTitlePressed: (item) => openSeries(context, item),
              onItemSubtitlePressed: (item) => openEpisode(context, item),
            ),
          ),
        BuiltInRow(kind: BuiltInKind.genres) => genreRow(
            context,
            ref,
            GenreRowData(
              title: row.title,
              genres: ref.watch(homeGenresProvider),
              onGenrePressed: (genre) => context.push('/genre/${Uri.encodeComponent(genre)}'),
            ),
          ),
        BuiltInRow(kind: BuiltInKind.libraries) => libraryRow(
            context,
            ref,
            Slots.libraries,
            LibraryRowData(
              title: row.title,
              items: views,
              shape: CardShape.landscape,
              onItemPressed: (item) => openItem(context, item),
            ),
          ),
        BuiltInRow(kind: BuiltInKind.recentlyAdded, :final libraryId?) => libraryRow(
            context,
            ref,
            Slots.recentlyAdded,
            LibraryRowData(
              title: row.title,
              items: ref.watch(latestProvider(libraryId)),
              onItemPressed: (item) => openItem(context, item),
              onTitlePressed: () => context.push('/library/$libraryId'),
            ),
          ),
        BuiltInRow(kind: BuiltInKind.recentlyAdded) => const SizedBox.shrink(),
        BuiltInRow(kind: BuiltInKind.thisWeek) => WeekRefresher(
            child: weekRow(
              context,
              ref,
              WeekRowData(title: row.title, week: ref.watch(thisWeekProvider)),
            ),
          ),
        BuiltInRow(:final kind) => !seerrSignedIn
            ? const SizedBox.shrink()
            : seerrRow(
                context,
                ref,
                SeerrRowData(
                  title: row.title,
                  items: ref.watch(seerrRowProvider(switch (kind) {
                    BuiltInKind.seerrTrending => SeerrRow.trending,
                    BuiltInKind.seerrPopularAnime => SeerrRow.popularAnime,
                    BuiltInKind.seerrSeasonalAnime => SeerrRow.seasonalAnime,
                    _ => SeerrRow.upcomingAnime,
                  })),
                ),
              ),
        JellyfinHomeRow() => libraryRow(
            context,
            ref,
            Slots.libraryRow,
            LibraryRowData(
              title: row.title,
              items: ref.watch(jellyfinRowProvider(row)),
              shape: row.landscape ? CardShape.landscape : CardShape.poster,
              onItemPressed: (item) => openItem(context, item),
              look: row.look.name,
            ),
          ),
        SeerrHomeRow() => !seerrSignedIn
            ? const SizedBox.shrink()
            : seerrRow(
                context,
                ref,
                SeerrRowData(
                  title: seerrRowTitle(ref, row),
                  subtitle: seerrRowSubtitle(ref, row),
                  items: ref.watch(seerrHomeRowProvider(row)),
                ),
              ),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(currentSessionProvider);
    final views = ref.watch(viewsProvider);
    final seerr = ref.watch(seerrAccountProvider).value;
    // "X is now available" (or its first episodes) when a Seerr request
    // lands on the server.
    ref.listen(seerrAvailabilityProvider, (previous, next) {
      // A rebuild hands the last alert over again; show each one once.
      if (next case AsyncData(:final value) when !identical(value, previous?.value)) {
        showToast(
          value.message,
          actionLabel: 'Open',
          onAction: () => openSeerrMedia(context, value.media),
          duration: const Duration(seconds: 10),
        );
      }
    });
    // Loaded early so the player has per-show track choices on first open.
    ref.watch(seriesTracksProvider);
    // Send MyAnimeList updates queued while offline (once per start).
    ref.watch(malStartupSyncProvider);
    // Downloads: resume queued ones, send progress watched offline, and
    // have local copies ready for the player.
    ref.watch(downloadsProvider);
    // Warm up so the player has the user's preferences on first open.
    ref.watch(playbackSettingsProvider);
    final layout = ref.watch(homeLayoutProvider);

    final bindings = ref.watch(keybindingsProvider).value ?? Keybindings.defaults;
    // The header (#100): the top bar sits see-through over it.
    final header = ref.watch(homeHeaderSettingsProvider).value?.enabled ?? false;
    final barStyle = ref.watch(componentStyleProvider(Slots.homeTopBar));
    // A theme's bar that draws itself (Depth's pills) floats over the page.
    final ownBar = HomeComponents.fillsBar(barStyle);
    // Tabs in every theme: in the bar, along the bottom on a phone. One taken
    // off the bar while showing goes back to Home.
    final tabs = (ref.watch(homeBarSettingsProvider).value ?? const HomeBarSettings()).tabs;
    final chosen = ref.watch(homeTabProvider);
    final tab = tabs.contains(chosen) ? chosen : HomeTab.home;
    final phone = context.layout.formFactor == FormFactor.phone;
    final overHome = header && tab == HomeTab.home;
    final extras = homeTabExtras(context, ref, onRefresh: () => _refresh(ref));
    final tabCount = tabs.length + extras.length;
    void onTab(HomeTab to) => ref.read(homeTabProvider.notifier).select(to);
    final barData = HomeTopBarData(
      tab: tab,
      onTab: onTab,
      tabs: tabs,
      extras: extras,
      serverName: session.serverName,
      host: session.baseUrl.host,
      title: _ServerTitle(name: session.serverName, host: session.baseUrl.host),
      actions: homeActions(context, ref, refreshShortcut: 'F5', onRefresh: () => _refresh(ref)),
    );
    // Refresh Home's key(s) (Settings > Keyboard shortcuts): F5, Ctrl+R.
    // Appearance > Background > Show artwork: behind the page.
    // Read here, as Home builds, not in the wheel's builder below.
    // No answer at all from the server: said once, not on every row.
    final serverDown = switch (views.error) {
      JellyfinException(statusCode: null, untrustedCertificate: false) => true,
      _ => false,
    };
    final sections = <Widget>[
            if (serverDown) _ServerDown(onRetry: () => _refresh(ref)),
            if (header) HomeComponents.hero.build(context, null, ref.watch(componentStyleProvider(Slots.homeHero))),
            if (seerr != null && !ref.watch(seerrReachableProvider)) const _SeerrDown(),
            // The rows in the user's order (Settings > Home); the old
            // fixed page until it's edited.
            for (final row in (layout.value ?? const <HomeRow>[]).where((r) => r.visible))
              homeSection(context, ref, _row(context, ref, row, views: views, seerrSignedIn: seerr != null)),
            // Then, if on: endless suggestions from what the user watches.
            for (final section in moreForYouSection(context, ref)) homeSection(context, ref, section),
    ];
    final homePage = RowErrors(
        hide: serverDown,
        onRetry: () => _refresh(ref),
        child: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: (n) {
            if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
              HomeComponents.scrolled.value = n.metrics.pixels;
            }
            return false;
          },
          child: SmoothWheel(
          builder: (_, wheel) => ListView(
          controller: wheel,
          // Under a floating bar without the header: start below the bar.
          padding: EdgeInsets.only(
            top: ownBar && !header
                ? MediaQuery.paddingOf(context).top + (context.layout.formFactor == FormFactor.phone ? 64 : 80)
                : 0,
            bottom: 48,
          ),
          children: [
            ...sections,
          ],
        ),
        ),
        ),
        ),
      );
    return ArtworkBackground(
      // Back from Movies or Shows: to Home, not out of the app.
      child: PopScope(
      canPop: tab == HomeTab.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onTab(HomeTab.home);
      },
      child: CallbackShortcuts(
      bindings: {for (final key in bindings.keysFor(PlayerAction.refreshHome)) key: () => _refresh(ref)},
      child: Focus(
        // Keys reach Home from the start on desktop; on a TV the remote's
        // focus belongs to the first card.
        autofocus: !ref.watch(isTvProvider),
        skipTraversal: true,
        child: Scaffold(
      backgroundColor: ArtworkBackground.pageColor(ref),
      extendBodyBehindAppBar: overHome || ownBar,
      appBar: ownBar
          ? PreferredSize(
              preferredSize: Size.fromHeight(context.layout.formFactor == FormFactor.phone ? 64 : 80),
              child: SafeArea(bottom: false, child: HomeComponents.topBarActions.build(context, barData, barStyle)),
            )
          : _OverHeaderBar(
        header: overHome,
        wide: context.layout.formFactor == FormFactor.desktop,
        builder: (overHeader) => AppBar(
        // Bigger on a PC (they looked small on a large window).
        toolbarHeight: context.layout.formFactor == FormFactor.desktop ? 64 : null,
        actionsIconTheme: context.layout.formFactor == FormFactor.desktop ? const IconThemeData(size: 27) : null,
        actionsPadding: context.layout.formFactor == FormFactor.desktop ? const EdgeInsets.only(right: 12) : null,
        backgroundColor: overHeader ? Colors.transparent : ArtworkBackground.pageColor(ref),
        foregroundColor: overHeader ? Colors.white : null,
        surfaceTintColor: overHeader ? Colors.transparent : null,
        // The tabs, in the true centre of the bar.
        flexibleSpace: phone || tabCount < 2
            ? null
            : SafeArea(
                child: Center(
                  child: ClassicTabBar(tabs: tabs, extras: extras, tab: tab, onTab: onTab, overArtwork: overHeader),
                ),
              ),
        title: _ServerTitle(name: session.serverName, host: session.baseUrl.host),
        actions: [
          HomeComponents.topBarActions.build(context, barData, barStyle),
        ],
      ),
      ),
      bottomNavigationBar: phone && tabCount > 1 ? HomeBottomNav(tab: tab, onTab: onTab, tabs: tabs, extras: extras) : null,
      body: HomeTabPages(tab: tab, home: homePage),
    ),
      ),
      ),
      ),
    );
  }
}

/// The server can't be reached: Home sends the user to the connect screen,
/// still signed in, to try it again or pick another server. Only while Home
/// is the page in front; under another page it's one line at the top that
/// keeps trying, so Home fills in by itself once it can.
class _ServerDown extends StatefulWidget {
  const _ServerDown({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  State<_ServerDown> createState() => _ServerDownState();
}

class _ServerDownState extends State<_ServerDown> {
  late final Timer _timer = Timer.periodic(const Duration(seconds: 30), (_) => _retry());
  bool _sent = false;

  void _retry() => unawaited(widget.onRetry().catchError((Object _) {}));

  @override
  void initState() {
    super.initState();
    _timer;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sent || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _sent = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final container = ProviderScope.containerOf(context, listen: false);
      final session = container.read(sessionControllerProvider).value;
      if (session == null) return;
      container.read(loginFlowProvider.notifier).serverUnreachable(session);
      GoRouter.of(context).go('/connect');
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.fromLTRB(context.layout.gutter, top + 12, context.layout.gutter, 0),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "Can't reach your server right now. Home fills in by itself when it can.",
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton(onPressed: _retry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// One line at the top of Home while Seerr can't be reached; its rows retry
/// by themselves and come back with it.
class _SeerrDown extends StatelessWidget {
  const _SeerrDown();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(context.layout.gutter, 12, context.layout.gutter, 0),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "Seerr isn't reachable right now. Its rows come back by themselves when it is.",
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// The connected server in the top bar: a server icon before its name (it
/// was read as the user's name), its address on hover / long press, and
/// Settings > Account & server on a tap.
class _ServerTitle extends StatelessWidget {
  const _ServerTitle({required this.name, required this.host});

  final String name;
  final String host;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Connected to $name · $host',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => context.push('/settings?section=account'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.dns_outlined, size: 20, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Home's top bar: see-through while over the header (#100), solid once the
/// page has scrolled past it.
class _OverHeaderBar extends StatelessWidget implements PreferredSizeWidget {
  const _OverHeaderBar({required this.header, required this.wide, required this.builder});

  final bool header;

  /// Taller on a PC, where the bar's icons are bigger.
  final bool wide;
  final Widget Function(bool overHeader) builder;

  @override
  Size get preferredSize => Size.fromHeight(wide ? 64 : kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    if (!header) return builder(false);
    final until = MediaQuery.sizeOf(context).height * 0.45;
    return ValueListenableBuilder<double>(
      valueListenable: HomeComponents.scrolled,
      builder: (context, pixels, _) => builder(pixels < until),
    );
  }
}
