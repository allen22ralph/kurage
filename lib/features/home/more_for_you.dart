import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/layout.dart';
import '../../app/providers.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/library_api.dart';
import '../../core/seerr/seerr_api.dart';
import '../../core/seerr/seerr_discover.dart';
import '../../core/seerr/seerr_recommend.dart';
import '../library/library_providers.dart';
import '../library/navigation.dart';
import '../library/widgets/media_row.dart';
import '../library/widgets/side_scroll.dart';
import '../seerr/seerr_health.dart';
import '../seerr/seerr_providers.dart';
import '../seerr/widgets/seerr_widgets.dart';
import '../../core/seerr/suggestion_filters.dart';
import 'recommendations.dart';
import 'suggestion_filters_store.dart';

// ---------------------------------------------------------------- settings

/// The endless "More for you" section under the user's own rows.
class MoreForYouSettings {
  const MoreForYouSettings({
    this.enabled = false,
    this.fromLibrary = true,
    this.notInterested = const {},
    this.filterSetId = filterSetDefault,
  });

  factory MoreForYouSettings.fromJson(Map<String, dynamic> j) => MoreForYouSettings(
    enabled: j['enabled'] as bool? ?? false,
    fromLibrary: j['fromLibrary'] as bool? ?? true,
    notInterested: {for (final k in (j['notInterested'] as List?) ?? const []) k as String},
    filterSetId: j['filterSetId'] as String? ?? filterSetDefault,
  );

  final bool enabled;

  /// Also rows of unwatched titles from the library ("Unwatched fantasy").
  final bool fromLibrary;

  /// Row ideas the user said "Not interested" to (see [MoreRowIdea.key]).
  final Set<String> notInterested;

  /// The suggestion filter set every generated row follows.
  final String filterSetId;

  MoreForYouSettings copyWith({bool? enabled, bool? fromLibrary, Set<String>? notInterested, String? filterSetId}) =>
      MoreForYouSettings(
        enabled: enabled ?? this.enabled,
        fromLibrary: fromLibrary ?? this.fromLibrary,
        notInterested: notInterested ?? this.notInterested,
        filterSetId: filterSetId ?? this.filterSetId,
      );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'fromLibrary': fromLibrary,
    'notInterested': notInterested.toList(),
    'filterSetId': filterSetId,
  };
}

final moreForYouSettingsProvider = AsyncNotifierProvider<MoreForYouSettingsController, MoreForYouSettings>(
  MoreForYouSettingsController.new,
);

class MoreForYouSettingsController extends AsyncNotifier<MoreForYouSettings> {
  String get _key {
    final s = ref.read(currentSessionProvider);
    return 'home.more.${s.serverId}.${s.userId}';
  }

  @override
  Future<MoreForYouSettings> build() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return const MoreForYouSettings();
    try {
      return MoreForYouSettings.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    } on Object {
      return const MoreForYouSettings();
    }
  }

  Future<void> save(MoreForYouSettings settings) async {
    await future;
    state = AsyncData(settings);
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(settings.toJson()));
  }

  Future<void> notInterested(String key) async {
    final s = await future;
    await save(s.copyWith(notInterested: {...s.notInterested, key}));
  }
}

// --------------------------------------------------------------- the ideas

/// One generated row: what it shows and why.
sealed class MoreRowIdea {
  const MoreRowIdea({required this.key, required this.title});

  /// Stable id, for "Not interested" ("genre:16", "seed:tv:1234", …).
  final String key;
  final String title;
}

/// From Seerr: a discover query, or one title's recommendations.
class SeerrIdea extends MoreRowIdea {
  const SeerrIdea({required super.key, required super.title, this.spec, this.seed});

  final SeerrRowSpec? spec;
  final TasteSeed? seed;
}

/// From the library: unwatched titles in a genre.
class LibraryIdea extends MoreRowIdea {
  const LibraryIdea({required super.key, required super.title, required this.genre});

  final String genre;
}

/// Row ideas from the taste profile, the strongest of each kind first and
/// the kinds taken in turn, so neighbouring rows differ ("Because you
/// watched X", "More fantasy", "Hidden gems: isekai", "From MAPPA", …).
List<MoreRowIdea> moreRowIdeas({
  required List<TasteSeed> seeds,
  required TasteProfile profile,
  List<String> libraryGenres = const [],
  Map<String, String> languageNames = const {},
  Set<String> notInterested = const {},
  SuggestionFilterSet? filters,
}) {
  final discover =
      filters?.discoverSource(preferTv: profile.tvShare >= 0.5) ??
      (profile.tvShare >= 0.5 ? SeerrSource.discoverTv : SeerrSource.discoverMovies);
  final tv = discover == SeerrSource.discoverTv;
  final kind = tv ? 'series' : 'movies';
  String cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
  final genres = profile.topGenres(8);
  final keywords = profile.topKeywords(8);

  final kinds = <List<MoreRowIdea>>[
    [
      // The first seed is the user's own "Because you watched" row's
      // usual pick; start with the next ones.
      for (final s in seeds.skip(1).take(8))
        SeerrIdea(key: 'seed:${s.key}', title: 'Because you watched ${s.name}', seed: s),
    ],
    [
      for (final g in genres)
        SeerrIdea(
          key: 'genre:${g.id}',
          title: 'More ${g.name.toLowerCase()} $kind',
          spec: SeerrRowSpec(source: discover, genres: [g], ratingMin: 6.5, votesMin: 30, hideAvailable: true),
        ),
    ],
    [
      for (final k in keywords)
        SeerrIdea(
          key: 'keyword:${k.id}',
          title: 'More ${cap(k.name)}',
          spec: SeerrRowSpec(source: discover, keywords: [k], ratingMin: 6.5, votesMin: 20, hideAvailable: true),
        ),
    ],
    [
      for (final g in [...genres.take(4), ...keywords.take(3)])
        SeerrIdea(
          key: 'gem:${g.id}',
          title: 'Hidden gems: ${g.name.toLowerCase()}',
          spec: SeerrRowSpec(
            source: discover,
            genres: [if (genres.contains(g)) g],
            keywords: [if (!genres.contains(g)) g],
            ratingMin: 7.5,
            votesMin: 15,
            votesMax: 400,
            sort: SeerrSort.rating,
            hideAvailable: true,
          ),
        ),
    ],
    [
      if (tv)
        for (final c in profile.topCompanies(4))
          SeerrIdea(
            key: 'network:${c.id}',
            title: 'From ${c.name}',
            spec: SeerrRowSpec(source: discover, company: c, votesMin: 20, hideAvailable: true),
          ),
    ],
    [
      for (final g in libraryGenres.take(6))
        LibraryIdea(key: 'library:$g', title: 'Unwatched ${g.toLowerCase()} in your library', genre: g),
    ],
    [
      if (profile.mainLanguage case final lang?)
        SeerrIdea(
          key: 'language:$lang',
          title: 'Top-rated ${languageNames[lang] ?? lang.toUpperCase()} $kind',
          spec: SeerrRowSpec(
            source: discover,
            originalLanguages: [SeerrOption(lang, languageNames[lang] ?? lang)],
            ratingMin: 8,
            votesMin: 200,
            sort: SeerrSort.rating,
            hideAvailable: true,
          ),
        ),
    ],
  ];

  // Then further down the taste profile, so the section keeps going:
  // the less strong genres / keywords and seeds, pairs of them, and the
  // best-rated / newest of each genre. (After the first set, so the rows
  // already shown keep their order.)
  final moreGenres = profile.topGenres(20).skip(8).toList();
  final moreKeywords = profile.topKeywords(30).skip(8).toList();
  final allGenres = [...genres, ...moreGenres];
  final more = <List<MoreRowIdea>>[
    [
      for (final s in seeds.skip(9).take(20))
        SeerrIdea(key: 'seed:${s.key}', title: 'Because you watched ${s.name}', seed: s),
    ],
    [
      for (final g in moreGenres)
        SeerrIdea(
          key: 'genre:${g.id}',
          title: 'More ${g.name.toLowerCase()} $kind',
          spec: SeerrRowSpec(source: discover, genres: [g], ratingMin: 6.5, votesMin: 30, hideAvailable: true),
        ),
    ],
    [
      for (final k in moreKeywords)
        SeerrIdea(
          key: 'keyword:${k.id}',
          title: 'More ${cap(k.name)}',
          spec: SeerrRowSpec(source: discover, keywords: [k], ratingMin: 6.5, votesMin: 20, hideAvailable: true),
        ),
    ],
    [
      for (final g in allGenres.take(10))
        SeerrIdea(
          key: 'best:${g.id}',
          title: 'Top-rated ${g.name.toLowerCase()} $kind',
          spec: SeerrRowSpec(source: discover, genres: [g], votesMin: 300, sort: SeerrSort.rating, hideAvailable: true),
        ),
    ],
    [
      for (final g in allGenres.take(10))
        SeerrIdea(
          key: 'new:${g.id}',
          title: 'New ${g.name.toLowerCase()} $kind',
          spec: SeerrRowSpec(
            source: discover,
            genres: [g],
            dateRange: SeerrDateRange.lastYear,
            votesMin: 10,
            hideAvailable: true,
          ),
        ),
    ],
    [
      for (final g in genres.take(5))
        for (final k in keywords.take(5))
          SeerrIdea(
            key: 'pair:${g.id}:${k.id}',
            title: '${cap(g.name)} · ${k.name.toLowerCase()}',
            spec: SeerrRowSpec(source: discover, genres: [g], keywords: [k], votesMin: 10, hideAvailable: true),
          ),
    ],
  ];

  final ideas = <MoreRowIdea>[];
  final seen = <String>{};
  for (final set in [kinds, more]) {
    for (var round = 0; set.any((k) => round < k.length); round++) {
      for (final k in set) {
        if (round >= k.length) continue;
        final idea = k[round];
        if (notInterested.contains(idea.key) || !seen.add(idea.key)) continue;
        // Every generated query follows the filter set too.
        ideas.add(switch (idea) {
          SeerrIdea(spec: final spec?) when filters != null => SeerrIdea(
            key: idea.key,
            title: idea.title,
            spec: filters.applyTo(spec),
          ),
          _ => idea,
        });
      }
    }
  }
  return ideas;
}

/// Language code -> English name (Seerr's list), for row titles.
final _languageNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  final api = ref.watch(seerrApiProvider);
  if (api == null) return const {};
  try {
    return {for (final l in await api.languages()) l.id: l.name};
  } on Object {
    return const {};
  }
}, retry: (_, _) => null);

/// The generated rows, while the section is on.
final moreForYouIdeasProvider = FutureProvider<List<MoreRowIdea>>((ref) async {
  final settings = await ref.watch(moreForYouSettingsProvider.future);
  if (!settings.enabled) return const [];
  final signedInToSeerr = ref.watch(seerrApiProvider) != null;
  final seeds = await ref.watch(tasteSeedsProvider.future).catchError((Object _) => const <TasteSeed>[]);
  // Seerr down: wait for it rather than plan from nothing. (The profile
  // retries by itself; its future only settles once it works, so look at
  // its state, and come back here when that changes.)
  if (signedInToSeerr) {
    if (ref.watch(tasteProfileProvider).error case final e? when seerrTransient(e)) throw e;
  }
  final profile = signedInToSeerr
      ? await ref.watch(tasteProfileProvider.future).catchError((Object e) {
          if (seerrTransient(e)) throw e;
          return const TasteProfile();
        })
      : const TasteProfile();
  final names = await ref.watch(_languageNamesProvider.future);
  final filters = await ref.watch(suggestionFilterSetProvider(settings.filterSetId).future);

  // Library rows: the profile's genres that the server also uses, else
  // the library's genres.
  var libraryGenres = const <String>[];
  if (settings.fromLibrary) {
    final serverGenres = await ref.watch(genresProvider(null).future).catchError((Object _) => const <String>[]);
    final liked = [for (final g in profile.topGenres(8)) g.name];
    libraryGenres = [for (final g in liked) ?serverGenres.where((s) => s.toLowerCase() == g.toLowerCase()).firstOrNull];
    if (libraryGenres.isEmpty) libraryGenres = serverGenres.take(4).toList();
  }
  return moreRowIdeas(
    seeds: signedInToSeerr ? seeds : const [],
    profile: profile,
    libraryGenres: libraryGenres,
    languageNames: names,
    notInterested: settings.notInterested,
    filters: filters,
  );
}, retry: seerrRetry);

/// The order rows were first shown in: when the ideas are worked out again
/// (e.g. Seerr back after an outage, with the full taste profile), rows
/// already on screen keep their place and new ones go below.
final _shownOrderProvider = Provider<List<String>>((ref) {
  ref.watch(moreForYouSettingsProvider);
  return [];
});

List<MoreRowIdea> _keepOrder(List<String> shown, List<MoreRowIdea> ideas) {
  final byKey = {for (final i in ideas) i.key: i};
  final ordered = [for (final k in shown) ?byKey[k]];
  final fresh = [
    for (final i in ideas)
      if (!shown.contains(i.key)) i,
  ];
  shown.addAll(fresh.map((i) => i.key));
  return [...ordered, ...fresh];
}

/// Titles already shown higher up in "More for you" aren't repeated
/// further down: the first row (lowest index) to show a title keeps it.
class _Claims {
  final _owner = <String, int>{};

  List<SeerrMedia> keep(int row, List<SeerrMedia> items) => [
    for (final m in items)
      if ((_owner[m.key] ??= row) >= row) m,
  ];
}

final _claimsProvider = Provider<_Claims>((ref) {
  ref.watch(moreForYouIdeasProvider);
  return _Claims();
});

// ----------------------------------------------------------------- widgets

/// The section under the user's rows; each row loads when it scrolls into
/// view, and Seerr rows load more as they're scrolled sideways.
List<Widget> moreForYouSection(BuildContext context, WidgetRef ref) {
  final ideas = ref.watch(moreForYouIdeasProvider);
  if (ref.watch(moreForYouSettingsProvider).value?.enabled != true) return const [];
  final layout = context.layout;
  return [
    Padding(
      padding: EdgeInsets.fromLTRB(layout.gutter, 40, layout.gutter, 0),
      child: Text('More for you', style: Theme.of(context).textTheme.headlineSmall),
    ),
    // The rows shown so far stay while the ideas are worked out again.
    ...switch (ideas) {
      AsyncValue(:final value?) when value.isEmpty => [
        Padding(
          padding: EdgeInsets.all(layout.gutter),
          child: const Text('Watch or favourite a few shows, and suggestions appear here.'),
        ),
      ],
      AsyncValue(:final value?) => [
        for (final (i, idea) in _keepOrder(ref.read(_shownOrderProvider), value).indexed)
          _MoreRow(key: ValueKey(idea.key), index: i, idea: idea),
        // The end: said, not just stopping.
        Padding(
          padding: EdgeInsets.fromLTRB(layout.gutter, 32, layout.gutter, 16),
          child: Row(
            children: [
              const Expanded(child: Text("That's everything for now.")),
              TextButton.icon(
                onPressed: () {
                  ref.read(_shownOrderProvider).clear();
                  ref.invalidate(tasteProfileProvider);
                  ref.invalidate(moreForYouIdeasProvider);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
      ],
      // Failed, or retrying after a failure (loading, with the error).
      AsyncValue(:final error?) when seerrTransient(error) => [
        Padding(padding: EdgeInsets.all(layout.gutter), child: const Text('Waiting for Seerr…')),
      ],
      AsyncError() => [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: layout.gutter, vertical: 8),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  "Couldn't load suggestions",
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
              TextButton(
                onPressed: () {
                  ref.invalidate(tasteProfileProvider);
                  ref.invalidate(moreForYouIdeasProvider);
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ],
      _ => [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
    },
  ];
}

/// Fewer titles than this (after filtering), and a generated row isn't
/// worth showing.
const _minRowItems = 6;

/// One generated row. Kept alive once built: Home builds lazily, and a
/// row rebuilt on the way back up would load again (different titles, a
/// different height) and make the page jump.
class _MoreRow extends ConsumerStatefulWidget {
  const _MoreRow({super.key, required this.index, required this.idea});

  final int index;
  final MoreRowIdea idea;

  @override
  ConsumerState<_MoreRow> createState() => _MoreRowState();
}

class _MoreRowState extends ConsumerState<_MoreRow> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final idea = widget.idea;
    final index = widget.index;
    final notInterested = IconButton(
      tooltip: 'Not interested',
      icon: const Icon(Icons.not_interested, size: 20),
      onPressed: () => ref.read(moreForYouSettingsProvider.notifier).notInterested(idea.key),
    );
    return switch (idea) {
      LibraryIdea(:final genre) => switch (ref.watch(moreLibraryIdeaProvider(genre))) {
        AsyncData(:final value) when value.length < _minRowItems => const SizedBox.shrink(),
        // Only a suggestion: if it can't load, it stays out of the way.
        final items when items.hasError && !items.hasValue => const SizedBox.shrink(),
        final items => _withAction(
          MediaRow(title: idea.title, items: items, onItemPressed: (item) => openItem(context, item)),
          notInterested,
        ),
      },
      final SeerrIdea seerr => _EndlessSeerrRow(index: index, idea: seerr, action: notInterested),
    };
  }

  /// A row with an action at the right of its title line.
  Widget _withAction(Widget row, Widget action) => Stack(
    children: [
      row,
      Positioned(top: 16, right: 8, child: action),
    ],
  );
}

final moreLibraryIdeaProvider = FutureProvider.family<List<BaseItem>, String>((ref, genre) async {
  final page = await ref
      .watch(libraryApiProvider)
      .getItems(
        ItemQuery(
          includeItemTypes: const [ItemType.series, ItemType.movie],
          genres: [genre],
          unplayedOnly: true,
          sortBy: SortField.random,
        ),
        limit: 40,
      );
  // Not watched shows or empty show folders, which the server lets through.
  return page.items.where(hasSomethingToWatch).take(24).toList();
}, retry: (_, _) => null);

/// A Seerr row that fetches its next page when scrolled near its end.
class _EndlessSeerrRow extends ConsumerStatefulWidget {
  const _EndlessSeerrRow({required this.index, required this.idea, required this.action});

  final int index;
  final SeerrIdea idea;
  final Widget action;

  @override
  ConsumerState<_EndlessSeerrRow> createState() => _EndlessSeerrRowState();
}

class _EndlessSeerrRowState extends ConsumerState<_EndlessSeerrRow> {
  final _items = <SeerrMedia>[];
  var _page = 0;
  var _loading = false;
  var _done = false;
  Object? _error;

  /// Failed (Seerr unreachable for a moment): tries again by itself, 5 s,
  /// 15 s, 30 s, then every minute, and straight away once Seerr answers.
  Timer? _retry;
  var _attempt = 0;

  @override
  void initState() {
    super.initState();
    _more();
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _retryNow() {
    _retry?.cancel();
    _retry = null;
    if (_error != null && mounted) {
      setState(() => _error = null);
      _more();
    }
  }

  Future<void> _more() async {
    final api = ref.read(seerrApiProvider);
    if (_loading || _done || _error != null || api == null) return;
    setState(() => _loading = true);
    try {
      final page = _page + 1;
      final idea = widget.idea;
      // A few at a time across all the rows, so Seerr isn't flooded.
      final results = await ref
          .read(seerrSlotsProvider)
          .run(
            () => trackSeerr(() => ref.read(seerrReachableProvider.notifier), switch (idea) {
              SeerrIdea(seed: final s?) => api.recommendations(s.type, s.tmdbId, page: page),
              SeerrIdea(spec: final spec?) => api.row(spec, page: page),
              _ => Future.value(const <SeerrMedia>[]),
            }),
          );
      _attempt = 0;
      final index = await ref.read(libraryTmdbIndexProvider.future).catchError((Object _) => const <String, String>{});
      final settings = await ref.read(moreForYouSettingsProvider.future);
      final filters = await ref.read(suggestionFilterSetProvider(settings.filterSetId).future);
      final fresh = [
        for (final m in results)
          if (m.status != SeerrMediaStatus.available && serverItemFor(m, index) == null && (filters?.allows(m) ?? true))
            m,
      ];
      if (!mounted) return;
      final kept = ref.read(_claimsProvider).keep(widget.index, fresh);
      setState(() {
        _page = page;
        _items.addAll(kept.where((m) => !_items.any((x) => x.key == m.key)));
        _done = results.isEmpty || page >= 5;
      });
      // Too few after filtering: get the next page straight away.
      if (_items.length < 8 && !_done) {
        _loading = false;
        await _more();
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      if (seerrTransient(e)) _retry = Timer(seerrRetryDelay(_attempt++), _retryNow);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Seerr is back: retry now rather than at the next attempt.
    ref.listen(seerrReachableProvider, (_, ok) {
      if (ok) _retryNow();
    });
    // Nothing yet and failing: hidden while it retries (Home says Seerr is
    // unreachable); a row that has titles keeps them.
    if ((_error != null && _items.isEmpty) || (_done && _items.length < _minRowItems)) return const SizedBox.shrink();
    final layout = context.layout;
    final width = layout.posterWidth;
    final theme = Theme.of(context);
    // Paged rows (Settings > Appearance > Rows): ‹ › by the title.
    return RowScope(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(layout.gutter, 24, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(widget.idea.title, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge),
              ),
              const RowPager(),
              widget.action,
            ],
          ),
        ),
        SizedBox(
          height: width * 1.5 + 80,
          child: _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : FocusTraversalGroup(
                  child: SideScroll(
                    pageable: true,
                    builder: (controller) => NotificationListener<ScrollUpdateNotification>(
                      onNotification: (n) {
                        if (n.metrics.extentAfter < width * 4) _more();
                        return false;
                      },
                      child: ListView.separated(
                        controller: controller,
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.symmetric(horizontal: layout.gutter, vertical: 8),
                        clipBehavior: Clip.none,
                        itemCount: _items.length + (_done ? 0 : 1),
                        separatorBuilder: (_, _) => const SizedBox(width: 16),
                        // The end: a spinner while the next page loads.
                        itemBuilder: (context, i) => i == _items.length
                            ? SizedBox(
                                width: width,
                                child: _loading ? const Center(child: CircularProgressIndicator()) : null,
                              )
                            : RowItem(index: i, child: SeerrCard(media: _items[i], width: width)),
                      ),
                    ),
                  ),
                ),
        ),
      ],
      ),
    );
  }
}
