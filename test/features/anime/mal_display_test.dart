import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/core/anime/anime_ids.dart';
import 'package:jellyfin_client/features/anime/anime_providers.dart';
import 'package:jellyfin_client/features/anime/anime_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    SharedPreferences.setMockInitialValues({});
  });

  // Frieren: AniDB 17617 -> MAL 52991; a second entry to "fix" the match to.
  final mapping = AnimeIdMapping.fromFribb([
    {'type': 'TV', 'anidb_id': 17617, 'mal_id': 52991, 'tvdb_id': 424536, 'season': {'tvdb': 1}},
  ]);

  Map<String, Object?> jikan(int id, String title, double score) => {
        'data': {
          'mal_id': id,
          'title': title,
          'title_english': id == 52991 ? "Frieren: Beyond Journey's End" : null,
          'score': score,
          'rank': 1,
          'popularity': 150,
          'members': 1234000,
          'episodes': 28,
          'type': 'TV',
        },
      };

  final series = itemJson('ser1', 'Frieren', type: 'Series', extra: {
    'ProviderIds': {'AniDB': '17617', 'Tvdb': '424536'},
    'UserData': {'Played': false},
  });

  FakeServer server() => FakeServer({
        '/UserViews': (
          200,
          pageJson([
            itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {'CollectionType': 'tvshows'}),
          ]),
        ),
        '/UserItems/Resume': (200, pageJson([])),
        '/Shows/NextUp': (200, pageJson([])),
        '/Items/Latest': (200, [series]),
        '/Items/ser1': (200, series),
        '/Shows/ser1/Seasons': (200, pageJson([])),
        '/Items/ser1/Similar': (200, pageJson([])),
        '/v4/anime/52991': (200, jikan(52991, 'Sousou no Frieren', 9.3)),
        '/v4/anime/99': (200, jikan(99, 'Some Other Show', 6.1)),
        '/v4/anime': (200, {
          'data': [
            jikan(99, 'Some Other Show', 6.1)['data'],
            jikan(52991, 'Sousou no Frieren', 9.3)['data'],
          ],
        }),
      });

  Future<ProviderContainer> pumpApp(WidgetTester tester, FakeServer s) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: fakeServerOverrides(s, animeIds: mapping));
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const JellyfinClientApp(),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('posters show the MAL score', (tester) async {
    await pumpApp(tester, server());
    expect(find.text('9.30'), findsOneWidget);
  });

  testWidgets('episode cards show the episode rating, not the show score', (tester) async {
    final s = server();
    s.routes['/Shows/NextUp'] = (200, pageJson([
      itemJson('ep19', 'Episode 19', type: 'Episode', extra: {
        'IndexNumber': 19,
        'ParentIndexNumber': 1,
        'SeriesId': 'ser1',
        'SeriesName': 'Frieren',
        'SeasonId': 'sea1',
        'ProviderIds': {'AniDB': '17617', 'Tvdb': '424536'},
      }),
    ]));
    s.routes['/Items/sea1'] = (200, itemJson('sea1', 'Season 1', type: 'Season', extra: {
      'IndexNumber': 1,
      'ProviderIds': {'AniDB': '17617', 'Tvdb': '424536'},
    }));
    // Episode 19 is rated 4.76 in the saved page.
    s.routes['/anime/52991/_/episode'] = (200, File('test/fixtures/mal_episodes.html').readAsStringSync());
    await pumpApp(tester, s);
    expect(find.text('9.52'), findsOneWidget, reason: 'Next up: the episode (4.76/5, shown out of 10)');
    expect(find.text('9.30'), findsOneWidget, reason: 'Recently added: the series');
  });

  testWidgets("an episode without a rating shows the show's score, marked 'show'", (tester) async {
    final s = server();
    s.routes['/Shows/NextUp'] = (200, pageJson([
      itemJson('ep99', 'Episode 99', type: 'Episode', extra: {
        'IndexNumber': 99, // not in the saved episodes page: no rating
        'ParentIndexNumber': 1,
        'SeriesId': 'ser1',
        'SeriesName': 'Frieren',
        'SeasonId': 'sea1',
        'ProviderIds': {'AniDB': '17617', 'Tvdb': '424536'},
      }),
    ]));
    s.routes['/Items/sea1'] = (200, itemJson('sea1', 'Season 1', type: 'Season', extra: {
      'IndexNumber': 1,
      'ProviderIds': {'AniDB': '17617', 'Tvdb': '424536'},
    }));
    s.routes['/Items/ser1'] = (200, itemJson('ser1', 'Frieren', type: 'Series', extra: {
      'ProviderIds': {'AniDB': '17617', 'Tvdb': '424536'},
    }));
    s.routes['/anime/52991/_/episode'] = (200, File('test/fixtures/mal_episodes.html').readAsStringSync());
    await pumpApp(tester, s);
    expect(find.text('show'), findsOneWidget, reason: "the Next up card: the show's score, marked");
    expect(find.text('9.30'), findsNWidgets(2), reason: 'Recently added (the series) and the marked Next up card');
  });

  testWidgets('detail page shows MAL facts; fix match picks another entry', (tester) async {
    final s = server();
    final container = await pumpApp(tester, s);
    await tester.tap(find.text('Frieren').last);
    await tester.pumpAndSettle();

    expect(find.text('Ranked #1'), findsOneWidget);
    expect(find.text('Popularity #150'), findsOneWidget);
    expect(find.text('1.2M members'), findsOneWidget);

    await tester.tap(find.text('Fix match'));
    await tester.pumpAndSettle();
    expect(find.text('Now: MAL #52991 (AniDB ID)'), findsOneWidget);
    expect(s.requestsTo('/v4/anime').single.queryParameters['q'], 'Frieren');

    await tester.tap(find.text('Some Other Show'));
    await tester.pumpAndSettle();
    expect(container.read(malOverridesProvider).value, {'ser1': 99});
    expect(find.text('6.10'), findsOneWidget, reason: 'detail page follows the fix');

    // And back to automatic.
    await tester.tap(find.text('Fix match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use automatic match'));
    await tester.pumpAndSettle();
    expect(container.read(malOverridesProvider).value, isEmpty);
  });

  testWidgets('unmatched series offer "Find match"; scores can be hidden', (tester) async {
    final s = server()..routes['/Items/Latest'] = (200, [itemJson('ser2', 'Unknown Show', type: 'Series')]);
    s.routes['/Items/ser2'] = (200, itemJson('ser2', 'Unknown Show', type: 'Series'));
    s.routes['/Shows/ser2/Seasons'] = (200, pageJson([]));
    s.routes['/Items/ser2/Similar'] = (200, pageJson([]));
    await pumpApp(tester, s);
    await tester.tap(find.text('Unknown Show').last);
    await tester.pumpAndSettle();
    expect(find.text('Not matched on MyAnimeList'), findsOneWidget);
    expect(find.text('Find match'), findsOneWidget);
  });

  testWidgets('a later season shows its own MAL entry; season 1 does not repeat', (tester) async {
    final reZero = AnimeIdMapping.fromFribb([
      {'type': 'TV', 'anidb_id': 11370, 'mal_id': 31240, 'tvdb_id': 305089, 'season': {'tvdb': 1}},
      {'type': 'TV', 'anidb_id': 19242, 'mal_id': 61316, 'tvdb_id': 305089, 'season': {'tvdb': 4}},
    ]);
    final show = itemJson('rz', 'Re:Zero', type: 'Series', extra: {
      'ProviderIds': {'AniDB': '11370', 'Tvdb': '305089'},
    });
    Map<String, Object?> season(String id, int n) => itemJson(id, 'Season $n', type: 'Season', extra: {
          'IndexNumber': n,
          'SeriesId': 'rz',
          'ProviderIds': {'AniDB': '11370', 'Tvdb': '305089'}, // copied down from the series
          'UserData': {'Played': false},
        });
    final s = FakeServer({
      '/UserViews': (200, pageJson([itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {'CollectionType': 'tvshows'})])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, [show]),
      '/Items/rz': (200, show),
      '/Items/rz/Similar': (200, pageJson([])),
      '/Shows/rz/Seasons': (200, pageJson([season('s1', 1), season('s4', 4)])),
      '/Shows/rz/Episodes': (200, pageJson([])),
      '/v4/anime/31240': (200, jikan(31240, 'Re:Zero', 8.2)),
      '/v4/anime/61316': (200, jikan(61316, 'Re:Zero 4th Season', 8.9)),
    });
    final container = ProviderContainer(overrides: fakeServerOverrides(s, animeIds: reZero));
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Re:Zero').last);
    await tester.pumpAndSettle();

    // Season 1 is selected first: only the series row (8.20).
    expect(find.text('8.20'), findsWidgets);
    expect(find.text('8.90'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Season 4'));
    await tester.pumpAndSettle();
    expect(find.text('8.90'), findsOneWidget);
  });

  testWidgets('episode rows show the MAL community rating', (tester) async {
    final reZero = AnimeIdMapping.fromFribb([
      {'type': 'TV', 'anidb_id': 11370, 'mal_id': 31240, 'tvdb_id': 305089, 'season': {'tvdb': 1}},
    ]);
    const ids = {'AniDB': '11370', 'Tvdb': '305089'};
    final show = itemJson('rz', 'Re:Zero', type: 'Series', extra: {'ProviderIds': ids});
    Map<String, Object?> episode(int n) => itemJson('e$n', 'Episode $n', type: 'Episode', extra: {
          'IndexNumber': n,
          'ParentIndexNumber': 1,
          'SeriesId': 'rz',
          'SeasonId': 's1',
          'ProviderIds': ids,
        });
    final s = FakeServer({
      '/UserViews': (200, pageJson([itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {'CollectionType': 'tvshows'})])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, [show]),
      '/Items/rz': (200, show),
      '/Items/rz/Similar': (200, pageJson([])),
      '/Shows/rz/Seasons': (200, pageJson([
        itemJson('s1', 'Season 1', type: 'Season', extra: {'IndexNumber': 1, 'SeriesId': 'rz', 'ProviderIds': ids}),
      ])),
      '/Shows/rz/Episodes': (200, pageJson([episode(1), episode(2)])),
      '/v4/anime/31240': (200, jikan(31240, 'Re:Zero', 8.2)),
      // Episode 1 is rated 4.30 on the real page; episode 2 isn't in it.
      '/anime/31240/_/episode': (200, File('test/fixtures/mal_episodes.html').readAsStringSync()),
    });
    final container = ProviderContainer(overrides: fakeServerOverrides(s, animeIds: reZero));
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Re:Zero').last);
    await tester.pumpAndSettle();

    expect(find.text('8.60'), findsOneWidget, reason: '4.30/5 shown out of 10');
    expect(find.bySemanticsLabel(RegExp('episode rating')), findsOneWidget, reason: 'unrated episode 2 shows none');
    expect(s.requestsTo('/anime/31240/_/episode'), hasLength(1), reason: 'one page for both episodes');

    // The original 1–5 scale, as on MAL.
    final settings = container.read(animeSettingsProvider).value!;
    await container.read(animeSettingsProvider.notifier).save(settings.copyWith(episodeScoresOutOf10: false));
    await tester.pumpAndSettle();
    expect(find.text('4.30'), findsOneWidget);
  });

  testWidgets("an episode card names its show, not its season's MAL entry", (tester) async {
    SharedPreferences.setMockInitialValues({'anime.titleLanguage': 'romaji'});
    final reZero = AnimeIdMapping.fromFribb([
      {'type': 'TV', 'anidb_id': 11370, 'mal_id': 31240, 'tvdb_id': 305089, 'season': {'tvdb': 1}},
      {'type': 'TV', 'anidb_id': 19242, 'mal_id': 61316, 'tvdb_id': 305089, 'season': {'tvdb': 4}},
    ]);
    const ids = {'AniDB': '11370', 'Tvdb': '305089'};
    final s = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([
        itemJson('e41', 'Episode 1', type: 'Episode', extra: {
          'IndexNumber': 1,
          'ParentIndexNumber': 4,
          'SeriesId': 'rz',
          'SeriesName': 'Re:Zero',
          'SeasonId': 's4',
          'ProviderIds': ids,
        }),
      ])),
      '/Items/rz': (200, itemJson('rz', 'Re:Zero', type: 'Series', extra: {'ProviderIds': ids})),
      '/Items/s4': (200, itemJson('s4', 'Season 4', type: 'Season', extra: {'IndexNumber': 4, 'ProviderIds': ids})),
      '/v4/anime/31240': (200, jikan(31240, 'Re:Zero kara Hajimeru Isekai Seikatsu', 8.2)),
      '/v4/anime/61316': (200, jikan(61316, 'Re:Zero kara Hajimeru Isekai Seikatsu 4th Season', 8.9)),
    });
    final container = ProviderContainer(overrides: fakeServerOverrides(s, animeIds: reZero));
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();

    expect(find.text('Re:Zero kara Hajimeru Isekai Seikatsu'), findsOneWidget);
    expect(find.textContaining('4th Season'), findsNothing, reason: 'S4:E1 underneath says which season');
  });

  testWidgets('title language: English shows the MAL English title', (tester) async {
    SharedPreferences.setMockInitialValues({'anime.titleLanguage': 'english'});
    await pumpApp(tester, server());
    expect(find.text("Frieren: Beyond Journey's End"), findsOneWidget);
    expect(find.text('Frieren'), findsNothing);
  });

  testWidgets('title language applies on the series page, under its logo too', (tester) async {
    SharedPreferences.setMockInitialValues({'anime.titleLanguage': 'english'});
    final s = server();
    // Like the user's server: an English name and a romaji original title.
    final withLogo = {
      ...series,
      'OriginalTitle': 'Sousou no Frieren',
      'ImageTags': {'Primary': 'p', 'Logo': 'l'},
    };
    s.routes['/Items/Latest'] = (200, [withLogo]);
    s.routes['/Items/ser1'] = (200, withLogo);
    await pumpApp(tester, s);
    await tester.tap(find.text("Frieren: Beyond Journey's End"));
    await tester.pumpAndSettle();
    // The logo is artwork; the chosen title is written under it.
    expect(find.text("Frieren: Beyond Journey's End"), findsWidgets);
    expect(find.text('Frieren'), findsNothing);
    expect(find.text('Sousou no Frieren'), findsNothing, reason: "the server's original title gives way");
  });

  testWidgets('the show page top bar slides away scrolling down, back scrolling up', (tester) async {
    await pumpApp(tester, server());
    tester.view.physicalSize = const Size(1600, 400); // short, so the page scrolls
    await tester.tap(find.text('Frieren'));
    await tester.pumpAndSettle();
    Offset barOffset() => tester.widget<AnimatedSlide>(find.byType(AnimatedSlide).first).offset;
    expect(barOffset(), Offset.zero);

    final page = find.byType(ListView).first;
    await tester.drag(page, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(barOffset(), const Offset(0, -1), reason: 'hidden while scrolling down');

    await tester.drag(page, const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(barOffset(), Offset.zero, reason: 'back on any scroll up');
  });

  testWidgets("episode names follow the title language (MAL's episode list)", (tester) async {
    SharedPreferences.setMockInitialValues({'anime.titleLanguage': 'romaji'});
    final s = server();
    s.routes['/Shows/NextUp'] = (200, pageJson([
      itemJson('ep19', 'Chance or Something More', type: 'Episode', extra: {
        'IndexNumber': 19,
        'ParentIndexNumber': 1,
        'SeriesId': 'ser1',
        'SeriesName': 'Frieren',
        'SeasonId': 'sea1',
        'ProviderIds': {'AniDB': '17617', 'Tvdb': '424536'},
      }),
    ]));
    s.routes['/Items/sea1'] = (200, itemJson('sea1', 'Season 1', type: 'Season', extra: {
      'IndexNumber': 1,
      'ProviderIds': {'AniDB': '17617', 'Tvdb': '424536'},
    }));
    s.routes['/anime/52991/_/episode'] = (200, File('test/fixtures/mal_episodes.html').readAsStringSync());
    await pumpApp(tester, s);
    expect(find.textContaining('Guuzen ka Hitsuzen ka'), findsOneWidget);
    expect(find.textContaining('Chance or Something More'), findsNothing);
  });
}
