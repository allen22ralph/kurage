import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/core/jellyfin/jellyfin_api.dart';
import 'package:jellyfin_client/core/jellyfin/library_api.dart';
import 'package:jellyfin_client/features/watchlist/watchlist_providers.dart';
import 'package:jellyfin_client/features/watchlist/watchlist_screen.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

BaseItem _item(String id, String name, String type, {Map<String, dynamic> extra = const {}}) =>
    BaseItem.fromJson(itemJson(id, name, type: type, extra: extra));

void main() {
  late FakeServer server;
  late LibraryApi library;

  setUp(() {
    server = FakeServer({
      '/Items': (
        200,
        pageJson([
          itemJson('s1', 'Delicious in Dungeon', type: 'Series', extra: {
            'UserData': {'Likes': true, 'UnplayedItemCount': 24},
          }),
        ]),
      ),
      'POST /UserItems/s1/Rating': (200, {'Likes': true}),
    });
    library = LibraryApi(
      JellyfinApi(
        baseUrl: Uri.parse('https://jellyfin.home.arpa'),
        clientInfo: testClientInfo,
        accessToken: 'tok',
        dio: Dio()..httpClientAdapter = server,
      ),
      userId: 'u1',
    );
  });

  test('reads the liked items, as the web watchlist keeps them', () async {
    final items = await library.getWatchlist();
    final q = server.requestsTo('/Items').single.queryParameters;
    expect(q['filters'], 'Likes');
    expect(q['includeItemTypes'], 'Movie,Series,Season,Episode');
    expect(q['recursive'], true);
    expect(items.single.userData.likes, isTrue);
    expect(items.single.userData.unplayedItemCount, 24);
  });

  test('adds and removes by the liked flag', () async {
    await library.setWatchlisted('s1', true);
    await library.setWatchlisted('s1', false);
    final calls = server.requestsTo('/UserItems/s1/Rating');
    expect([for (final c in calls) c.queryParameters['likes']], [true, false]);
    expect(calls.first.method, 'POST');
  });

  test('shows, episodes and movies stay apart', () {
    final series = _item('s', 'Show', 'Series');
    final season = _item('se', 'Season 2', 'Season');
    final episode = _item('e', 'Ep', 'Episode', extra: {'SeriesName': 'Show'});
    final movie = _item('m', 'Film', 'Movie');
    expect([for (final i in [series, season, episode, movie]) WatchlistFilter.shows.keeps(i)], [true, true, false, false]);
    expect([for (final i in [series, season, episode, movie]) WatchlistFilter.episodes.keeps(i)], [false, false, true, false]);
    expect([for (final i in [series, season, episode, movie]) WatchlistFilter.movies.keeps(i)], [false, false, false, true]);
    expect(canWatchlist(_item('c', 'Box', 'BoxSet')), isFalse);
    expect(canWatchlist(episode), isTrue);
  });

  test('the line under each title says where it is at', () {
    expect(
      watchlistSubline(_item('s', 'Show', 'Series', extra: {
        'ProductionYear': 2024,
        'UserData': {'UnplayedItemCount': 24},
      })),
      '2024 · 24 unwatched',
    );
    expect(
      watchlistSubline(_item('m', 'Film', 'Movie', extra: {
        'ProductionYear': 2019,
        'RunTimeTicks': 166 * 60 * 10000000,
      })),
      '2019 · 2h 46m',
    );
    expect(
      watchlistSubline(_item('e', 'Ep', 'Episode', extra: {
        'ParentIndexNumber': 1,
        'IndexNumber': 5,
        'RunTimeTicks': 24 * 60 * 10000000,
        'UserData': {'PlaybackPositionTicks': 10 * 60 * 10000000},
      })),
      startsWith('S1'),
    );
  });

  test('sorting: newest release first, undated last', () {
    final old = _item('a', 'A', 'Movie', extra: {'PremiereDate': '2001-01-01T00:00:00Z'});
    final recent = _item('b', 'B', 'Movie', extra: {'PremiereDate': '2024-01-01T00:00:00Z'});
    final undated = _item('c', 'C', 'Movie');
    final list = [old, undated, recent]..sort(WatchlistSort.released.compare);
    expect([for (final i in list) i.id], ['b', 'a', 'c']);
  });

  test('your order: placed ones in order, new ones on top', () {
    final a = _item('a', 'A', 'Movie', extra: {'PremiereDate': '2001-01-01T00:00:00Z'});
    final b = _item('b', 'B', 'Movie');
    final c = _item('c', 'C', 'Movie');
    final fresh = _item('n', 'New', 'Movie', extra: {'PremiereDate': '2025-01-01T00:00:00Z'});
    expect([for (final i in arrange([a, b, c, fresh], ['c', 'a', 'b', 'gone'])) i.id], ['n', 'c', 'a', 'b']);
  });

  test('moving one saves the whole order on the account', () async {
    final prefs = FakeServer({
      '/DisplayPreferences/jellyfin-client-watchlist': (200, {
        'CustomPrefs': {'order': '["a","b","c"]'},
      }),
      'POST /DisplayPreferences/jellyfin-client-watchlist': (204, null),
    });
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final c = ProviderContainer(overrides: fakeServerOverrides(prefs));
    addTearDown(c.dispose);
    await c.read(sessionControllerProvider.future);
    expect(await c.read(watchlistOrderProvider.future), ['a', 'b', 'c']);

    final items = [for (final id in ['a', 'b', 'c']) _item(id, id, 'Movie')];
    await c.read(watchlistOrderProvider.notifier).move(items, 'c', before: 'a');
    expect(c.read(watchlistOrderProvider).value, ['c', 'a', 'b']);
    final body = prefs.requestsTo('/DisplayPreferences/jellyfin-client-watchlist').last.data as Map;
    expect(body['CustomPrefs'], {'order': '["c","a","b"]'});

    await c.read(watchlistOrderProvider.notifier).move(items, 'c', after: 'b');
    expect(c.read(watchlistOrderProvider).value, ['a', 'b', 'c']);
  });
}