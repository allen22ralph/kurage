import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/features/library/widgets/add_to_playlist.dart';
import 'package:jellyfin_client/features/library/widgets/card_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  late FakeServer server;
  final episode = BaseItem.fromJson(itemJson('ep1', 'First', type: 'Episode'));

  Future<void> open(WidgetTester tester, List<BaseItem> items) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.runAsync(() => c.read(sessionControllerProvider.future));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showAddToPlaylist(context, items), child: const Text('Open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  setUp(() {
    server = FakeServer({
      '/Items': (200, pageJson([itemJson('pl1', 'Road trip', type: 'Playlist')])),
      'POST /Playlists/pl1/Items': (204, null),
      'POST /Playlists': (200, {'Id': 'pl2'}),
    });
  });

  testWidgets('adds to a playlist that exists', (tester) async {
    await open(tester, [episode, BaseItem.fromJson(itemJson('ep2', 'Second', type: 'Episode'))]);
    await tester.tap(find.text('Road trip'));
    await settle(tester);
    final request = server.requestsTo('/Playlists/pl1/Items').single;
    expect(request.queryParameters['ids'], 'ep1,ep2');
    expect(find.text('Add to playlist'), findsNothing, reason: 'closed');
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('makes a new one with it in', (tester) async {
    final before = playlistsChanged.value;
    await open(tester, [episode]);
    await tester.tap(find.text('New playlist'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '  Favourites  ');
    await tester.tap(find.text('Create'));
    await settle(tester);
    final body = server.requestsTo('/Playlists').single.data as Map;
    expect(body['Name'], 'Favourites');
    expect(body['Ids'], ['ep1']);
    expect(playlistsChanged.value, greaterThan(before), reason: 'lists of playlists load again');
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a refusal is shown and the window stays', (tester) async {
    server = FakeServer({
      '/Items': (200, pageJson([itemJson('pl1', 'Road trip', type: 'Playlist')])),
      'POST /Playlists/pl1/Items': (403, null),
    });
    await open(tester, [episode]);
    await tester.tap(find.text('Road trip'));
    await settle(tester);
    expect(find.text('Add to playlist'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an entry comes out of the playlist it was listed from', (tester) async {
    server = FakeServer({'DELETE /Playlists/pl1/Items': (204, null)});
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.runAsync(() => c.read(sessionControllerProvider.future));
    final playlist = BaseItem.fromJson(itemJson('pl1', 'Road trip', type: 'Playlist'));
    final entry = BaseItem.fromJson(itemJson('ep1', 'First', type: 'Episode', extra: {'PlaylistItemId': 'entry7'}));
    var reloaded = 0;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: PlaylistScope(
            playlist: playlist,
            onRemoved: () => reloaded++,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => CardActions(context).removeFromPlaylist(PlaylistScope.maybeOf(context)!, entry),
                child: const Text('Remove'),
              ),
            ),
          ),
        ),
      ),
    ));
    expect(playlistEntryId(episode), isNull, reason: 'not listed from a playlist');
    await tester.tap(find.text('Remove'));
    await settle(tester);
    expect(server.requestsTo('/Playlists/pl1/Items').single.queryParameters['entryIds'], 'entry7');
    expect(reloaded, 1);
    await tester.pump(const Duration(seconds: 6));
  });

  test('what can go in one', () {
    expect(canAddToPlaylist(episode), isTrue);
    expect(canAddToPlaylist(BaseItem.fromJson(itemJson('s', 'S', type: 'Series'))), isTrue);
    expect(canAddToPlaylist(BaseItem.fromJson(itemJson('l', 'L', type: 'CollectionFolder'))), isFalse);
  });
}
