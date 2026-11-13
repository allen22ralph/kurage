import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/features/library/depth/playlist_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  late FakeServer server;

  Map<String, dynamic> entry(String id, String name, String entryId) =>
      itemJson(id, name, type: 'Episode', extra: {'PlaylistItemId': entryId, 'SeriesName': 'Show $name'});

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.runAsync(() => c.read(sessionControllerProvider.future));
    final playlist = BaseItem.fromJson(itemJson('pl1', 'Road trip', type: 'Playlist'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: Scaffold(body: DepthPlaylistPage(playlist: playlist))),
    ));
    await settle(tester);
  }

  setUp(() {
    server = FakeServer({
      '/Playlists/pl1/Items': (
        200,
        pageJson([entry('a', 'Alpha', 'e1'), entry('b', 'Bravo', 'e2'), entry('c', 'Charlie', 'e3')]),
      ),
      'DELETE /Playlists/pl1/Items': (204, null),
      'POST /Playlists/pl1/Items/e3/Move/0': (204, null),
    });
  });

  testWidgets('pick several, then take them out together', (tester) async {
    await open(tester);
    expect(find.text('Show Alpha'), findsOneWidget);

    await tester.longPress(find.text('Show Alpha'));
    await tester.pump();
    await tester.tap(find.text('Show Charlie'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove from the playlist').last);
    await settle(tester);
    final removed = server.requestsTo('/Playlists/pl1/Items').where((r) => r.method == 'DELETE').single;
    expect(removed.queryParameters['entryIds'], 'e1,e3');
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('move to top keeps the picked one first', (tester) async {
    await open(tester);
    await tester.longPress(find.text('Show Charlie'));
    await tester.pump();
    await tester.tap(find.byTooltip('Move to top'));
    await settle(tester);
    expect(server.requestsTo('/Playlists/pl1/Items/e3/Move/0'), hasLength(1));
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('right-click while picking: the menu is for all of them, the clicked one joining', (tester) async {
    server = FakeServer({
      '/Playlists/pl1/Items': (
        200,
        pageJson([
          entry('a', 'Alpha', 'e1'),
          itemJson('b', 'Bravo', type: 'Episode', extra: {
            'PlaylistItemId': 'e2',
            'SeriesName': 'Show Bravo',
            'UserData': {'Played': true},
          }),
          entry('c', 'Charlie', 'e3'),
        ]),
      ),
      'DELETE /Playlists/pl1/Items': (204, null),
    });
    await open(tester);
    await tester.longPress(find.text('Show Alpha'));
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.text('Show Bravo')), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Mark watched'), findsOneWidget, reason: 'Alpha is not watched');
    expect(find.text('Mark unwatched'), findsOneWidget, reason: 'Bravo is');

    await tester.tap(find.text('Remove from the playlist'));
    await settle(tester);
    final removed = server.requestsTo('/Playlists/pl1/Items').where((r) => r.method == 'DELETE').single;
    expect(removed.queryParameters['entryIds'], 'e1,e2');
    await tester.pump(const Duration(seconds: 6));
  });
}