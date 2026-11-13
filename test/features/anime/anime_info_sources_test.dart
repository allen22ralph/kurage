import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/anime/anime_info.dart';
import 'package:jellyfin_client/core/anime/episode_scores.dart';
import 'package:jellyfin_client/features/anime/anime_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

/// The Apothecary Diaries as the official MAL API returns it.
const _mal = {
  'id': 54492,
  'title': 'Kusuriya no Hitorigoto',
  'alternative_titles': {'en': 'The Apothecary Diaries', 'ja': '薬屋のひとりごと', 'synonyms': []},
  'mean': 8.87,
  'num_scoring_users': 300000,
  'rank': 40,
  'popularity': 300,
  'num_list_users': 900000,
  'num_episodes': 24,
  'media_type': 'tv',
  'main_picture': {'medium': 'https://cdn.myanimelist.net/m.jpg'},
};

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(signedInStorage()));

  test('MalInfoApi parses details and search, sending the client ID', () async {
    final server = FakeServer({
      '/v2/anime/54492': (200, _mal),
      '/v2/anime': (200, {
        'data': [
          {'node': _mal},
        ],
      }),
    });
    final api = MalInfoApi(
      clientId: 'abc',
      dio: Dio(BaseOptions(baseUrl: 'https://api.myanimelist.net/v2'))..httpClientAdapter = server,
    );
    final info = await api.anime(54492);
    expect((info.title, info.titleEnglish, info.score, info.episodes, info.type),
        ('Kusuriya no Hitorigoto', 'The Apothecary Diaries', 8.87, 24, 'TV'));
    expect(server.requests.single.headers['X-MAL-CLIENT-ID'], 'abc');
    expect((await api.search('apothecary')).single.malId, 54492);
  });

  ProviderContainer container(FakeServer server) {
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    return c;
  }

  test('scores come from the official API once there is a client ID', () async {
    SharedPreferences.setMockInitialValues({'anime.malClientId': 'abc'});
    final server = FakeServer({'/v2/anime/54492': (200, _mal)});
    final info = await container(server).read(animeInfoProvider(54492).future);
    expect(info?.score, 8.87);
    expect(server.requestsTo('/v4/anime/54492'), isEmpty, reason: 'Jikan not needed');
  });

  test('falls back to Jikan when the official API fails (and without a client ID)', () async {
    final jikan = {
      'data': {'mal_id': 54492, 'title': 'Kusuriya no Hitorigoto', 'score': 8.8},
    };
    SharedPreferences.setMockInitialValues({'anime.malClientId': 'abc'});
    var server = FakeServer({'/v2/anime/54492': (500, null), '/v4/anime/54492': (200, jikan)});
    expect((await container(server).read(animeInfoProvider(54492).future))?.score, 8.8);

    SharedPreferences.setMockInitialValues({});
    server = FakeServer({'/v4/anime/54492': (200, jikan)});
    expect((await container(server).read(animeInfoProvider(54492).future))?.score, 8.8);
    expect(server.requestsTo('/v2/anime/54492'), isEmpty);
  });

  group('episode ratings', () {
    final page = File('test/fixtures/mal_episodes.html').readAsStringSync();

    test('reads titles and the Poll column of a real MAL Episodes page', () {
      final eps = parseMalEpisodePage(page);
      expect(eps.keys, [1, 19]);
      expect([for (final e in eps.values) e.score], [4.30, 4.76]);
      final e19 = eps[19]!;
      expect((e19.title, e19.romaji, e19.japanese), ('Chance or Something More', 'Guuzen ka Hitsuzen ka', '偶然か必然か'));
      expect(parseMalEpisodePage('<html>changed layout</html>'), isEmpty);
    });

    EpisodeScoresApi api(FakeServer server) => EpisodeScoresApi(
          site: Dio(BaseOptions(baseUrl: 'https://myanimelist.net'))..httpClientAdapter = server,
          jikan: JikanApi(
            dio: Dio(BaseOptions(baseUrl: 'https://api.jikan.moe/v4'))..httpClientAdapter = server,
            spacing: Duration.zero,
          ),
        );

    test('fetches only the page of 100 holding the episode', () async {
      final server = FakeServer({'/anime/21/_/episode': (200, page)});
      await api(server).page(21, 1050);
      expect(server.requests.single.queryParameters['offset'], 1000);
    });

    test('falls back to Jikan when the page fails', () async {
      final server = FakeServer({
        '/anime/54492/_/episode': (503, null),
        '/v4/anime/54492/episodes': (200, {
          'data': [
            {'mal_id': 1, 'score': 4.3, 'title': 'Maomao', 'title_romanji': 'Maomao', 'title_japanese': '猫猫'},
            {'mal_id': 2, 'score': null},
          ],
        }),
      });
      final eps = await api(server).page(54492, 1);
      expect((eps[1]!.score, eps[1]!.japanese, eps[2]!.score), (4.3, '猫猫', null));
    });
  });
}
