import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';

/// Cross-reference of anime database IDs, built from Fribb/anime-lists
/// (AniDB, AniList, TVDB, TMDB → MyAnimeList).
///
/// A TVDB season can hold several MAL entries (a split-cour season is two
/// MAL entries); [malForTvdb] returns them in airing order.
class AnimeIdMapping {
  const AnimeIdMapping({
    this.byAnidb = const {},
    this.byAnilist = const {},
    this.byTvdbSeason = const {},
    this.byTmdbTvSeason = const {},
    this.byTmdbMovie = const {},
  });

  /// Builds the index from the upstream list (`anime-list-full.json`).
  factory AnimeIdMapping.fromFribb(List<dynamic> entries) {
    final anidb = <int, int>{};
    final anilist = <int, int>{};
    final tvdb = <String, List<(int, int, bool)>>{}; // (anidb, mal, isTv)
    final tmdbTv = <String, List<(int, int, bool)>>{};
    final tmdbMovie = <int, int>{};

    for (final e in entries.cast<Map<String, dynamic>>()) {
      final mal = e['mal_id'];
      if (mal is! int) continue;
      final anidbId = e['anidb_id'];
      final isTv = e['type'] == 'TV';
      if (anidbId is int) anidb[anidbId] = mal;
      if (e['anilist_id'] case final int id) anilist[id] = mal;
      final season = e['season'];
      final order = anidbId is int ? anidbId : 1 << 30;
      if (e['tvdb_id'] case final int id) {
        final s = season is Map ? season['tvdb'] : null;
        if (s is int) (tvdb['$id:$s'] ??= []).add((order, mal, isTv));
      }
      if (e['themoviedb_id'] case {'tv': final int id}) {
        final s = season is Map ? season['tmdb'] : null;
        if (s is int) (tmdbTv['$id:$s'] ??= []).add((order, mal, isTv));
      }
      if (e['themoviedb_id'] case {'movie': final int id}) tmdbMovie[id] = mal;
    }

    // TV entries first (OVAs/specials share TVDB seasons), then airing
    // order (AniDB IDs grow over time).
    List<int> ordered(List<(int, int, bool)> list) {
      list.sort((a, b) => a.$3 != b.$3 ? (a.$3 ? -1 : 1) : a.$1.compareTo(b.$1));
      return [for (final (_, mal, _) in list) mal];
    }

    return AnimeIdMapping(
      byAnidb: anidb,
      byAnilist: anilist,
      byTvdbSeason: {for (final e in tvdb.entries) e.key: ordered(e.value)},
      byTmdbTvSeason: {for (final e in tmdbTv.entries) e.key: ordered(e.value)},
      byTmdbMovie: tmdbMovie,
    );
  }

  factory AnimeIdMapping.fromJson(Map<String, dynamic> json) {
    Map<int, int> ints(Object? m) => {
          for (final e in (m as Map<String, dynamic>).entries) int.parse(e.key): e.value as int,
        };
    Map<String, List<int>> lists(Object? m) => {
          for (final e in (m as Map<String, dynamic>).entries)
            e.key: [for (final v in e.value as List) v as int],
        };
    return AnimeIdMapping(
      byAnidb: ints(json['anidb']),
      byAnilist: ints(json['anilist']),
      byTvdbSeason: lists(json['tvdb']),
      byTmdbTvSeason: lists(json['tmdbTv']),
      byTmdbMovie: ints(json['tmdbMovie']),
    );
  }

  final Map<int, int> byAnidb;
  final Map<int, int> byAnilist;
  final Map<String, List<int>> byTvdbSeason;
  final Map<String, List<int>> byTmdbTvSeason;
  final Map<int, int> byTmdbMovie;

  bool get isEmpty => byAnidb.isEmpty && byTvdbSeason.isEmpty;

  int? malForAnidb(int id) => byAnidb[id];
  int? malForAnilist(int id) => byAnilist[id];
  List<int> malForTvdb(int id, int season) => byTvdbSeason['$id:$season'] ?? const [];
  List<int> malForTmdbTv(int id, int season) => byTmdbTvSeason['$id:$season'] ?? const [];
  int? malForTmdbMovie(int id) => byTmdbMovie[id];

  Map<String, dynamic> toJson() => {
        'anidb': {for (final e in byAnidb.entries) '${e.key}': e.value},
        'anilist': {for (final e in byAnilist.entries) '${e.key}': e.value},
        'tvdb': byTvdbSeason,
        'tmdbTv': byTmdbTvSeason,
        'tmdbMovie': {for (final e in byTmdbMovie.entries) '${e.key}': e.value},
      };
}

/// Loads the mapping: a compact cached index if fresh, else the upstream
/// list (≈7.5 MB, parsed off the UI isolate), falling back to a stale
/// cache when offline.
class AnimeIdMappingSource {
  AnimeIdMappingSource({
    required this.cacheDir,
    Dio? dio,
    this.maxAge = const Duration(days: 7),
    DateTime Function()? now,
  })  : _dio = dio ?? Dio(),
        _now = now ?? DateTime.now;

  static const url =
      'https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json';

  final Directory cacheDir;
  final Duration maxAge;
  final Dio _dio;
  final DateTime Function() _now;

  File get _file => File('${cacheDir.path}${Platform.pathSeparator}anime-ids.json');

  Future<AnimeIdMapping> load() async {
    final cached = await _readCache();
    if (cached != null && _now().difference(cached.$1) < maxAge) return cached.$2;
    try {
      final response = await _dio.get<String>(url, options: Options(responseType: ResponseType.plain));
      final body = response.data!;
      final mapping = await Isolate.run(
        () => AnimeIdMapping.fromFribb(jsonDecode(body) as List<dynamic>).toJson(),
      );
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode({'fetchedAt': _now().toIso8601String(), ...mapping}));
      return AnimeIdMapping.fromJson(mapping);
    } on Object {
      // Offline or the list moved: a week-old index beats none.
      if (cached != null) return cached.$2;
      rethrow;
    }
  }

  Future<(DateTime, AnimeIdMapping)?> _readCache() async {
    try {
      if (!await _file.exists()) return null;
      final json = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      return (DateTime.parse(json['fetchedAt'] as String), AnimeIdMapping.fromJson(json));
    } on Object {
      return null;
    }
  }
}
