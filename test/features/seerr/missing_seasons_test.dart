import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/core/seerr/seerr_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  Map<String, Object?> season(String id, int n) =>
      itemJson(id, 'Season $n', type: 'Season', extra: {'IndexNumber': n, 'SeriesId': 'ch'});
  Map<String, Object?> episode(String id, int n, {bool virtual = false}) => itemJson(id, 'Episode $n',
      type: 'Episode',
      extra: {'IndexNumber': n, 'ParentIndexNumber': 1, 'SeriesId': 'ch', 'LocationType': virtual ? 'Virtual' : 'FileSystem'});

  late FakeServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final show = itemJson('ch', 'Chitose', type: 'Series', extra: {
      'ProviderIds': {'Tmdb': '7'},
    });
    server = FakeServer({
      '/UserViews': (200, pageJson([itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {'CollectionType': 'tvshows'})])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, [show]),
      '/Items/ch': (200, show),
      '/Items/ch/Similar': (200, pageJson([])),
      '/Shows/ch/Seasons': (200, pageJson([season('s1', 1)])),
      // Three on the server; a fourth only as Jellyfin's placeholder.
      '/Shows/ch/Episodes': (200, pageJson([episode('e14', 14), episode('e15', 15), episode('e16', 16), episode('e1', 1, virtual: true)])),
      '/api/v1/tv/7': (200, {
        'id': 7,
        'name': 'Chitose',
        'seasons': [
          {'seasonNumber': 1, 'name': 'Season 1', 'episodeCount': 16},
          {'seasonNumber': 2, 'name': 'Season 2', 'episodeCount': 12},
        ],
        'mediaInfo': {
          'status': 4,
          'seasons': [
            {'seasonNumber': 1, 'status': 4},
          ],
        },
      }),
      '/api/v1/request': (200, {'results': <Object>[]}),
    });
  });

  testWidgets("a show's page offers what's missing: seasons not on the server, and the rest of a partial one",
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      ...signedInStorage(),
      'seerr.account': jsonEncode({
        'baseUrl': 'https://seerr.home.arpa',
        'userId': 3,
        'displayName': 'sam',
        'permissions': SeerrPermission.request,
        'cookie': 'connect.sid=s%3Aabc',
      }),
    });
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chitose').last);
    await tester.pumpAndSettle();

    expect(find.text('Request missing seasons (2)'), findsOneWidget);
    expect(find.text('Season 2 · Not on server'), findsOneWidget);
    expect(find.text('3 of 16 episodes are on the server.'), findsOneWidget, reason: "the placeholder doesn't count");
    expect(find.text('Request the rest of Season 1'), findsOneWidget);

    await tester.tap(find.text('Request missing seasons (2)'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(CheckboxListTile, 'Season 2'), findsOneWidget, reason: 'the request window opens');
  });

  testWidgets('without Seerr, the page offers nothing extra', (tester) async {
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chitose').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Request'), findsNothing);
    expect(find.textContaining('Not on server'), findsNothing);
  });
}
