import 'seerr_api.dart';

/// Something picked from one of Seerr's lookup lists (a genre, keyword,
/// studio, network, watch provider, language…): its API value and a label.
class SeerrOption {
  const SeerrOption(this.id, this.name);

  factory SeerrOption.fromJson(Map<String, dynamic> j) => SeerrOption(j['id'] as String, j['name'] as String);

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  @override
  bool operator ==(Object other) => other is SeerrOption && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Where a custom Seerr row's titles come from.
enum SeerrSource {
  discoverTv('Discover TV'),
  discoverMovies('Discover movies'),
  trending('Trending'),
  upcomingTv('Upcoming TV'),
  upcomingMovies('Upcoming movies'),
  watchlist('My Seerr watchlist'),
  becauseYouWatched('Because you watched…'),
  recommendedForYou('Recommended for you'),
  pickedForYou('Picked for you');

  const SeerrSource(this.label);

  final String label;

  bool get isDiscover => this == discoverTv || this == discoverMovies;
  bool get isTv => this == discoverTv || this == upcomingTv;

  /// Built from the user's library and watch history.
  bool get isRecommendation => this == becauseYouWatched || this == recommendedForYou || this == pickedForYou;
}

enum SeerrTrendingType {
  all('Movies & TV'),
  tv('TV'),
  movie('Movies');

  const SeerrTrendingType(this.label);

  final String label;
}

/// Release / first-air date windows; [custom] uses the row's own dates.
enum SeerrDateRange {
  any('Any time'),
  thisYear('This year'),
  lastYear('Last 12 months'),
  last5Years('Last 5 years'),
  thisAnimeSeason("This anime season"),
  nextAnimeSeason('Next anime season'),
  custom('Custom dates');

  const SeerrDateRange(this.label);

  final String label;
}

/// TMDB sort keys for discover (each ascending or descending).
enum SeerrSort {
  popularity('Popularity', 'popularity', 'popularity'),
  releaseDate('Release date', 'first_air_date', 'primary_release_date'),
  rating('Rating', 'vote_average', 'vote_average'),
  votes('Number of votes', 'vote_count', 'vote_count'),
  title('Title', 'name', 'title'),
  revenue('Revenue (movies)', 'popularity', 'revenue');

  const SeerrSort(this.label, this.tvKey, this.movieKey);

  final String label;
  final String tvKey;
  final String movieKey;
}

/// TV status values TMDB filters on.
const seerrTvStatuses = {
  0: 'Returning series',
  1: 'Planned',
  2: 'In production',
  3: 'Ended',
  4: 'Cancelled',
  5: 'Pilot',
};

/// The anime season (Winter = Jan–Mar, …) containing [day]: its first and
/// last day. [offset] 1 = the next season.
(DateTime, DateTime) animeSeason(DateTime day, {int offset = 0}) {
  final quarter = (day.month - 1) ~/ 3 + offset;
  final start = DateTime(day.year + quarter ~/ 4, (quarter % 4) * 3 + 1);
  final end = DateTime(start.year, start.month + 3, 0);
  return (start, end);
}

String seerrDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Everything a custom Seerr row asks Seerr for: the source and, for the
/// discover sources, Seerr's full set of discover filters.
class SeerrRowSpec {
  const SeerrRowSpec({
    this.source = SeerrSource.discoverTv,
    this.trendingType = SeerrTrendingType.all,
    this.trendingWeek = true,
    this.genres = const [],
    this.anyGenre = false,
    this.keywords = const [],
    this.anyKeyword = false,
    this.excludeKeywords = const [],
    this.originalLanguages = const [],
    this.company,
    this.dateRange = SeerrDateRange.any,
    this.dateFrom,
    this.dateTo,
    this.tvStatuses = const [],
    this.ratingMin,
    this.ratingMax,
    this.votesMin,
    this.votesMax,
    this.runtimeMin,
    this.runtimeMax,
    this.watchRegion,
    this.watchProviders = const [],
    this.certificationCountry,
    this.certifications = const [],
    this.sort = SeerrSort.popularity,
    this.descending = true,
    this.hideAvailable = false,
    this.seed,
    this.filterSetId = 'default',
  });

  final SeerrSource source;

  // Trending only.
  final SeerrTrendingType trendingType;
  final bool trendingWeek;

  // Discover only.
  final List<SeerrOption> genres;

  /// Any of [genres] (default: all of them).
  final bool anyGenre;
  final List<SeerrOption> keywords;
  final bool anyKeyword;
  final List<SeerrOption> excludeKeywords;

  /// Any of these original languages (ISO 639-1).
  final List<SeerrOption> originalLanguages;

  /// A studio (movies) or network (TV).
  final SeerrOption? company;
  final SeerrDateRange dateRange;
  final DateTime? dateFrom;
  final DateTime? dateTo;

  /// TV status codes (see [seerrTvStatuses]); any of them.
  final List<int> tvStatuses;

  /// TMDB score, 0–10.
  final double? ratingMin;
  final double? ratingMax;
  final int? votesMin;

  /// Few votes = little known ("hidden gems").
  final int? votesMax;

  /// Minutes.
  final int? runtimeMin;
  final int? runtimeMax;

  /// Streaming services (any of) in [watchRegion] (ISO 3166-1).
  final String? watchRegion;
  final List<SeerrOption> watchProviders;

  /// Age ratings (any of) in [certificationCountry], e.g. US: TV-14.
  final String? certificationCountry;
  final List<String> certifications;

  final SeerrSort sort;
  final bool descending;

  /// Leave out titles that are already on the server.
  final bool hideAvailable;

  /// Because you watched: the title ("tv:1234" + its name); null = the
  /// most recent one from the library.
  final SeerrOption? seed;

  /// Recommendation sources: the suggestion filter set to apply ('default',
  /// 'none' or a set's id).
  final String filterSetId;

  SeerrMediaType get mediaType => source.isTv ? SeerrMediaType.tv : SeerrMediaType.movie;

  /// The dates [dateRange] stands for on [today], or null for any time.
  (DateTime?, DateTime?) dates(DateTime today) => switch (dateRange) {
        SeerrDateRange.any => (null, null),
        SeerrDateRange.thisYear => (DateTime(today.year), DateTime(today.year, 12, 31)),
        SeerrDateRange.lastYear => (DateTime(today.year - 1, today.month, today.day), today),
        SeerrDateRange.last5Years => (DateTime(today.year - 5, today.month, today.day), today),
        SeerrDateRange.thisAnimeSeason => animeSeason(today),
        SeerrDateRange.nextAnimeSeason => animeSeason(today, offset: 1),
        SeerrDateRange.custom => (dateFrom, dateTo),
      };

  /// Query parameters for `/discover/tv` or `/discover/movies`.
  Map<String, Object?> discoverQuery(DateTime today) {
    final tv = source == SeerrSource.discoverTv;
    final (from, to) = dates(today);
    String? ids(List<SeerrOption> list, String sep) => list.isEmpty ? null : list.map((o) => o.id).join(sep);
    return {
      // TMDB: ',' = all of, '|' = any of.
      'genre': ids(genres, anyGenre ? '|' : ','),
      'keywords': ids(keywords, anyKeyword ? '|' : ','),
      'excludeKeywords': ids(excludeKeywords, ','),
      'language': ids(originalLanguages, '|'),
      if (company case final c?) (tv ? 'network' : 'studio'): c.id,
      if (from != null) (tv ? 'firstAirDateGte' : 'primaryReleaseDateGte'): seerrDate(from),
      if (to != null) (tv ? 'firstAirDateLte' : 'primaryReleaseDateLte'): seerrDate(to),
      if (tv && tvStatuses.isNotEmpty) 'status': tvStatuses.join('|'),
      'voteAverageGte': ratingMin,
      'voteAverageLte': ratingMax,
      'voteCountGte': votesMin,
      'voteCountLte': votesMax,
      'withRuntimeGte': runtimeMin,
      'withRuntimeLte': runtimeMax,
      if (watchProviders.isNotEmpty) ...{
        'watchRegion': watchRegion ?? 'US',
        'watchProviders': ids(watchProviders, '|'),
      },
      if (certifications.isNotEmpty) ...{
        'certificationCountry': certificationCountry ?? 'US',
        'certification': certifications.join('|'),
      },
      'sortBy': '${tv ? sort.tvKey : sort.movieKey}.${descending ? 'desc' : 'asc'}',
    }..removeWhere((_, v) => v == null);
  }

  factory SeerrRowSpec.fromJson(Map<String, dynamic> j) {
    List<SeerrOption> options(String key) => [
          for (final o in (j[key] as List?) ?? const []) SeerrOption.fromJson(o as Map<String, dynamic>),
        ];
    T named<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    DateTime? date(Object? s) => s is String ? DateTime.tryParse(s) : null;
    return SeerrRowSpec(
      source: named(SeerrSource.values, j['source'], SeerrSource.discoverTv),
      trendingType: named(SeerrTrendingType.values, j['trendingType'], SeerrTrendingType.all),
      trendingWeek: j['trendingWeek'] as bool? ?? true,
      genres: options('genres'),
      anyGenre: j['anyGenre'] as bool? ?? false,
      keywords: options('keywords'),
      anyKeyword: j['anyKeyword'] as bool? ?? false,
      excludeKeywords: options('excludeKeywords'),
      originalLanguages: options('originalLanguages'),
      company: j['company'] is Map ? SeerrOption.fromJson(j['company'] as Map<String, dynamic>) : null,
      dateRange: named(SeerrDateRange.values, j['dateRange'], SeerrDateRange.any),
      dateFrom: date(j['dateFrom']),
      dateTo: date(j['dateTo']),
      tvStatuses: [for (final s in (j['tvStatuses'] as List?) ?? const []) (s as num).toInt()],
      ratingMin: (j['ratingMin'] as num?)?.toDouble(),
      ratingMax: (j['ratingMax'] as num?)?.toDouble(),
      votesMin: (j['votesMin'] as num?)?.toInt(),
      votesMax: (j['votesMax'] as num?)?.toInt(),
      runtimeMin: (j['runtimeMin'] as num?)?.toInt(),
      runtimeMax: (j['runtimeMax'] as num?)?.toInt(),
      watchRegion: j['watchRegion'] as String?,
      watchProviders: options('watchProviders'),
      certificationCountry: j['certificationCountry'] as String?,
      certifications: [for (final c in (j['certifications'] as List?) ?? const []) c as String],
      sort: named(SeerrSort.values, j['sort'], SeerrSort.popularity),
      descending: j['descending'] as bool? ?? true,
      hideAvailable: j['hideAvailable'] as bool? ?? false,
      seed: j['seed'] is Map ? SeerrOption.fromJson(j['seed'] as Map<String, dynamic>) : null,
      filterSetId: j['filterSetId'] as String? ?? 'default',
    );
  }

  Map<String, dynamic> toJson() => {
        'source': source.name,
        'trendingType': trendingType.name,
        'trendingWeek': trendingWeek,
        'genres': [for (final o in genres) o.toJson()],
        'anyGenre': anyGenre,
        'keywords': [for (final o in keywords) o.toJson()],
        'anyKeyword': anyKeyword,
        'excludeKeywords': [for (final o in excludeKeywords) o.toJson()],
        'originalLanguages': [for (final o in originalLanguages) o.toJson()],
        'company': company?.toJson(),
        'dateRange': dateRange.name,
        'dateFrom': dateFrom == null ? null : seerrDate(dateFrom!),
        'dateTo': dateTo == null ? null : seerrDate(dateTo!),
        'tvStatuses': tvStatuses,
        'ratingMin': ratingMin,
        'ratingMax': ratingMax,
        'votesMin': votesMin,
        'votesMax': votesMax,
        'runtimeMin': runtimeMin,
        'runtimeMax': runtimeMax,
        'watchRegion': watchRegion,
        'watchProviders': [for (final o in watchProviders) o.toJson()],
        'certificationCountry': certificationCountry,
        'certifications': certifications,
        'sort': sort.name,
        'descending': descending,
        'hideAvailable': hideAvailable,
        'seed': seed?.toJson(),
        'filterSetId': filterSetId,
      };
}

/// Seerr's lookup lists, for the row editor's pickers.
extension SeerrLookups on SeerrApi {
  Future<List<SeerrOption>> genres(SeerrMediaType type) async => [
        for (final g in await getList(type == SeerrMediaType.tv ? '/genres/tv' : '/genres/movie'))
          SeerrOption('${g['id']}', g['name'] as String),
      ];

  Future<List<SeerrOption>> languages() async => [
        for (final l in await getList('/languages'))
          SeerrOption(l['iso_639_1'] as String, (l['english_name'] as String?) ?? l['iso_639_1'] as String),
      ]..sort((a, b) => a.name.compareTo(b.name));

  Future<List<SeerrOption>> watchRegions() async => [
        for (final r in await getList('/watchproviders/regions'))
          SeerrOption(r['iso_3166_1'] as String, (r['english_name'] as String?) ?? r['iso_3166_1'] as String),
      ]..sort((a, b) => a.name.compareTo(b.name));

  Future<List<SeerrOption>> watchProviders(SeerrMediaType type, String region) async => [
        for (final p in await getList(
          type == SeerrMediaType.tv ? '/watchproviders/tv' : '/watchproviders/movies',
          query: {'watchRegion': region},
        ))
          SeerrOption('${p['id']}', p['name'] as String),
      ];

  Future<List<SeerrOption>> searchKeywords(String query) async => [
        for (final k in await getResults('/search/keyword', {'query': query}))
          SeerrOption('${k['id']}', k['name'] as String),
      ];

  /// Studios (production companies) by name.
  Future<List<SeerrOption>> searchCompanies(String query) async => [
        for (final c in await getResults('/search/company', {'query': query}))
          SeerrOption('${c['id']}', c['name'] as String),
      ];

  /// A TV network by its TMDB id (Seerr has no network search).
  Future<SeerrOption> network(int id) async {
    final n = await getMap('/network/$id');
    return SeerrOption('${n['id']}', n['name'] as String);
  }

  /// Age ratings by country code, in their usual order.
  Future<Map<String, List<String>>> certifications(SeerrMediaType type) async {
    final data = await getMap(type == SeerrMediaType.tv ? '/certifications/tv' : '/certifications/movie');
    final all = (data['certifications'] as Map?) ?? const {};
    return {
      for (final e in all.entries)
        e.key as String: ([for (final c in e.value as List) c as Map]
              ..sort((a, b) => ((a['order'] as num?) ?? 0).compareTo((b['order'] as num?) ?? 0)))
            .map((c) => c['certification'] as String)
            .toList(),
    };
  }

  /// The titles a custom row shows, from its source and filters.
  /// [page] > 1: more of the same (discover and trending sources).
  Future<List<SeerrMedia>> row(SeerrRowSpec spec, {DateTime? today, int page = 1}) async {
    final results = switch (spec.source) {
      SeerrSource.discoverTv => await discoverTv(spec.discoverQuery(today ?? DateTime.now()), page: page),
      SeerrSource.discoverMovies => await discoverMovies(spec.discoverQuery(today ?? DateTime.now()), page: page),
      SeerrSource.trending => await trendingOf(
          mediaType: spec.trendingType.name,
          timeWindow: spec.trendingWeek ? 'week' : 'day',
        ),
      SeerrSource.upcomingTv => await upcoming(SeerrMediaType.tv),
      SeerrSource.upcomingMovies => await upcoming(SeerrMediaType.movie),
      SeerrSource.watchlist => await watchlist(),
      // Need the library: built in features/home/recommendations.dart.
      SeerrSource.becauseYouWatched ||
      SeerrSource.recommendedForYou ||
      SeerrSource.pickedForYou =>
        throw UnsupportedError('${spec.source} is built from the library'),
    };
    return spec.hideAvailable
        ? [for (final m in results) if (m.status != SeerrMediaStatus.available) m]
        : results;
  }
}
