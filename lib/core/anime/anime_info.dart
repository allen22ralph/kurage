import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'episode_scores.dart';
import '../log/app_log.dart';
import '../log/log_interceptor.dart';

/// What the app shows about an anime from MyAnimeList.
class AnimeInfo {
  const AnimeInfo({
    required this.malId,
    required this.title,
    this.titleEnglish,
    this.titleJapanese,
    this.score,
    this.scoredBy,
    this.rank,
    this.popularity,
    this.members,
    this.episodes,
    this.type,
    this.imageUrl,
  });

  /// From a Jikan v4 `/anime/{id}` (or search result) `data` object.
  factory AnimeInfo.fromJikan(Map<String, dynamic> d) => AnimeInfo(
        malId: d['mal_id'] as int,
        title: d['title'] as String? ?? '',
        titleEnglish: d['title_english'] as String?,
        titleJapanese: d['title_japanese'] as String?,
        score: (d['score'] as num?)?.toDouble(),
        scoredBy: d['scored_by'] as int?,
        rank: d['rank'] as int?,
        popularity: d['popularity'] as int?,
        members: d['members'] as int?,
        episodes: d['episodes'] as int?,
        type: d['type'] as String?,
        imageUrl: (d['images'] as Map?)?['jpg']?['image_url'] as String?,
      );

  /// From an official MAL API v2 anime object (with [MalInfoApi.fields]).
  factory AnimeInfo.fromMal(Map<String, dynamic> d) {
    final alt = d['alternative_titles'] as Map?;
    String? nonEmpty(Object? s) => s is String && s.isNotEmpty ? s : null;
    final episodes = (d['num_episodes'] as num?)?.toInt();
    return AnimeInfo(
      malId: d['id'] as int,
      title: d['title'] as String? ?? '',
      titleEnglish: nonEmpty(alt?['en']),
      titleJapanese: nonEmpty(alt?['ja']),
      score: (d['mean'] as num?)?.toDouble(),
      scoredBy: (d['num_scoring_users'] as num?)?.toInt(),
      rank: (d['rank'] as num?)?.toInt(),
      popularity: (d['popularity'] as num?)?.toInt(),
      members: (d['num_list_users'] as num?)?.toInt(),
      episodes: episodes == 0 ? null : episodes,
      type: _malTypes[d['media_type']] ?? (d['media_type'] as String?)?.toUpperCase(),
      imageUrl: (d['main_picture'] as Map?)?['medium'] as String?,
    );
  }

  /// MAL v2 media types, spelled as Jikan (and the MAL site) show them.
  static const _malTypes = {
    'tv': 'TV',
    'movie': 'Movie',
    'ova': 'OVA',
    'ona': 'ONA',
    'special': 'Special',
    'tv_special': 'TV Special',
    'music': 'Music',
    'cm': 'CM',
    'pv': 'PV',
  };

  factory AnimeInfo.fromJson(Map<String, dynamic> j) => AnimeInfo(
        malId: j['malId'] as int,
        title: j['title'] as String,
        titleEnglish: j['titleEnglish'] as String?,
        titleJapanese: j['titleJapanese'] as String?,
        score: (j['score'] as num?)?.toDouble(),
        scoredBy: j['scoredBy'] as int?,
        rank: j['rank'] as int?,
        popularity: j['popularity'] as int?,
        members: j['members'] as int?,
        episodes: j['episodes'] as int?,
        type: j['type'] as String?,
        imageUrl: j['imageUrl'] as String?,
      );

  final int malId;

  /// MAL's main title (usually Romaji).
  final String title;
  final String? titleEnglish;
  final String? titleJapanese;
  final double? score;
  final int? scoredBy;
  final int? rank;
  final int? popularity;
  final int? members;

  /// Total episodes, null while airing with no announced count.
  final int? episodes;
  final String? type;
  final String? imageUrl;

  Uri get url => Uri.parse('https://myanimelist.net/anime/$malId');

  Map<String, dynamic> toJson() => {
        'malId': malId,
        'title': title,
        'titleEnglish': titleEnglish,
        'titleJapanese': titleJapanese,
        'score': score,
        'scoredBy': scoredBy,
        'rank': rank,
        'popularity': popularity,
        'members': members,
        'episodes': episodes,
        'type': type,
        'imageUrl': imageUrl,
      };
}

/// Where MAL details come from: the official API or Jikan.
abstract interface class AnimeInfoSource {
  Future<AnimeInfo> anime(int malId);
  Future<List<AnimeInfo>> search(String query);
}

/// The official MyAnimeList API with just a client ID (no user sign-in).
class MalInfoApi implements AnimeInfoSource {
  MalInfoApi({required String clientId, Dio? dio})
      : _dio = (dio ?? Dio(BaseOptions(baseUrl: 'https://api.myanimelist.net/v2')))
          ..options.headers['X-MAL-CLIENT-ID'] = clientId;

  final Dio _dio;

  static const fields = 'id,title,alternative_titles,mean,num_scoring_users,rank,popularity,'
      'num_list_users,num_episodes,media_type,main_picture';

  @override
  Future<AnimeInfo> anime(int malId) async {
    final r = await _dio.get<Map<String, dynamic>>('/anime/$malId', queryParameters: {'fields': fields});
    return AnimeInfo.fromMal(r.data!);
  }

  @override
  Future<List<AnimeInfo>> search(String query) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/anime',
      queryParameters: {'q': query, 'limit': 10, 'fields': fields},
    );
    return [
      for (final e in r.data!['data'] as List) AnimeInfo.fromMal((e as Map)['node'] as Map<String, dynamic>),
    ];
  }
}

/// Jikan (unofficial MyAnimeList API, no key). Requests are spaced to stay
/// within its rate limit (3/s, 60/min) and retried on HTTP 429.
class JikanApi implements AnimeInfoSource {
  JikanApi({Dio? dio, this.spacing = const Duration(milliseconds: 1100)})
      : _dio = (dio ?? Dio(BaseOptions(baseUrl: 'https://api.jikan.moe/v4')))
          ..interceptors.add(AppLogInterceptor(LogArea.anime));

  final Dio _dio;

  /// Minimum gap between requests (≈55/min, under Jikan's 60/min).
  final Duration spacing;
  Future<void> _queue = Future.value();

  @override
  Future<AnimeInfo> anime(int malId) async {
    final data = await _get('/anime/$malId');
    return AnimeInfo.fromJikan(data['data'] as Map<String, dynamic>);
  }

  @override
  Future<List<AnimeInfo>> search(String query) async {
    final data = await _get('/anime', query: {'q': query, 'limit': 10, 'sfw': true});
    return [
      for (final d in data['data'] as List) AnimeInfo.fromJikan(d as Map<String, dynamic>),
    ];
  }

  /// Episode titles and community ratings (1–5), one page of 100.
  /// The entry MAL lists as [malId]'s sequel (its next cour or season);
  /// null when there's none.
  Future<int?> sequel(int malId) async {
    final data = await _get('/anime/$malId/relations');
    for (final relation in data['data'] as List? ?? const []) {
      if ((relation as Map)['relation'] != 'Sequel') continue;
      for (final entry in relation['entry'] as List? ?? const []) {
        if ((entry as Map)['type'] == 'anime') return entry['mal_id'] as int?;
      }
    }
    return null;
  }

  Future<Map<int, MalEpisode>> episodes(int malId, {int page = 1}) async {
    final data = await _get('/anime/$malId/episodes', query: {'page': page});
    String? text(Object? s) => s is String && s.trim().isNotEmpty ? s.trim() : null;
    return {
      for (final e in (data['data'] as List).cast<Map<String, dynamic>>())
        e['mal_id'] as int: MalEpisode(
          score: switch (e['score']) {
            final num s when s > 0 => s.toDouble(),
            _ => null,
          },
          title: text(e['title']),
          romaji: text(e['title_romanji']),
          japanese: text(e['title_japanese']),
        ),
    };
  }

  Future<Map<String, dynamic>> _get(String path, {Map<String, Object?>? query}) {
    final result = _queue.then((_) => _send(path, query));
    // The next request waits for this one plus the spacing.
    _queue = result.then((_) {}, onError: (_) {}).then((_) => Future<void>.delayed(spacing));
    return result;
  }

  Future<Map<String, dynamic>> _send(String path, Map<String, Object?>? query) async {
    for (var attempt = 0;; attempt++) {
      try {
        final r = await _dio.get<Map<String, dynamic>>(path, queryParameters: query);
        return r.data!;
      } on DioException catch (e) {
        if (e.response?.statusCode == 429 && attempt < 3) {
          await Future<void>.delayed(Duration(seconds: 2 << attempt));
          continue;
        }
        rethrow;
      }
    }
  }
}

/// MAL details cached on disk, so scores show instantly and Jikan isn't
/// asked again for [maxAge]. Without a [cacheDir] it only keeps them in
/// memory (tests).
class AnimeInfoCache {
  AnimeInfoCache({this.cacheDir, this.maxAge = const Duration(days: 3), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Directory? cacheDir;
  final Duration maxAge;
  final DateTime Function() _now;
  Map<int, (DateTime, AnimeInfo)>? _entries;
  Future<void>? _saving;

  File? get _file =>
      cacheDir == null ? null : File('${cacheDir!.path}${Platform.pathSeparator}anime-info.json');

  Future<Map<int, (DateTime, AnimeInfo)>> _load() async {
    if (_entries case final e?) return e;
    final entries = <int, (DateTime, AnimeInfo)>{};
    final file = _file;
    try {
      if (file != null && await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final e in json.entries) {
          final v = e.value as Map<String, dynamic>;
          entries[int.parse(e.key)] = (
            DateTime.parse(v['at'] as String),
            AnimeInfo.fromJson(v['info'] as Map<String, dynamic>),
          );
        }
      }
    } on Object {
      // A damaged cache is simply rebuilt.
    }
    return _entries = entries;
  }

  /// Cached info, fresh or not ([fresh] false = refetch when possible).
  Future<({AnimeInfo info, bool fresh})?> get(int malId) async {
    final hit = (await _load())[malId];
    if (hit == null) return null;
    return (info: hit.$2, fresh: _now().difference(hit.$1) < maxAge);
  }

  Future<void> put(AnimeInfo info) async {
    (await _load())[info.malId] = (_now(), info);
    final file = _file;
    if (file == null) return;
    // Coalesce bursts of writes (a screen full of cards) into one.
    _saving ??= Future<void>.delayed(const Duration(milliseconds: 500), () async {
      _saving = null;
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        for (final e in _entries!.entries)
          '${e.key}': {'at': e.value.$1.toIso8601String(), 'info': e.value.$2.toJson()},
      }));
    });
  }
}
