import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/core/anime/anime_ids.dart';
import 'package:jellyfin_client/features/library/widgets/media_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    SharedPreferences.setMockInitialValues({'anime.showScores': false}); // keep card text simple
  });

  // Four shows; three on MAL with scores 7.0, 9.1, 8.2; one unmatched.
  final shows = [
    ('a', 'Alpha', 1, 7.0),
    ('b', 'Bravo', 2, 9.1),
    ('c', 'Charlie', 3, 8.2),
    ('d', 'Delta', null, null),
  ];
  final mapping = AnimeIdMapping.fromFribb([
    for (final (_, _, anidb, _) in shows)
      if (anidb != null) {'type': 'TV', 'anidb_id': anidb, 'mal_id': 100 + anidb},
  ]);

  FakeServer server() => FakeServer({
        '/UserViews': (200, pageJson([itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {'CollectionType': 'tvshows'})])),
        '/UserItems/Resume': (200, pageJson([])),
        '/Shows/NextUp': (200, pageJson([])),
        '/Items/Latest': (200, <Object>[]),
        '/Items/lib1': (200, itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {'CollectionType': 'tvshows'})),
        '/Genres': (200, pageJson([])),
        // Two pages, so MAL mode must load past the first.
        '/Items': (options) {
          final start = options.queryParameters['startIndex'] as int;
          final page = start == 0 ? shows.sublist(0, 2) : shows.sublist(2);
          return (
            200,
            pageJson(
              [
                for (final (id, name, anidb, _) in page)
                  itemJson(id, name, type: 'Series', extra: {
                    if (anidb != null) 'ProviderIds': {'AniDB': '$anidb'},
                  }),
              ],
              total: 4,
              start: start,
            ),
          );
        },
        for (final (_, name, anidb, score) in shows)
          if (anidb != null)
            '/v4/anime/${100 + anidb}': (200, {'data': {'mal_id': 100 + anidb, 'title': name, 'score': score}}),
      });

  List<String> order(WidgetTester tester) => [
        for (final card in tester.widgetList<MediaCard>(find.byType(MediaCard))) card.item.name,
      ];

  testWidgets('sort by MAL score loads everything; filter by minimum', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: fakeServerOverrides(server(), animeIds: mapping));
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anime').first);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ActionChip, 'Name'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'MAL score'));
    await tester.pumpAndSettle();
    expect(order(tester), ['Bravo', 'Charlie', 'Alpha', 'Delta'], reason: 'unscored last');

    await tester.tap(find.widgetWithText(ActionChip, 'Descending'));
    await tester.pumpAndSettle();
    expect(order(tester), ['Alpha', 'Charlie', 'Bravo', 'Delta']);

    await tester.tap(find.widgetWithText(FilterChip, 'MAL score'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('8 and up'));
    await tester.pumpAndSettle();
    expect(order(tester), ['Charlie', 'Bravo']);
    expect(find.widgetWithText(FilterChip, 'MAL ≥ 8'), findsOneWidget);
  });
}
