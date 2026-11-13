import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/library_api.dart';
import '../../core/seerr/seerr_api.dart';
import '../../core/seerr/seerr_discover.dart';
import '../library/library_providers.dart';
import '../seerr/seerr_health.dart';
import '../seerr/seerr_providers.dart' show libraryTmdbIndexProvider, seerrApiProvider, serverItemFor;
import 'recommendations.dart';

/// The home page's rows, in order: built-in rows (which can be hidden and
/// moved) and the user's own Jellyfin and Seerr rows. Saved per device and
/// per account (a TV and a PC may want different homes).
sealed class HomeRow {
  const HomeRow({required this.id, this.visible = true});

  /// Stable within a layout (built-ins: their kind + library).
  final String id;
  final bool visible;

  HomeRow withVisible(bool visible);
  Map<String, dynamic> toJson();

  static HomeRow? fromJson(Map<String, dynamic> j) => switch (j['type']) {
        'builtin' => BuiltInRow.fromJson(j),
        'jellyfin' => JellyfinHomeRow.fromJson(j),
        'seerr' => SeerrHomeRow.fromJson(j),
        _ => null,
      };
}

enum BuiltInKind {
  continueWatching('Continue watching'),
  nextUp('Next up'),
  thisWeek('This week'),
  genres('Browse by genre'),
  libraries('Libraries'),
  recentlyAdded('Recently added'),
  seerrTrending('Trending'),
  seerrPopularAnime('Popular anime'),
  seerrSeasonalAnime("This season's anime"),
  seerrUpcomingAnime('Upcoming anime');

  const BuiltInKind(this.label);

  final String label;

  bool get isSeerr => name.startsWith('seerr');
}

class BuiltInRow extends HomeRow {
  BuiltInRow(this.kind, {this.libraryId, this.libraryName, super.visible})
      : super(id: libraryId == null ? kind.name : '${kind.name}:$libraryId');

  factory BuiltInRow.fromJson(Map<String, dynamic> j) => BuiltInRow(
        BuiltInKind.values.byName(j['kind'] as String),
        libraryId: j['libraryId'] as String?,
        libraryName: j['libraryName'] as String?,
        visible: j['visible'] as bool? ?? true,
      );

  final BuiltInKind kind;

  /// Recently added: which library.
  final String? libraryId;
  final String? libraryName;

  String get title =>
      kind == BuiltInKind.recentlyAdded ? 'Recently added in ${libraryName ?? 'library'}' : kind.label;

  @override
  BuiltInRow withVisible(bool visible) =>
      BuiltInRow(kind, libraryId: libraryId, libraryName: libraryName, visible: visible);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'builtin',
        'kind': kind.name,
        'libraryId': ?libraryId,
        'libraryName': ?libraryName,
        'visible': visible,
      };
}

enum JellyfinRowFilter {
  all('Everything'),
  unwatched('Unwatched'),
  inProgress('In progress'),
  watched('Watched'),
  favorites('Favourites');

  const JellyfinRowFilter(this.label);

  final String label;
}

/// How a custom library row looks in a theme with its own row styles
/// (Depth); Classic shows cards either way.
enum RowLook {
  shelf('Shelf', 'Spines that open into covers'),
  expanding('Expanding', 'Stills that open wide to their description');

  const RowLook(this.label, this.description);

  final String label;
  final String description;
}

/// A row of Jellyfin items matching the user's filters.
class JellyfinHomeRow extends HomeRow {
  const JellyfinHomeRow({
    required super.id,
    required this.title,
    this.libraryId,
    this.libraryName,
    this.types = const [ItemType.series],
    this.genres = const [],
    this.filter = JellyfinRowFilter.all,
    this.sort = SortField.dateAdded,
    this.descending = true,
    this.limit = 24,
    this.landscape = false,
    this.look = RowLook.shelf,
    super.visible,
  });

  factory JellyfinHomeRow.fromJson(Map<String, dynamic> j) => JellyfinHomeRow(
        id: j['id'] as String,
        title: j['title'] as String,
        libraryId: j['libraryId'] as String?,
        libraryName: j['libraryName'] as String?,
        types: [
          for (final t in (j['types'] as List?) ?? const [])
            ?ItemType.values.where((v) => v.name == t).firstOrNull,
        ],
        genres: [for (final g in (j['genres'] as List?) ?? const []) g as String],
        filter: JellyfinRowFilter.values.where((v) => v.name == j['filter']).firstOrNull ?? JellyfinRowFilter.all,
        sort: SortField.values.where((v) => v.name == j['sort']).firstOrNull ?? SortField.dateAdded,
        descending: j['descending'] as bool? ?? true,
        limit: (j['limit'] as num?)?.toInt() ?? 24,
        landscape: j['landscape'] as bool? ?? false,
        look: RowLook.values.where((v) => v.name == j['look']).firstOrNull ?? RowLook.shelf,
        visible: j['visible'] as bool? ?? true,
      );

  final String title;

  /// Null = all libraries.
  final String? libraryId;
  final String? libraryName;
  final List<ItemType> types;
  final List<String> genres;
  final JellyfinRowFilter filter;
  final SortField sort;
  final bool descending;
  final int limit;

  /// Wide cards (episode stills) instead of posters.
  final bool landscape;

  /// Its look in a theme with row styles (Depth).
  final RowLook look;

  ItemQuery get query => ItemQuery(
        parentId: libraryId,
        includeItemTypes: types,
        sortBy: sort,
        descending: descending,
        genres: genres,
        unplayedOnly: filter == JellyfinRowFilter.unwatched,
        favoritesOnly: filter == JellyfinRowFilter.favorites,
        extraFilters: [
          if (filter == JellyfinRowFilter.inProgress) 'IsResumable',
          if (filter == JellyfinRowFilter.watched) 'IsPlayed',
        ],
      );

  JellyfinHomeRow copyWith({
    String? title,
    String? Function()? libraryId,
    String? Function()? libraryName,
    List<ItemType>? types,
    List<String>? genres,
    JellyfinRowFilter? filter,
    SortField? sort,
    bool? descending,
    int? limit,
    bool? landscape,
    RowLook? look,
    bool? visible,
  }) =>
      JellyfinHomeRow(
        id: id,
        title: title ?? this.title,
        libraryId: libraryId == null ? this.libraryId : libraryId(),
        libraryName: libraryName == null ? this.libraryName : libraryName(),
        types: types ?? this.types,
        genres: genres ?? this.genres,
        filter: filter ?? this.filter,
        sort: sort ?? this.sort,
        descending: descending ?? this.descending,
        limit: limit ?? this.limit,
        landscape: landscape ?? this.landscape,
        look: look ?? this.look,
        visible: visible ?? this.visible,
      );

  @override
  JellyfinHomeRow withVisible(bool visible) => copyWith(visible: visible);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'jellyfin',
        'id': id,
        'title': title,
        'libraryId': libraryId,
        'libraryName': libraryName,
        'types': [for (final t in types) t.name],
        'genres': genres,
        'filter': filter.name,
        'sort': sort.name,
        'descending': descending,
        'limit': limit,
        'landscape': landscape,
        'look': look.name,
        'visible': visible,
      };

  // Used as a provider key: equal when every setting is.
  @override
  bool operator ==(Object other) => other is JellyfinHomeRow && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// A row of Seerr titles from the user's source and filters.
class SeerrHomeRow extends HomeRow {
  const SeerrHomeRow({required super.id, required this.title, required this.spec, this.limit = 20, super.visible});

  factory SeerrHomeRow.fromJson(Map<String, dynamic> j) => SeerrHomeRow(
        id: j['id'] as String,
        title: j['title'] as String,
        spec: SeerrRowSpec.fromJson((j['spec'] as Map).cast<String, dynamic>()),
        limit: (j['limit'] as num?)?.toInt() ?? 20,
        visible: j['visible'] as bool? ?? true,
      );

  final String title;
  final SeerrRowSpec spec;
  final int limit;

  SeerrHomeRow copyWith({String? title, SeerrRowSpec? spec, int? limit, bool? visible}) => SeerrHomeRow(
        id: id,
        title: title ?? this.title,
        spec: spec ?? this.spec,
        limit: limit ?? this.limit,
        visible: visible ?? this.visible,
      );

  @override
  SeerrHomeRow withVisible(bool visible) => copyWith(visible: visible);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'seerr',
        'id': id,
        'title': title,
        'spec': spec.toJson(),
        'limit': limit,
        'visible': visible,
      };

  @override
  bool operator ==(Object other) => other is SeerrHomeRow && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Libraries that get a "Recently added" row (video libraries).
bool _hasLatest(BaseItem view) => const {'movies', 'tvshows', null}.contains(view.collectionType);

/// Today's fixed home page, as a layout: the default.
List<HomeRow> defaultHomeLayout(List<BaseItem> views) => [
      BuiltInRow(BuiltInKind.continueWatching),
      BuiltInRow(BuiltInKind.nextUp),
      BuiltInRow(BuiltInKind.thisWeek),
      BuiltInRow(BuiltInKind.genres),
      BuiltInRow(BuiltInKind.libraries),
      for (final v in views.where(_hasLatest)) BuiltInRow(BuiltInKind.recentlyAdded, libraryId: v.id, libraryName: v.name),
      for (final kind in BuiltInKind.values.where((k) => k.isSeerr)) BuiltInRow(kind),
    ];

/// [saved] brought up to date with the server's libraries: new libraries
/// get a "Recently added" row (after the other ones), removed ones lose
/// theirs, and renamed ones show their new name.
List<HomeRow> reconcileHomeLayout(List<HomeRow> saved, List<BaseItem> views) {
  final latest = {for (final v in views.where(_hasLatest)) v.id: v};
  final rows = <HomeRow>[
    for (final r in saved)
      if (r case BuiltInRow(kind: BuiltInKind.recentlyAdded, :final libraryId?))
        if (latest[libraryId] case final v?)
          BuiltInRow(BuiltInKind.recentlyAdded, libraryId: v.id, libraryName: v.name, visible: r.visible)
        else
          ...const <HomeRow>[]
      else
        r,
  ];
  // Built-in rows missing from the saved layout (new libraries, rows added
  // in an update) come back in their default order: each right after the
  // default row before it, or first.
  var anchor = -1;
  for (final d in defaultHomeLayout(views)) {
    final at = rows.indexWhere((r) => r.id == d.id);
    if (at >= 0) {
      anchor = at;
    } else {
      rows.insert(++anchor, d);
    }
  }
  return rows;
}

final homeLayoutProvider =
    AsyncNotifierProvider<HomeLayoutController, List<HomeRow>>(HomeLayoutController.new, retry: (_, _) => null);

class HomeLayoutController extends AsyncNotifier<List<HomeRow>> {
  String get _key {
    final session = ref.read(currentSessionProvider);
    return 'home.layout.${session.serverId}.${session.userId}';
  }

  @override
  Future<List<HomeRow>> build() async {
    // Libraries failing to load (offline) still gives a home page.
    List<BaseItem> views;
    try {
      views = await ref.watch(viewsProvider.future);
    } on Object {
      views = const [];
    }
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return defaultHomeLayout(views);
    try {
      final saved = [
        for (final j in jsonDecode(raw) as List) ?HomeRow.fromJson((j as Map).cast<String, dynamic>()),
      ];
      return reconcileHomeLayout(saved, views);
    } on Object {
      return defaultHomeLayout(views);
    }
  }

  Future<void> save(List<HomeRow> rows) async {
    await future;
    state = AsyncData(rows);
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode([for (final r in rows) r.toJson()]));
  }

  Future<void> reset() async {
    await (await SharedPreferences.getInstance()).remove(_key);
    ref.invalidateSelf();
    await future;
  }

  /// A fresh id for a new custom row.
  static String newId() => 'custom-${DateTime.now().microsecondsSinceEpoch}';
}

/// Items for a custom Jellyfin row.
final jellyfinRowProvider = FutureProvider.autoDispose.family<List<BaseItem>, JellyfinHomeRow>((ref, row) async {
  // The Expanding look shows each one's description.
  final fields = row.look == RowLook.expanding ? '$listFields,Overview' : listFields;
  if (!row.query.unplayedOnly) {
    return (await ref.watch(libraryApiProvider).getItems(row.query, limit: row.limit, fields: fields)).items;
  }
  // "Unwatched": some of what the server calls unplayed isn't; ask for more.
  final page = await ref.watch(libraryApiProvider).getItems(row.query, limit: row.limit * 2, fields: fields);
  return page.items.where(hasSomethingToWatch).take(row.limit).toList();
}, retry: (_, _) => null);

/// Picked for you: TV, movies, or (null) whichever the user watches more.
SeerrMediaType? pickedType(SeerrRowSpec spec) => switch (spec.trendingType) {
      SeerrTrendingType.tv => SeerrMediaType.tv,
      SeerrTrendingType.movie => SeerrMediaType.movie,
      SeerrTrendingType.all => null,
    };

/// A Seerr row's title as shown: the user's, or for recommendation rows
/// left unnamed, one that says what it is ("Because you watched Frieren").
String seerrRowTitle(WidgetRef ref, SeerrHomeRow row) {
  if (row.title.trim().isNotEmpty) return row.title;
  return switch (row.spec.source) {
    SeerrSource.becauseYouWatched => switch (ref.watch(becauseYouWatchedProvider(row.spec)).value?.seed) {
        final s? => 'Because you watched ${s.name}',
        null => 'Because you watched…',
      },
    SeerrSource.recommendedForYou => 'Recommended for you',
    SeerrSource.pickedForYou => 'Picked for you',
    final s => s.label,
  };
}

/// "Why these?" for Picked for you: the profile's top tags.
String? seerrRowSubtitle(WidgetRef ref, SeerrHomeRow row) => row.spec.source == SeerrSource.pickedForYou
    ? switch (ref.watch(pickedForYouProvider((pickedType(row.spec), row.spec.hideAvailable, row.spec.filterSetId))).value?.profile) {
        final p? when !p.isEmpty => 'Based on ${p.summary()}',
        _ => null,
      }
    : null;

/// Titles for a custom Seerr row.
final seerrHomeRowProvider = FutureProvider.autoDispose.family<List<SeerrMedia>, SeerrHomeRow>((ref, row) async {
  final api = ref.watch(seerrApiProvider);
  if (api == null) return const [];
  final spec = row.spec;
  // Built from the library and watch history (they hide on-server titles
  // themselves when asked).
  switch (spec.source) {
    case SeerrSource.becauseYouWatched:
      return (await ref.watch(becauseYouWatchedProvider(spec).future)).items.take(row.limit).toList();
    case SeerrSource.recommendedForYou:
      return (await ref.watch(recommendedForYouProvider((spec.hideAvailable, spec.filterSetId)).future))
          .take(row.limit)
          .toList();
    case SeerrSource.pickedForYou:
      return (await ref.watch(pickedForYouProvider((pickedType(spec), spec.hideAvailable, spec.filterSetId)).future))
          .items
          .take(row.limit)
          .toList();
    default:
  }
  final results = await trackSeerr(() => ref.read(seerrReachableProvider.notifier), api.row(spec));
  if (!row.spec.hideAvailable) return results.take(row.limit).toList();
  // "Hide titles already on the server" also uses the library's TMDB ids.
  final index = await ref.watch(libraryTmdbIndexProvider.future).catchError((Object _) => const <String, String>{});
  return [for (final m in results) if (serverItemFor(m, index) == null) m].take(row.limit).toList();
}, retry: seerrRetry);
