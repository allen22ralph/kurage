import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/anime/anime_ids.dart';
import 'package:jellyfin_client/core/anime/mal_auth.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/features/anime/mal_account.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

/// Re:Zero: season 1 is one MAL entry; season 2 aired as two (13 + 12).
final _mapping = AnimeIdMapping.fromFribb([
  {'type': 'TV', 'anidb_id': 11370, 'mal_id': 31240, 'tvdb_id': 305089, 'season': {'tvdb': 1}},
  {'type': 'TV', 'anidb_id': 14792, 'mal_id': 39587, 'tvdb_id': 305089, 'season': {'tvdb': 2}},
  {'type': 'TV', 'anidb_id': 15593, 'mal_id': 42203, 'tvdb_id': 305089, 'season': {'tvdb': 2}},
]);

String _account({DateTime? expiresAt}) => jsonEncode({
      'username': 'sam',
      'tokens': MalAuth.encode(MalTokens(
        accessToken: 'tok',
        refreshToken: 'refresh',
        expiresAt: expiresAt ?? DateTime.now().add(const Duration(days: 30)),
      )),
    });

BaseItem _episode(String season, int seasonNumber, int number, {bool played = true}) => BaseItem.fromJson({
      'Id': 'ep$seasonNumber-$number',
      'Name': 'Episode $number',
      'Type': 'Episode',
      'SeriesId': 'rz',
      'SeriesName': 'Re:Zero',
      'SeasonId': season,
      'ParentIndexNumber': seasonNumber,
      'IndexNumber': number,
      'UserData': {'Played': played},
    });

void main() {
  late FakeServer server;
  late Map<int, Map<String, Object?>> malList; // MAL's view of the user's list
  late bool malOnline;

  setUp(() {
    malOnline = true;
    malList = {};
    final ids = {'AniDB': '11370', 'Tvdb': '305089'};
    server = FakeServer({
      '/Items/rz': (200, itemJson('rz', 'Re:Zero', type: 'Series', extra: {'ProviderIds': ids})),
      '/Items/s1': (200, itemJson('s1', 'Season 1', type: 'Season', extra: {'ProviderIds': ids})),
      '/Items/s2': (200, itemJson('s2', 'Season 2', type: 'Season', extra: {'ProviderIds': ids})),
      'https://myanimelist.net/v1/oauth2/token': (200, {'access_token': 'tok2', 'refresh_token': 'r2', 'expires_in': 3600}),
    });
    for (final (id, episodes) in [(31240, 25), (39587, 13), (42203, 12)]) {
      server.routes['GET /v2/anime/$id'] = (_) => malOnline
          ? (200, {'id': id, 'title': 'Re:Zero $id', 'num_episodes': episodes, 'my_list_status': malList[id]})
          : unreachable;
      server.routes['PATCH /v2/anime/$id/my_list_status'] = (RequestOptions o) {
        if (!malOnline) return unreachable;
        final form = (o.data as Map).cast<String, String>();
        malList[id] = {
          'status': form['status'],
          'num_episodes_watched': int.parse(form['num_watched_episodes']!),
          'start_date': form['start_date'] ?? malList[id]?['start_date'],
        };
        return (200, {});
      };
    }
  });

  Future<ProviderContainer> start({bool linked = true, DateTime? expiresAt, Map<String, Object> prefs = const {}}) async {
    FlutterSecureStorage.setMockInitialValues({
      ...signedInStorage(),
      if (linked) 'mal.account': _account(expiresAt: expiresAt),
    });
    SharedPreferences.setMockInitialValues(prefs);
    final c = ProviderContainer(overrides: fakeServerOverrides(server, animeIds: _mapping));
    addTearDown(c.dispose);
    return c;
  }

  List<RequestOptions> patches() => server.requests.where((r) => r.method == 'PATCH').toList();

  test('watching an episode updates MAL (watching, start date) and logs it', () async {
    final c = await start();
    await c.read(malSyncServiceProvider).markedWatched(_episode('s1', 1, 5));

    expect(malList[31240], containsPair('num_episodes_watched', 5));
    expect(malList[31240], containsPair('status', 'watching'));
    expect(malList[31240]!['start_date'], isNotNull);
    expect(patches().single.headers['Authorization'], 'Bearer tok');
    final log = c.read(malSyncLogProvider).value!;
    expect(log.single.message, contains('5 watched'));
    expect(await c.read(malSyncServiceProvider).queue(), isEmpty);
  });

  test('rewatching an earlier episode never lowers MAL', () async {
    final c = await start();
    malList[31240] = {'status': 'watching', 'num_episodes_watched': 10, 'start_date': '2026-01-01'};
    await c.read(malSyncServiceProvider).markedWatched(_episode('s1', 1, 3));
    expect(patches(), isEmpty);
    expect(c.read(malSyncLogProvider).value!.single.message, contains('Already up to date'));
  });

  test('marking an episode unwatched takes MAL back one', () async {
    final c = await start();
    malList[31240] = {'status': 'completed', 'num_episodes_watched': 25, 'start_date': '2026-01-01'};
    await c.read(malSyncServiceProvider).markedWatched(_episode('s1', 1, 25, played: false), watched: false);
    expect(malList[31240], containsPair('num_episodes_watched', 24));
    expect(malList[31240], containsPair('status', 'watching'));
    expect(c.read(malSyncLogProvider).value!.single.message, contains('24 watched'));

    // An episode MAL never counted changes nothing.
    await c.read(malSyncServiceProvider).markedWatched(_episode('s1', 1, 25, played: false), watched: false);
    expect(patches(), hasLength(1));
  });

  test('a split-cour season updates the right MAL entry', () async {
    final c = await start();
    await c.read(malSyncServiceProvider).markedWatched(_episode('s2', 2, 15));
    expect(malList.keys, [42203]);
    expect(malList[42203], containsPair('num_episodes_watched', 2));
  });

  test('marking a season watched completes each of its MAL entries', () async {
    final c = await start();
    final season = BaseItem.fromJson({
      'Id': 's2', 'Name': 'Season 2', 'Type': 'Season', 'SeriesId': 'rz', 'SeriesName': 'Re:Zero',
      'IndexNumber': 2, 'ProviderIds': {'AniDB': '11370', 'Tvdb': '305089'},
    });
    await c.read(malSyncServiceProvider).markedWatched(season);
    expect(malList[39587], containsPair('status', 'completed'));
    expect(malList[42203], containsPair('num_episodes_watched', 12));
  });

  test('offline updates wait in the queue and are sent later', () async {
    final c = await start();
    malOnline = false;
    await c.read(malSyncServiceProvider).markedWatched(_episode('s1', 1, 7));
    expect(malList, isEmpty);
    final queued = await c.read(malSyncServiceProvider).queue();
    expect([for (final j in queued) (j.malId, j.episode)], [(31240, 7)]);
    expect(c.read(malSyncLogProvider).value!.first.ok, isFalse);

    malOnline = true;
    await c.read(malSyncServiceProvider).processQueue();
    expect(malList[31240], containsPair('num_episodes_watched', 7));
    expect(await c.read(malSyncServiceProvider).queue(), isEmpty);
  });

  test('nothing is sent when not linked, sync is off, or the show opted out', () async {
    var c = await start(linked: false);
    await c.read(malSyncServiceProvider).markedWatched(_episode('s1', 1, 2));
    c.dispose();

    c = await start(prefs: {'anime.syncEnabled': false});
    await c.read(malSyncServiceProvider).markedWatched(_episode('s1', 1, 2));
    c.dispose();

    c = await start(prefs: {'anime.syncOptOut': ['rz']});
    await c.read(malSyncServiceProvider).markedWatched(_episode('s1', 1, 2));

    expect(patches(), isEmpty);
    expect(server.requests.where((r) => r.uri.host == 'api.myanimelist.net'), isEmpty);
  });

  test('an expired token is refreshed and saved', () async {
    final c = await start(expiresAt: DateTime.now().subtract(const Duration(hours: 1)));
    await c.read(malSyncServiceProvider).markedWatched(_episode('s1', 1, 1));
    expect(server.requestsTo('/v1/oauth2/token'), hasLength(1));
    expect(patches().single.headers['Authorization'], 'Bearer tok2');
    expect(c.read(malAccountProvider).value!.tokens.accessToken, 'tok2');
  });

  test('after playback, syncs only if the server counts it watched', () async {
    final c = await start();
    server.routes['/Items/ep1-4'] = (200, {
      ...itemJson('ep1-4', 'Episode 4', type: 'Episode'),
      'SeriesId': 'rz', 'SeasonId': 's1', 'ParentIndexNumber': 1, 'IndexNumber': 4,
      'UserData': {'Played': true},
    });
    server.routes['/Items/ep1-5'] = (200, {
      ...itemJson('ep1-5', 'Episode 5', type: 'Episode'),
      'SeriesId': 'rz', 'SeasonId': 's1', 'ParentIndexNumber': 1, 'IndexNumber': 5,
      'UserData': {'Played': false, 'PlaybackPositionTicks': 100},
    });
    await c.read(malSyncServiceProvider).playbackEnded('ep1-5');
    expect(patches(), isEmpty, reason: 'stopped halfway');
    await c.read(malSyncServiceProvider).playbackEnded('ep1-4');
    expect(malList[31240], containsPair('num_episodes_watched', 4));
  });
}
