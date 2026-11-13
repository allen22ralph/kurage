import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/anime/mal_api.dart';
import 'package:jellyfin_client/core/anime/mal_auth.dart';
import 'package:jellyfin_client/core/anime/mal_sync.dart';

import '../../support/fake_server.dart';

MalAnime _anime({int? episodes = 12, MalStatus? status, int watched = 0, String? start, bool rewatching = false}) =>
    MalAnime(
      id: 1,
      title: 'Frieren',
      episodes: episodes,
      listStatus: MalListStatus(status: status, watchedEpisodes: watched, startDate: start, rewatching: rewatching),
    );

void main() {
  final today = DateTime(2026, 10, 27);

  group('planMalUpdate', () {
    test('first episode: watching, with a start date', () {
      expect(planMalUpdate(_anime(), 1, today), {
        'num_watched_episodes': '1',
        'status': 'watching',
        'start_date': '2026-10-27',
      });
    });

    test('keeps an existing start date', () {
      final plan = planMalUpdate(_anime(status: MalStatus.watching, watched: 3, start: '2026-01-01'), 4, today)!;
      expect(plan.containsKey('start_date'), isFalse);
      expect(plan['num_watched_episodes'], '4');
    });

    test('last episode completes it with a finish date', () {
      expect(planMalUpdate(_anime(status: MalStatus.watching, watched: 11, start: '2026-01-01'), 12, today), {
        'num_watched_episodes': '12',
        'status': 'completed',
        'finish_date': '2026-10-27',
      });
    });

    test('never lowers the count; leaves completed alone', () {
      expect(planMalUpdate(_anime(status: MalStatus.watching, watched: 8), 5, today), isNull);
      expect(planMalUpdate(_anime(status: MalStatus.watching, watched: 8), 8, today), isNull);
      expect(planMalUpdate(_anime(status: MalStatus.completed, watched: 12), 12, today), isNull);
    });

    test('a rewatch of a completed show still moves forward', () {
      final plan = planMalUpdate(
        _anime(status: MalStatus.completed, watched: 3, rewatching: true, start: '2025-01-01'),
        4,
        today,
      );
      expect(plan?['num_watched_episodes'], '4');
    });

    test('airing (unknown total): watching, never completed', () {
      expect(planMalUpdate(_anime(episodes: null), 30, today)!['status'], 'watching');
    });

    test('on hold or plan to watch: back to watching', () {
      expect(planMalUpdate(_anime(status: MalStatus.onHold, watched: 2, start: 'x'), 3, today)!['status'], 'watching');
      expect(planMalUpdate(_anime(status: MalStatus.planToWatch), 1, today)!['status'], 'watching');
    });
  });

  group('resolveMalEpisode', () {
    // Re:Zero season 2 aired as two MAL entries of 13 and 12 episodes.
    Future<int?> count(int id) async => {39587: 13, 42203: 12}[id];

    test('episodes of a split-cour season land in the right entry', () async {
      expect(await resolveMalEpisode([39587, 42203], 5, count), (39587, 5));
      expect(await resolveMalEpisode([39587, 42203], 13, count), (39587, 13));
      expect(await resolveMalEpisode([39587, 42203], 15, count), (42203, 2));
      expect(await resolveMalEpisode([61316], 7, count), (61316, 7));
    });

    test('an entry of unknown length keeps everything after it', () async {
      expect(await resolveMalEpisode([1, 2], 40, (_) async => null), (1, 40));
    });

    test('a show matched to its first cour only: past its end, on into the sequel', () async {
      // Chitose: matched to a 13-episode entry; its sequel (still airing) has no length yet.
      Future<int?> length(int id) async => {100: 13}[id];
      Future<int?> sequel(int id) async => {100: 200}[id];
      expect(await resolveMalEpisode([100], 14, length, sequelOf: sequel), (200, 1));
      expect(await resolveMalEpisode([100], 16, length, sequelOf: sequel), (200, 3));
      expect(await resolveMalEpisode([100], 13, length, sequelOf: sequel), (100, 13));
      expect(await resolveMalEpisode([100], 14, length), (100, 14), reason: 'without sequels, as before');
      expect(await resolveMalEpisode([200], 9, length, sequelOf: sequel), (200, 9), reason: 'unknown length: stays');
    });
  });

  group('planMalUnwatch', () {
    MalAnime anime(MalStatus status, int watched, {bool rewatching = false}) => MalAnime(
          id: 1,
          title: 'A',
          episodes: 12,
          listStatus: MalListStatus.fromJson({
            'status': status.api,
            'num_episodes_watched': watched,
            'is_rewatching': rewatching,
          }),
        );

    test('goes back to the episode before; completed becomes watching', () {
      expect(planMalUnwatch(anime(MalStatus.completed, 12), 12), {'num_watched_episodes': '11', 'status': 'watching'});
      expect(planMalUnwatch(anime(MalStatus.watching, 5), 3), {'num_watched_episodes': '2', 'status': 'watching'});
      expect(planMalUnwatch(anime(MalStatus.onHold, 5), 5)?['status'], 'on_hold');
    });

    test('does nothing for episodes MAL never counted', () {
      expect(planMalUnwatch(anime(MalStatus.watching, 5), 6), isNull);
    });
  });

  test('unwatching wins over an earlier watch and keeps the furthest back', () {
    var q = [const MalSyncJob(malId: 1, episode: 5, title: 'A')];
    q = enqueue(q, const MalSyncJob(malId: 1, episode: 5, title: 'A', unwatched: true));
    q = enqueue(q, const MalSyncJob(malId: 1, episode: 3, title: 'A', unwatched: true));
    q = enqueue(q, const MalSyncJob(malId: 1, episode: 4, title: 'A', unwatched: true));
    expect([for (final j in q) (j.episode, j.unwatched)], [(3, true)]);
    final round = MalSyncJob.fromJson(q.single.toJson());
    expect((round.episode, round.unwatched), (3, true));
  });

  test('the queue keeps the furthest episode per anime', () {
    var q = <MalSyncJob>[];
    q = enqueue(q, const MalSyncJob(malId: 1, episode: 3, title: 'A'));
    q = enqueue(q, const MalSyncJob(malId: 2, episode: 1, title: 'B'));
    q = enqueue(q, const MalSyncJob(malId: 1, episode: 5, title: 'A'));
    q = enqueue(q, const MalSyncJob(malId: 1, episode: 4, title: 'A'));
    expect([for (final j in q) (j.malId, j.episode)], [(2, 1), (1, 5)]);
  });

  group('MalAuth', () {
    test('authorize URL uses PKCE plain with the loopback redirect', () {
      final auth = MalAuth(clientId: 'cid', random: Random(1));
      final verifier = auth.newVerifier();
      expect(verifier.length, inInclusiveRange(43, 128));
      expect(verifier, matches(RegExp(r'^[A-Za-z0-9\-._~]+$')));
      final uri = auth.authorizeUri(verifier: verifier, state: 'st');
      expect(uri.queryParameters, {
        'response_type': 'code',
        'client_id': 'cid',
        'code_challenge': verifier,
        'code_challenge_method': 'plain',
        'state': 'st',
        'redirect_uri': 'http://localhost:53682/callback',
      });
    });

    test('catches the redirect; rejects a wrong state', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final code = MalAuth.waitForCode(server, 'good');
      final client = HttpClient();
      Future<int> get(String path) async {
        final r = await (await client.get('127.0.0.1', server.port, path)).close();
        await r.drain<void>();
        return r.statusCode;
      }

      expect(await get('/favicon.ico'), 404);
      expect(await get('/callback?code=abc&state=good'), 200);
      expect(await code, 'abc');
      await server.close(force: true);

      final server2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bad = MalAuth.waitForCode(server2, 'good');
      final failed = expectLater(bad, throwsA(isA<MalAuthException>()));
      final r = await (await client.get('127.0.0.1', server2.port, '/callback?code=x&state=evil')).close();
      await r.drain<void>();
      await failed;
      await server2.close(force: true);
      client.close();
    });

    test('exchanges the code and refreshes tokens', () async {
      final server = FakeServer({
        'https://myanimelist.net/v1/oauth2/token': (RequestOptions o) {
          final form = o.data as Map;
          return (
            200,
            {
              'access_token': form['grant_type'] == 'refresh_token' ? 'access2' : 'access1',
              'refresh_token': 'refresh',
              'expires_in': 3600,
            },
          );
        },
      });
      final now = DateTime(2026, 10, 27, 12);
      final auth = MalAuth(clientId: 'cid', dio: Dio()..httpClientAdapter = server, now: () => now);

      final tokens = await auth.exchangeCode('abc', 'verifier');
      final form = server.requests.single.data as Map;
      expect(form, {
        'client_id': 'cid',
        'grant_type': 'authorization_code',
        'code': 'abc',
        'redirect_uri': 'http://localhost:53682/callback',
        'code_verifier': 'verifier',
      });
      expect(tokens.accessToken, 'access1');
      expect(tokens.expiresAt, now.add(const Duration(hours: 1)));
      expect(tokens.expiredAt(now.add(const Duration(minutes: 56))), isTrue, reason: 'refresh early');

      expect((await auth.refresh(tokens)).accessToken, 'access2');
      expect(MalAuth.decode(MalAuth.encode(tokens)).refreshToken, 'refresh');
    });
  });

  test('MalApi reads list status and patches it as a form', () async {
    final server = FakeServer({
      'GET /v2/anime/52991': (
        200,
        {
          'id': 52991,
          'title': 'Sousou no Frieren',
          'num_episodes': 28,
          'my_list_status': {'status': 'watching', 'num_episodes_watched': 4, 'start_date': '2026-01-02'},
        },
      ),
      'PATCH /v2/anime/52991/my_list_status': (200, {}),
    });
    final api = MalApi(
      accessToken: () async => 'tok',
      dio: Dio(BaseOptions(baseUrl: 'https://api.myanimelist.net/v2'))..httpClientAdapter = server,
    );
    final anime = await api.anime(52991);
    expect((anime.episodes, anime.listStatus.status, anime.listStatus.watchedEpisodes), (28, MalStatus.watching, 4));
    expect(server.requests.first.headers['Authorization'], 'Bearer tok');

    await api.updateListStatus(52991, {'num_watched_episodes': '5', 'status': 'watching'});
    final patch = server.requests.last;
    expect(patch.method, 'PATCH');
    expect(patch.data, {'num_watched_episodes': '5', 'status': 'watching'});
    expect(patch.contentType, Headers.formUrlEncodedContentType);
  });
}
