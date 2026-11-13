import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/core/jellyfin/jellyfin_api.dart';
import 'package:jellyfin_client/core/jellyfin/library_api.dart';

import '../../support/fake_server.dart';

void main() {
  late FakeServer server;
  late LibraryApi library;

  setUp(() {
    server = FakeServer({
      '/Items': (200, pageJson([itemJson('m1', 'Your Name')], total: 1)),
      '/Items/Latest': (200, [itemJson('m1', 'Your Name')]),
      '/UserPlayedItems/m1': (200, {'Played': true}),
      '/UserFavoriteItems/m1': (200, {'IsFavorite': true}),
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

  test('getItems sends filters, sorting and paging', () async {
    final page = await library.getItems(
      const ItemQuery(
        parentId: 'lib1',
        includeItemTypes: [ItemType.series],
        sortBy: SortField.dateAdded,
        descending: true,
        unplayedOnly: true,
        favoritesOnly: true,
        genres: ['Fantasy', 'Adventure'],
      ),
      startIndex: 100,
      limit: 50,
    );

    expect(page.items.single.name, 'Your Name');
    final q = server.requests.single.queryParameters;
    expect(q['userId'], 'u1');
    expect(q['parentId'], 'lib1');
    expect(q['includeItemTypes'], 'Series');
    expect(q['sortBy'], 'DateCreated,SortName');
    expect(q['sortOrder'], 'Descending');
    expect(q['filters'], 'IsUnplayed,IsFavorite');
    expect(q['genres'], 'Fantasy|Adventure');
    expect(q['startIndex'], 100);
    expect(q['limit'], 50);
    expect(q.containsKey('searchTerm'), isFalse, reason: 'nulls are dropped');
  });

  test('latest returns a bare list', () async {
    final items = await library.getLatest('lib1');
    expect(items.single.id, 'm1');
    expect(server.requests.single.queryParameters['groupItems'], true);
  });

  test('played and favorite use POST to set and DELETE to clear', () async {
    await library.setPlayed('m1', true);
    await library.setPlayed('m1', false);
    await library.setFavorite('m1', true);
    await library.setFavorite('m1', false);

    expect(
      server.requests.map((r) => '${r.method} ${r.uri.path}'),
      [
        'POST /UserPlayedItems/m1',
        'DELETE /UserPlayedItems/m1',
        'POST /UserFavoriteItems/m1',
        'DELETE /UserFavoriteItems/m1',
      ],
    );
  });

  test('collection types map to item types', () {
    expect(itemTypesForCollection('movies'), [ItemType.movie]);
    expect(itemTypesForCollection('tvshows'), [ItemType.series]);
    expect(itemTypesForCollection(null), isEmpty);
  });

  test('playlists: an entry moves, a playlist is deleted, a new one can start empty', () async {
    server = FakeServer({
      'POST /Playlists/pl1/Items/e7/Move/2': (204, null),
      'DELETE /Items/pl1': (204, null),
      'POST /Playlists': (200, {'Id': 'pl2'}),
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
    await library.movePlaylistEntry('pl1', 'e7', 2);
    await library.deletePlaylist('pl1');
    await library.createPlaylist('Road trip', const []);
    expect(server.requestsTo('/Playlists/pl1/Items/e7/Move/2').single.method, 'POST');
    expect(server.requestsTo('/Items/pl1').single.method, 'DELETE');
    final body = server.requestsTo('/Playlists').single.data as Map;
    expect(body['Ids'], isEmpty);
    expect(body['MediaType'], 'Video');
  });
}