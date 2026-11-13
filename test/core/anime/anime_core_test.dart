import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/anime/anime_ids.dart';
import 'package:jellyfin_client/core/anime/anime_info.dart';
import 'package:jellyfin_client/core/anime/anime_matcher.dart';

import '../../support/fake_server.dart';

/// Real entries from Fribb/anime-lists: Re:Zero (TVDB 305089) with its
/// split-cour season 2, an OVA sharing the TVDB ID, and a movie.
final _fribb = [
  {'type': 'TV', 'anidb_id': 11370, 'anilist_id': 21355, 'mal_id': 31240, 'tvdb_id': 305089, 'themoviedb_id': {'tv': 65942}, 'season': {'tvdb': 1, 'tmdb': 1}},
  {'type': 'OVA', 'anidb_id': 13430, 'mal_id': null, 'tvdb_id': 305089, 'season': {'tvdb': 0, 'tmdb': 0}},
  {'type': 'TV', 'anidb_id': 15593, 'mal_id': 42203, 'tvdb_id': 305089, 'themoviedb_id': {'tv': 65942}, 'season': {'tvdb': 2, 'tmdb': 1}},
  {'type': 'TV', 'anidb_id': 14792, 'mal_id': 39587, 'tvdb_id': 305089, 'themoviedb_id': {'tv': 65942}, 'season': {'tvdb': 2, 'tmdb': 1}},
  {'type': 'Special', 'anidb_id': 15000, 'mal_id': 99999, 'tvdb_id': 305089, 'season': {'tvdb': 2}},
  {'type': 'TV', 'anidb_id': 19242, 'mal_id': 61316, 'tvdb_id': 305089, 'season': {'tvdb': 4, 'tmdb': 1}},
  {'type': 'Movie', 'anidb_id': 16000, 'mal_id': 50000, 'themoviedb_id': {'movie': 777}},
];

void main() {
  final mapping = AnimeIdMapping.fromFribb(_fribb);

  group('AnimeIdMapping', () {
    test('indexes every ID kind', () {
      expect(mapping.malForAnidb(11370), 31240);
      expect(mapping.malForAnilist(21355), 31240);
      expect(mapping.malForTmdbMovie(777), 50000);
      expect(mapping.malForAnidb(13430), isNull, reason: 'no MAL entry');
    });

    test('a split-cour TVDB season lists both parts, TV before specials', () {
      expect(mapping.malForTvdb(305089, 2), [39587, 42203, 99999]);
      expect(mapping.malForTvdb(305089, 4), [61316]);
      expect(mapping.malForTvdb(305089, 9), isEmpty);
    });

    test('round-trips through its compact cache form', () {
      final again = AnimeIdMapping.fromJson(
        jsonDecode(jsonEncode(mapping.toJson())) as Map<String, dynamic>,
      );
      expect(again.malForAnidb(11370), 31240);
      expect(again.malForTvdb(305089, 2), [39587, 42203, 99999]);
      expect(again.malForTmdbMovie(777), 50000);
    });
  });

  group('matchMal', () {
    const series = {'AniDB': '11370', 'Tvdb': '305089', 'Tmdb': '65942'};

    test('a manual match wins', () {
      final m = matchMal(const MatchInput(ids: series), mapping, manual: 123);
      expect((m!.malId, m.source), (123, MatchSource.manual));
    });

    test('a whole series and its first season use the series AniDB ID', () {
      expect(matchMal(const MatchInput(ids: series), mapping)!.source, MatchSource.anidb);
      final s1 = matchMal(const MatchInput(seriesIds: series, seasonNumber: 1), mapping)!;
      expect((s1.malId, s1.source), (31240, MatchSource.anidb));
    });

    test('later seasons use TVDB + season, not the series AniDB ID', () {
      final s4 = matchMal(const MatchInput(seriesIds: series, seasonNumber: 4), mapping)!;
      expect((s4.malId, s4.source), (61316, MatchSource.tvdb));
      final s2 = matchMal(const MatchInput(seriesIds: series, seasonNumber: 2), mapping)!;
      expect(s2.entries, [39587, 42203, 99999]);
    });

    test("a season's own AniDB ID beats everything but manual", () {
      final m = matchMal(
        const MatchInput(ids: {'AniDB': '15593'}, seriesIds: series, seasonNumber: 2),
        mapping,
      )!;
      expect((m.malId, m.source), (42203, MatchSource.anidb));
    });

    test("series IDs copied onto a season don't count as the season's", () {
      final m = matchMal(const MatchInput(ids: series, seriesIds: series, seasonNumber: 4), mapping)!;
      expect(m.malId, 61316);
    });

    test('provider keys are case-insensitive; movies match by TMDB', () {
      expect(matchMal(const MatchInput(ids: {'anilist': '21355'}), mapping)!.malId, 31240);
      final movie = matchMal(const MatchInput(ids: {'Tmdb': '777'}, isMovie: true), mapping)!;
      expect((movie.malId, movie.source), (50000, MatchSource.tmdb));
    });

    test('nothing known: no match', () {
      expect(matchMal(const MatchInput(ids: {'Imdb': 'tt1'}), mapping), isNull);
      expect(matchMal(const MatchInput(seriesIds: {'Tvdb': '1'}, seasonNumber: 3), mapping), isNull);
    });
  });

  group('AnimeIdMappingSource', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('anime-ids'));
    tearDown(() => dir.delete(recursive: true));

    test('downloads once, then serves the cache; stale cache when offline', () async {
      var now = DateTime(2026, 10, 27);
      var online = true;
      final server = FakeServer({
        AnimeIdMappingSource.url: (_) => online ? (200, _fribb) : unreachable,
      });
      AnimeIdMappingSource source() => AnimeIdMappingSource(
            cacheDir: dir,
            dio: Dio()..httpClientAdapter = server,
            now: () => now,
          );

      expect((await source().load()).malForAnidb(11370), 31240);
      expect((await source().load()).malForAnidb(11370), 31240);
      expect(server.requests, hasLength(1), reason: 'second load from cache');

      now = now.add(const Duration(days: 8));
      online = false;
      expect((await source().load()).malForAnidb(11370), 31240, reason: 'stale beats none');
      expect(server.requests, hasLength(2));
    });
  });

  group('JikanApi', () {
    Map<String, Object?> anime(int id, {double score = 8.2}) => {
          'data': {
            'mal_id': id,
            'title': 'Re:Zero kara Hajimeru Isekai Seikatsu',
            'title_english': 'Re:ZERO -Starting Life in Another World-',
            'title_japanese': 'Re：ゼロから始める異世界生活',
            'score': score,
            'rank': 400,
            'popularity': 20,
            'members': 2500000,
            'episodes': 25,
            'type': 'TV',
            'images': {'jpg': {'image_url': 'https://cdn.myanimelist.net/x.jpg'}},
          },
        };

    test('parses an anime and retries after "too many requests"', () async {
      var calls = 0;
      final server = FakeServer({
        '/v4/anime/31240': (_) => ++calls == 1 ? (429, null) : (200, anime(31240)),
      });
      final api = JikanApi(
        dio: Dio(BaseOptions(baseUrl: 'https://api.jikan.moe/v4'))..httpClientAdapter = server,
        spacing: Duration.zero,
      );
      final info = await api.anime(31240);
      expect(calls, 2);
      expect(info.title, startsWith('Re:Zero'));
      expect(info.titleEnglish, startsWith('Re:ZERO'));
      expect(info.score, 8.2);
      expect(info.episodes, 25);
      expect(info.url.toString(), 'https://myanimelist.net/anime/31240');
    });

    test('spaces requests out', () async {
      final server = FakeServer({'/v4/anime/1': (200, anime(1)), '/v4/anime/2': (200, anime(2))});
      final api = JikanApi(
        dio: Dio(BaseOptions(baseUrl: 'https://api.jikan.moe/v4'))..httpClientAdapter = server,
        spacing: const Duration(milliseconds: 150),
      );
      final watch = Stopwatch()..start();
      await Future.wait([api.anime(1), api.anime(2)]);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(140));
    });
  });

  group('AnimeInfoCache', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('anime-info'));
    tearDown(() => dir.delete(recursive: true));

    test('survives restarts and ages entries', () async {
      var now = DateTime(2026, 10, 27);
      const info = AnimeInfo(malId: 31240, title: 'Re:Zero', score: 8.2);
      final cache = AnimeInfoCache(cacheDir: dir, now: () => now);
      await cache.put(info);
      await Future<void>.delayed(const Duration(milliseconds: 600)); // write-behind

      final reopened = AnimeInfoCache(cacheDir: dir, now: () => now);
      expect((await reopened.get(31240))!.info.score, 8.2);
      expect((await reopened.get(31240))!.fresh, isTrue);
      now = now.add(const Duration(days: 4));
      expect((await reopened.get(31240))!.fresh, isFalse);
      expect(await reopened.get(1), isNull);
    });
  });
}
