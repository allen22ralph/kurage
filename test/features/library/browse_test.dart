import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/router.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/features/auth/connect_screen.dart';
import 'package:jellyfin_client/features/home/home_screen.dart';
import 'package:jellyfin_client/features/library/item_detail_screen.dart';
import 'package:jellyfin_client/features/library/navigation.dart';
import 'package:jellyfin_client/features/search/search_screen.dart';

import '../../support/fake_server.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    SharedPreferences.setMockInitialValues({});
  });

  late ProviderContainer container;

  /// The detail page on top: (item id, season id).
  (String, String?) detailShown(WidgetTester tester) {
    final page = tester.widget<ItemDetailScreen>(find.byType(ItemDetailScreen).last);
    return (page.itemId, page.seasonId);
  }

  Future<void> pumpApp(WidgetTester tester, FakeServer server) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    container = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const JellyfinClientApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  final series = itemJson('ser1', 'Frieren', type: 'Series', extra: {
    'ProductionYear': 2023,
    'Status': 'Continuing',
    'Overview': 'An elf mage outlives her party.',
    'Genres': ['Fantasy'],
    'UserData': {'Played': false, 'UnplayedItemCount': 10},
  });

  Map<String, Object> homeRoutes() => {
        '/UserViews': (
          200,
          pageJson([
            itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {
              'CollectionType': 'tvshows',
            }),
          ]),
        ),
        '/UserItems/Resume': (
          200,
          pageJson([
            itemJson('ep3', 'Killing Magic', type: 'Episode', extra: {
              'SeriesId': 'ser1',
              'SeriesName': 'Frieren',
              'SeasonId': 'sea1',
              'IndexNumber': 3,
              'ParentIndexNumber': 1,
              'UserData': {
                'PlaybackPositionTicks': 1000,
                'PlayedPercentage': 30,
              },
            }),
          ]),
        ),
        '/Shows/NextUp': (200, pageJson([])),
        '/Items/Latest': (200, [series]),
      };

  testWidgets('home shows resume, libraries and latest rows', (tester) async {
    await pumpApp(tester, FakeServer(homeRoutes()));

    expect(find.text('Continue watching'), findsOneWidget);
    expect(find.text('S1:E3 · Killing Magic'), findsOneWidget);
    expect(find.text('Next up'), findsNothing, reason: 'empty rows hide');
    expect(find.text('Libraries'), findsOneWidget);
    expect(find.text('Recently added in Anime'), findsOneWidget);
    expect(find.text('Frieren'), findsWidgets);

    // The unwatched count is a small corner badge, not a card-sized block.
    final badge = tester.getSize(
      find.ancestor(of: find.text('10'), matching: find.byType(Container)).first,
    );
    expect(badge.width, lessThan(40));
    expect(badge.height, lessThan(30));
  });

  testWidgets('continue watching captions open the show or the episode',
      (tester) async {
    await pumpApp(tester, FakeServer(homeRoutes()));

    // Episode line -> that episode's page (not the player).
    await tester.tap(find.text('S1:E3 · Killing Magic'));
    await tester.pumpAndSettle();
    expect(detailShown(tester), ('ep3', null));

    container.read(routerProvider).go('/');
    await tester.pumpAndSettle();

    // Show name -> the series page at the episode's season. 'Frieren' also
    // labels the series card in Recently added; the first is the episode's.
    await tester.tap(find.text('Frieren').first);
    await tester.pumpAndSettle();
    expect(detailShown(tester), ('ser1', 'sea1'));
  });

  testWidgets('leaving the player: to the page before it, or a page from its title in its place',
      (tester) async {
    await pumpApp(tester, FakeServer(homeRoutes()));
    final episode = BaseItem.fromJson(itemJson('ep3', 'Killing Magic', type: 'Episode', extra: {
      'SeriesId': 'ser1',
      'SeasonId': 'sea1',
    }));
    final router = container.read(routerProvider);

    // Back: the page it was opened from. Here the series page, opened from search.
    router.push('/search');
    await tester.pumpAndSettle();
    router.push('/item/ser1');
    await tester.pumpAndSettle();
    router.push('/item/ep3');
    await tester.pumpAndSettle();
    exitPlayer(tester.element(find.byType(ItemDetailScreen).last));
    await tester.pumpAndSettle();
    expect(tester.widget<ItemDetailScreen>(find.byType(ItemDetailScreen).last).itemId, 'ser1');

    // The title's show: in its place, so Back goes where it would have.
    router.push('/item/ep3');
    await tester.pumpAndSettle();
    exitPlayerTo(tester.element(find.byType(ItemDetailScreen).last), seriesPathOf(episode));
    await tester.pumpAndSettle();
    expect(detailShown(tester), ('ser1', 'sea1'));
    router.pop();
    await tester.pumpAndSettle();
    expect(tester.widget<ItemDetailScreen>(find.byType(ItemDetailScreen).last).itemId, 'ser1');
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
  });

  testWidgets('a server out of reach: off to the server screen, still signed in, and back Home once it answers', (tester) async {
    final routes = {...homeRoutes()};
    final working = routes['/UserViews'];
    var down = true;
    routes['/UserViews'] = (RequestOptions o) => down ? (-1, null) : working as FakeResponse;
    await tester.runAsync(() async {});
    await pumpApp(tester, FakeServer(routes));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(ConnectScreen), findsOneWidget);
    expect(find.textContaining("Can't reach"), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.textContaining('JellyfinException'), findsNothing);

    down = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.textContaining("Can't reach"), findsNothing);
    expect(find.byType(ConnectScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 60));
  });

  testWidgets('favorites are grouped: series, movies and episodes apart', (tester) async {
    final server = FakeServer({
      ...homeRoutes(),
      '/Items': (
        200,
        pageJson([
          itemJson('e1', 'An episode', type: 'Episode', extra: {'SeriesName': 'A show', 'IndexNumber': 1, 'ParentIndexNumber': 1}),
          itemJson('s1', 'A show', type: 'Series'),
          itemJson('m1', 'A film', type: 'Movie'),
        ]),
      ),
    });
    await pumpApp(tester, server);
    container.read(routerProvider).push('/favorites');
    await tester.pumpAndSettle();
    final series = tester.getTopLeft(find.text('Series · 1')).dy;
    final movies = tester.getTopLeft(find.text('Movies · 1')).dy;
    final episodes = tester.getTopLeft(find.text('Episodes · 1')).dy;
    expect(series, lessThan(movies));
    expect(movies, lessThan(episodes));
  });

  testWidgets('library grid loads the next page when scrolled', (tester) async {
    final server = FakeServer({
      ...homeRoutes(),
      '/Items/lib1': (
        200,
        itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {
          'CollectionType': 'tvshows',
        }),
      ),
      '/Genres': (200, pageJson([itemJson('g1', 'Fantasy', type: 'Genre')])),
      '/Items': (options) {
        final start = options.queryParameters['startIndex'] as int;
        final count = start == 0 ? 100 : 20;
        return (
          200,
          pageJson(
            [
              for (var i = start; i < start + count; i++)
                itemJson('s$i', 'Show $i', type: 'Series'),
            ],
            total: 120,
            start: start,
          ),
        );
      },
    });
    await pumpApp(tester, server);

    await tester.tap(find.text('Anime').first);
    await tester.pumpAndSettle();

    expect(find.text('120 items'), findsOneWidget);
    // (The library's requests: Home's This week asks /Items too.)
    final first = server.requestsTo('/Items').firstWhere((r) => r.queryParameters['parentId'] != null).queryParameters;
    expect(first['parentId'], 'lib1');
    expect(first['includeItemTypes'], 'Series');

    await tester.fling(find.byType(CustomScrollView), const Offset(0, -20000), 5000);
    await tester.pumpAndSettle();

    final starts = server
        .requestsTo('/Items')
        .where((r) => r.queryParameters['parentId'] != null)
        .map((r) => r.queryParameters['startIndex'])
        .toList();
    expect(starts, [0, 100]);
    expect(find.text('Show 119'), findsOneWidget);
  });

  testWidgets('series page lists seasons and episodes; mark watched',
      (tester) async {
    var played = false;
    final server = FakeServer({
      ...homeRoutes(),
      '/Items/ser1': (_) => (
            200,
            {
              ...series,
              'UserData': {'Played': played},
            },
          ),
      '/Shows/ser1/Seasons': (
        200,
        pageJson([
          itemJson('sea1', 'Season 1', type: 'Season', extra: {
            'IndexNumber': 1,
            'SeriesId': 'ser1',
          }),
        ]),
      ),
      '/Shows/ser1/Episodes': (
        200,
        pageJson([
          itemJson('ep1', 'The Journey\'s End', type: 'Episode', extra: {
            'IndexNumber': 1,
            'RunTimeTicks': 24 * 60 * 10000000,
          }),
          itemJson('ep2', 'It Didn\'t Have to Be Magic', type: 'Episode', extra: {
            'IndexNumber': 2,
          }),
        ]),
      ),
      '/Items/ser1/Similar': (200, pageJson([])),
      '/UserPlayedItems/ser1': (_) {
        played = true;
        return (200, {'Played': true});
      },
    });
    await pumpApp(tester, server);

    await tester.tap(find.text('Frieren').last);
    await tester.pumpAndSettle();

    expect(find.text('An elf mage outlives her party.'), findsOneWidget);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('1. The Journey\'s End'), findsOneWidget);
    expect(find.text('24m'), findsOneWidget);
    expect(find.textContaining('2023–'), findsOneWidget);

    await tester.tap(find.text('Mark series watched'));
    await tester.pumpAndSettle();

    expect(server.requestsTo('/UserPlayedItems/ser1').single.method, 'POST');
    expect(find.text('Series watched'), findsOneWidget);
  });

  testWidgets('episodes and seasons can be marked watched one by one',
      (tester) async {
    final played = <String>{'ep2'};
    final server = FakeServer({
      ...homeRoutes(),
      '/Items/ser1': (200, series),
      '/Shows/ser1/Seasons': (_) => (
            200,
            pageJson([
              itemJson('sea1', 'Season 1', type: 'Season', extra: {
                'IndexNumber': 1,
                'SeriesId': 'ser1',
                'UserData': {'Played': played.containsAll(['ep1', 'ep2'])},
              }),
            ]),
          ),
      '/Shows/ser1/Episodes': (_) => (
            200,
            pageJson([
              for (final (id, n) in [('ep1', 1), ('ep2', 2)])
                itemJson(id, 'Episode $n', type: 'Episode', extra: {
                  'IndexNumber': n,
                  'UserData': {'Played': played.contains(id)},
                }),
            ]),
          ),
      '/Items/ser1/Similar': (200, pageJson([])),
      for (final id in ['ep1', 'ep2', 'sea1'])
        '/UserPlayedItems/$id': (RequestOptions o) {
          if (o.method == 'POST') {
            played.addAll(id == 'sea1' ? ['ep1', 'ep2'] : [id]);
          } else {
            played.removeAll(id == 'sea1' ? ['ep1', 'ep2'] : [id]);
          }
          return (200, {'Played': o.method == 'POST'});
        },
    });
    await pumpApp(tester, server);
    await tester.tap(find.text('Frieren').last);
    await tester.pumpAndSettle();

    // Episode 1 unwatched, episode 2 watched; the season isn't done.
    expect(find.byTooltip('Season 1 · watched'), findsNothing);
    expect(find.byTooltip('Mark watched'), findsOneWidget);
    expect(find.byTooltip('Mark unwatched'), findsOneWidget);

    Future<void> tapVisible(Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    await tapVisible(find.byTooltip('Mark watched'));
    expect(server.requestsTo('/UserPlayedItems/ep1').single.method, 'POST');
    expect(find.byTooltip('Mark unwatched'), findsNWidgets(2));

    await tapVisible(find.byTooltip('Mark unwatched').last);
    expect(server.requestsTo('/UserPlayedItems/ep2').single.method, 'DELETE');

    // The whole season at once.
    await tapVisible(find.text('Mark season watched'));
    expect(server.requestsTo('/UserPlayedItems/sea1').single.method, 'POST');
    expect(find.text('Mark season unwatched'), findsOneWidget);
    // The season chip now shows it's fully watched.
    expect(find.byTooltip('Season 1 · watched'), findsOneWidget);
    expect(find.byTooltip('Mark unwatched'), findsNWidgets(2));
    // The series itself was never touched.
    expect(server.requestsTo('/UserPlayedItems/ser1'), isEmpty);
  });

  testWidgets('select several episodes: long press, Shift+click, then mark them watched together', (tester) async {
    final played = <String>{};
    final server = FakeServer({
      ...homeRoutes(),
      '/Items/ser1': (200, series),
      '/Shows/ser1/Seasons': (
        200,
        pageJson([
          itemJson('sea1', 'Season 1', type: 'Season', extra: {'IndexNumber': 1, 'SeriesId': 'ser1'}),
        ]),
      ),
      '/Shows/ser1/Episodes': (_) => (
            200,
            pageJson([
              for (var n = 1; n <= 4; n++)
                itemJson('ep$n', 'Episode $n', type: 'Episode', extra: {
                  'IndexNumber': n,
                  'UserData': {'Played': played.contains('ep$n')},
                }),
            ]),
          ),
      '/Items/ser1/Similar': (200, pageJson([])),
      for (var n = 1; n <= 4; n++)
        'POST /UserPlayedItems/ep$n': (RequestOptions o) {
          played.add('ep$n');
          return (200, {'Played': true});
        },
    });
    await pumpApp(tester, server);
    await tester.tap(find.text('Frieren').last);
    await tester.pumpAndSettle();

    Finder episode(int n) => find.text('$n. Episode $n');
    // Long press selects it, and starts selecting (a floating bar).
    await tester.scrollUntilVisible(episode(4), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.longPress(episode(1));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing, reason: 'shown by highlighting the row');

    // Shift+click: a range.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(episode(3));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);

    // The bar slides away while scrolling down, and back on scrolling up.
    Offset bar() => tester.widget<AnimatedSlide>(find.ancestor(of: find.text('3 selected'), matching: find.byType(AnimatedSlide))).offset;
    final page = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(page).position;
    position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.drag(page, const Offset(0, -60));
    await tester.pumpAndSettle();
    if (position.pixels < position.maxScrollExtent - 4) expect(bar(), isNot(Offset.zero), reason: 'hidden scrolling down');
    await tester.drag(page, const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(bar(), Offset.zero, reason: 'back on scrolling up');

    await tester.tap(find.widgetWithText(TextButton, 'Mark watched'));
    await tester.pumpAndSettle();
    expect(played, {'ep1', 'ep2', 'ep3'});
    expect(find.textContaining('selected'), findsNothing, reason: 'done: no longer selecting');
  });

  testWidgets('"Select from here to the end" picks the rest of the season', (tester) async {
    final server = FakeServer({
      ...homeRoutes(),
      '/Items/ser1': (200, series),
      '/Shows/ser1/Seasons': (
        200,
        pageJson([
          itemJson('sea1', 'Season 1', type: 'Season', extra: {'IndexNumber': 1, 'SeriesId': 'ser1'}),
        ]),
      ),
      '/Shows/ser1/Episodes': (
        200,
        pageJson([
          for (var n = 1; n <= 5; n++) itemJson('ep$n', 'Episode $n', type: 'Episode', extra: {'IndexNumber': n}),
        ]),
      ),
      '/Items/ser1/Similar': (200, pageJson([])),
    });
    await pumpApp(tester, server);
    await tester.tap(find.text('Frieren').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('2. Episode 2'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    // Right-click: the episode's menu.
    await tester.tapAt(tester.getCenter(find.text('2. Episode 2')), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    await tester.tap(find.text('Select from here to the end'));
    await tester.pumpAndSettle();
    expect(find.text('4 selected'), findsOneWidget);
  });

  testWidgets('F5 (or Ctrl+R) refreshes Home', (tester) async {
    final server = FakeServer(homeRoutes());
    await pumpApp(tester, server);
    final before = server.requestsTo('/UserViews').length;
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(server.requestsTo('/UserViews').length, before + 1);
    await tester.tap(find.byTooltip('Refresh (F5)'));
    await tester.pumpAndSettle();
    expect(server.requestsTo('/UserViews').length, before + 2);
  });
}
