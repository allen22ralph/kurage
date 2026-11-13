import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/router.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/app/system_nav_bar.dart';
import 'package:jellyfin_client/app/user_avatar.dart';
import 'package:jellyfin_client/features/home/depth/depth_top_bar.dart';
import 'package:jellyfin_client/features/home/depth/drum_section.dart';
import 'package:jellyfin_client/features/home/depth/tab_nav.dart';
import 'package:jellyfin_client/features/home/home_tabs.dart';
import 'package:jellyfin_client/features/library/depth/detail_parts.dart';
import 'package:jellyfin_client/features/library/depth/episode_page.dart';
import 'package:jellyfin_client/features/library/depth/episode_rows.dart';
import 'package:jellyfin_client/features/library/depth/series_page.dart';
import 'package:jellyfin_client/features/library/item_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

void main() {
  group('an overview', () {
    test('without a credit or a note is left alone', () {
      final parts = splitOverview('An elf mage outlives her party.');
      expect(parts.body, 'An elf mage outlives her party.');
      expect(parts.source, isNull);
      expect(parts.note, isNull);
    });

    test('tells a credit in brackets from the text', () {
      final parts = splitOverview('An elf mage outlives her party.\n\n(Source: Viz)');
      expect(parts.body, 'An elf mage outlives her party.');
      expect(parts.source, 'Viz');
    });

    test('tells a credit on its own line, and a note', () {
      final parts = splitOverview('The story.\nSource: Crunchyroll\nNote: Screened early.');
      expect(parts.body, 'The story.');
      expect(parts.source, 'Crunchyroll');
      expect(parts.note, 'Screened early.');
    });

    test('a word in the story is not a credit', () {
      final parts = splitOverview('The source: of all magic is lost.');
      expect(parts.source, isNull);
      expect(parts.body, 'The source: of all magic is lost.');
    });
  });

  test('the row of episodes keeps the current one, near the middle', () {
    final episodes = [for (var i = 0; i < 20; i++) BaseItem.fromJson(itemJson('e$i', 'E$i', type: 'Episode'))];
    expect(episodesAround(episodes, 'e10').map((e) => e.id), contains('e10'));
    expect(episodesAround(episodes, 'e10'), hasLength(8));
    expect(episodesAround(episodes, 'e0').first.id, 'e0');
    expect(episodesAround(episodes, 'e19').last.id, 'e19');
    expect(episodesAround(episodes.take(3).toList(), 'e1'), hasLength(3));
  });

  test('how much is left, and watched', () {
    final item = BaseItem.fromJson(itemJson('e', 'E', type: 'Episode', extra: {
      'RunTimeTicks': 26 * 60 * 10000000,
      'UserData': {'PlaybackPositionTicks': 13 * 60 * 10000000, 'PlayedPercentage': 50},
    }));
    expect(timeLeft(item), '13m left');
    expect(watchedFraction(item), 0.5);
  });

  test('a series says what it has', () {
    final seasons = [
      BaseItem.fromJson(itemJson('s0', 'Specials', type: 'Season', extra: {'IndexNumber': 0})),
      BaseItem.fromJson(itemJson('s1', 'Season 1', type: 'Season', extra: {'IndexNumber': 1})),
      BaseItem.fromJson(itemJson('s2', 'Season 2', type: 'Season', extra: {'IndexNumber': 2})),
    ];
    expect(seriesLabel(seasons), 'Series · 2 seasons · Specials');
    expect(seriesLabel(seasons.skip(1).take(1).toList()), 'Series · 1 season');
    expect(seriesLabel(null), 'Series');
  });

  group('pages', () {
    late ProviderContainer c;
    late FakeServer server;

    final series = itemJson('ser1', 'Frieren', type: 'Series', extra: {
      'ProductionYear': 2023,
      'Status': 'Continuing',
      'OfficialRating': 'TV-14',
      'CommunityRating': 9.7,
      'Overview': 'An elf mage outlives her party.\n\n(Source: Viz)',
      'Genres': ['Adventure', 'Fantasy'],
      'Tags': ['elf', 'friendship'],
      'Studios': [for (var i = 1; i <= 7; i++) {'Name': 'Studio $i'}],
      'BackdropImageTags': ['b'],
      'People': [
        {'Id': 'p1', 'Name': 'Atsumi Tanezaki', 'Role': 'Frieren', 'Type': 'Actor'},
        {'Id': 'p2', 'Name': 'Keiichiro Saito', 'Type': 'Director'},
      ],
    });
    Map<String, Object?> episode(int n, {bool played = false, int position = 0}) => itemJson('ep$n', 'Episode $n', type: 'Episode', extra: {
          'IndexNumber': n,
          'ParentIndexNumber': 1,
          'SeriesId': 'ser1',
          'SeriesName': 'Frieren',
          'SeasonId': 's1',
          'SeasonName': 'Season 1',
          'RunTimeTicks': 26 * 60 * 10000000,
          'Overview': 'Overview of episode $n.',
          'UserData': {'Played': played, 'PlaybackPositionTicks': position},
        });

    Future<void> open(
      WidgetTester tester,
      String path, {
      Size size = const Size(1440, 1000),
      String theme = 'depth',
      String effects = 'full',
      List<Map<String, Object?>>? nextUp,
      bool firstPlayed = true,
      Map<String, Object> prefs = const {},
    }) async {
      SharedPreferences.setMockInitialValues({'theme.id': theme, 'appearance.effects': effects, ...prefs});
      FlutterSecureStorage.setMockInitialValues(signedInStorage());
      final episodes = [episode(1, played: firstPlayed), episode(2, position: 13 * 60 * 10000000), episode(3), episode(4)];
      final byId = {for (final e in episodes) e['Id']: e};
      server = FakeServer({
        '/UserViews': (200, pageJson([])),
        '/UserItems/Resume': (200, pageJson([])),
        '/Shows/NextUp': (200, pageJson(nextUp ?? [episode(2, position: 13 * 60 * 10000000)])),
        '/Items/Latest': (200, []),
        '/Genres': (200, pageJson([])),
        '/Items': (200, pageJson([])),
        '/Items/ser1': (200, series),
        '/Items/mov1': (200, itemJson('mov1', 'A film', extra: {'RunTimeTicks': 2 * 3600 * 10000000, 'Overview': 'A story.', 'Genres': ['Drama']})),
        for (final e in byId.entries) '/Items/${e.key}': (200, e.value),
        '/UserPlayedItems/ep3': (200, {'Played': true}),
        '/UserFavoriteItems/ep3': (200, {'IsFavorite': true}),
        '/Items/ser1/Similar': (200, pageJson([])),
        '/Items/mov1/Similar': (200, pageJson([])),
        '/Items/ser1/LocalTrailers': (200, []),
        '/Items/mov1/LocalTrailers': (200, []),
        '/Shows/ser1/Seasons': (200, pageJson([
          itemJson('s0', 'Specials', type: 'Season', extra: {'IndexNumber': 0}),
          itemJson('s1', 'Season 1', type: 'Season', extra: {'IndexNumber': 1, 'SeriesId': 'ser1'}),
        ])),
        '/Shows/ser1/Episodes': (RequestOptions r) => (200, pageJson(r.queryParameters['seasonId'] == 's0' ? [] : episodes)),
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      c = ProviderContainer(overrides: fakeServerOverrides(server));
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
      await tester.pump(const Duration(milliseconds: 200));
      c.read(routerProvider).push(path);
      for (var i = 0; i < 14; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 150));
      }
      await tester.pump(const Duration(seconds: 3));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }

    Future<void> scrollTo(WidgetTester tester, Finder target) async {
      await tester.scrollUntilVisible(target, 300, scrollable: find.byType(Scrollable).first);
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets('series on a PC: resume, about, tabs, rows, cast', (tester) async {
      await open(tester, '/item/ser1');
      expect(find.byType(DepthSeriesPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text('Resume S1:E2'), findsOneWidget);
      expect(find.text('· 13:00'), findsOneWidget);
      expect(find.text('Mark series watched'), findsOneWidget);
      expect(find.text('SERIES · 1 SEASON · SPECIALS'), findsOneWidget);
      expect(find.text('S1'), findsOneWidget, reason: 'the big number follows the season');

      expect(find.text('Source: Viz'), findsOneWidget);
      expect(find.text('elf'), findsOneWidget, reason: 'tags as chips');
      await scrollTo(tester, find.text('Show all 7'));
      expect(find.text('Studio 6 · Studio 7'), findsNothing);
      await tester.tap(find.text('Show all 7'));
      await tester.pump();
      expect(find.textContaining('Studio 7'), findsOneWidget);

      await scrollTo(tester, find.byType(DepthEpisodeRow).first);
      expect(find.text('1 of 4 watched'), findsOneWidget);
      expect(find.text('Episode 2'), findsOneWidget);
      expect(find.byType(SeasonTabs), findsOneWidget);

      await scrollTo(tester, find.byType(DepthCastRow));
      expect(find.text('1 cast · 1 crew'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    testWidgets('choosing a season moves the number and the list', (tester) async {
      await open(tester, '/item/ser1');
      await scrollTo(tester, find.byType(SeasonTabs));
      await tester.tap(find.descendant(of: find.byType(SeasonTabs), matching: find.text('Specials')));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 150));
      }
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(DepthEpisodeRow), findsNothing);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('SP'), findsOneWidget, reason: 'the big number');
      await close(tester);
    });

    testWidgets('a row opens its episode page', (tester) async {
      await open(tester, '/item/ser1');
      await scrollTo(tester, find.text('Episode 3'));
      await tester.tap(find.text('Episode 3'));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 150));
      }
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(DepthEpisodePage), findsOneWidget);
      expect(find.text('E3'), findsOneWidget);
      await close(tester);
    });

    testWidgets('series on a phone fits, with its round actions', (tester) async {
      await open(tester, '/item/ser1', size: const Size(390, 844));
      expect(tester.takeException(), isNull);
      expect(find.text('Mark watched'), findsOneWidget);
      expect(find.text('Favorite'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
      await scrollTo(tester, find.byType(DepthEpisodeRow).first);
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    testWidgets('the main button says where the show is up to', (tester) async {
      await open(tester, '/item/ser1', nextUp: [], firstPlayed: false);
      expect(find.text('Start S1:E1'), findsOneWidget);
      await close(tester);

      await open(tester, '/item/ser1', nextUp: [episode(1)], firstPlayed: false);
      expect(find.text('Start S1:E1'), findsOneWidget);
      await close(tester);

      await open(tester, '/item/ser1', nextUp: [episode(3)]);
      expect(find.text('Continue S1:E3'), findsOneWidget);
      await close(tester);

      await open(tester, '/item/ser1', nextUp: []);
      expect(find.text('Watch again S1:E1'), findsOneWidget);
      await close(tester);
    });

    testWidgets('on a PC, marking, favorite and download sit under the hero, the main button in it', (tester) async {
      await open(tester, '/item/ser1');
      const heroEnds = 96 + 600;
      expect(tester.getTopLeft(find.text('Mark series watched')).dy, greaterThan(heroEnds));
      expect(tester.getTopLeft(find.text('Resume S1:E2')).dy, lessThan(heroEnds));
      expect(tester.getTopLeft(find.ancestor(of: find.text('Mark series watched'), matching: find.byType(GhostButton))).dx, tester.getTopLeft(find.byType(HeroPicture)).dx, reason: 'lined up with the hero, on the left');
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    testWidgets('a PC has Home\'s bar with Back and the tabs, Shows lit for a series', (tester) async {
      // Home, underneath, comes into view: it reads its files from here.
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (_) async => Directory.systemTemp.path);
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));

      await open(tester, '/item/ser1');
      expect(find.byType(PillTopBar), findsOneWidget);
      expect(find.byType(PillBackButton), findsOneWidget);
      expect(find.byType(HomeBottomNav), findsNothing);
      expect(find.descendant(of: find.byType(TabPill), matching: find.text('Shows')), findsOneWidget);
      expect(tester.widget<TabPill>(find.byType(TabPill)).tab, HomeTab.shows);
      expect(find.byTooltip('Search'), findsOneWidget);

      await tester.tap(find.descendant(of: find.byType(TabPill), matching: find.text('Movies')));
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 150));
      }
      await tester.pump(const Duration(seconds: 2));
      expect(c.read(homeTabProvider), HomeTab.movies);
      expect(find.byType(DepthSeriesPage), findsNothing);
      expect(tester.takeException(), isNull);
      await close(tester);
      await tester.pump(const Duration(seconds: 60));
    });

    testWidgets('a film lights Movies, and Back returns', (tester) async {
      await open(tester, '/item/mov1');
      expect(tester.widget<TabPill>(find.byType(TabPill)).tab, HomeTab.movies);
      await tester.tap(find.byType(PillBackButton));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(DepthSeriesPage), findsNothing);
      await close(tester);
      await tester.pump(const Duration(seconds: 60));
    });

    testWidgets('a phone has the tabs along the bottom, and the bar fits', (tester) async {
      await open(tester, '/item/ser1', size: const Size(390, 844));
      expect(find.byType(PillTopBar), findsOneWidget);
      expect(find.byType(PillBackButton), findsOneWidget);
      expect(find.byType(TabPill), findsNothing);
      expect(tester.widget<HomeBottomNav>(find.byType(HomeBottomNav)).tab, HomeTab.shows);
      expect(find.byType(HidesStatusBar), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The tools open beside Back without running out of room.
      await tester.tap(find.descendant(of: find.byType(PillTopBar), matching: find.byType(CurrentUserAvatar)).last);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byTooltip('Downloads'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    testWidgets('Classic keeps its own bar, hides the status bar, and ticks a watched episode once', (tester) async {
      await open(tester, '/item/ser1', theme: 'classic');
      expect(find.byType(PillTopBar), findsNothing);
      expect(find.byType(HidesStatusBar), findsOneWidget);
      await tester.scrollUntilVisible(find.textContaining('Episode 1'), 200, scrollable: find.byType(Scrollable).first);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      await close(tester);
    });

    testWidgets('the About section rolls in on a PC, and is simply there on a phone', (tester) async {
      Finder rolling() => find.ancestor(of: find.byType(DepthOverview).first, matching: find.byType(DrumSection));

      await open(tester, '/item/ser1');
      expect(rolling(), findsOneWidget);
      await close(tester);

      await open(tester, '/item/ser1', size: const Size(390, 844));
      expect(rolling(), findsNothing);
      await close(tester);

      await open(tester, '/item/ep2', size: const Size(390, 844));
      expect(rolling(), findsNothing);
      await close(tester);
    });

    testWidgets('on a phone, a row\'s text opens the episode; its picture selects while selecting', (tester) async {
      await open(tester, '/item/ser1', size: const Size(390, 844));
      final three = find.widgetWithText(DepthEpisodeRow, 'Episode 3');
      final four = find.widgetWithText(DepthEpisodeRow, 'Episode 4');
      await scrollTo(tester, four);
      // Both rows on screen, clear of the bar.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 350));
      await tester.pump(const Duration(seconds: 2));
      expect(find.descendant(of: four, matching: find.byIcon(Icons.play_arrow_rounded)), findsOneWidget);

      await tester.longPress(find.text('Episode 3'));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<DepthEpisodeRow>(three).selected, isTrue);

      await tester.tap(find.descendant(of: four, matching: find.byType(EpisodeThumb)));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<DepthEpisodeRow>(four).selected, isTrue, reason: 'not playing while selecting');

      await tester.tap(find.descendant(of: four, matching: find.byType(EpisodeThumb)));
      await tester.tap(find.descendant(of: three, matching: find.byType(EpisodeThumb)));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<DepthEpisodeRow>(three).selected, isFalse);

      await tester.tap(find.text('Episode 3'));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 150));
      }
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(DepthEpisodePage), findsOneWidget);
      await close(tester);
    });

    testWidgets('Classic: an episode\'s title opens its page', (tester) async {
      await open(tester, '/item/ser1', theme: 'classic');
      final title = find.textContaining('Episode 3');
      await tester.scrollUntilVisible(title, 200, scrollable: find.byType(Scrollable).first);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(title);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<ItemDetailScreen>(find.byType(ItemDetailScreen).last).itemId, 'ep3');
      await close(tester);
    });

    testWidgets('the bar in every theme: tabs in Classic, and what\'s taken off stays off', (tester) async {
      // Classic on a PC: the tabs in the bar's true centre.
      await open(tester, '/', theme: 'classic');
      final pill = find.byType(ClassicTabBar);
      expect(pill, findsOneWidget);
      expect(tester.getCenter(pill).dx, closeTo(1440 / 2, 1));
      expect(find.byType(HomeBottomNav), findsNothing);
      expect(find.byTooltip('Downloads'), findsOneWidget);
      await close(tester);
      await tester.pump(const Duration(seconds: 60));

      // A phone: along the bottom.
      await open(tester, '/', theme: 'classic', size: const Size(390, 844));
      expect(find.byType(TabPill), findsNothing);
      expect(find.byType(HomeBottomNav), findsOneWidget);
      await close(tester);
      await tester.pump(const Duration(seconds: 60));

      // Taken off, in Classic and Depth alike; Settings stays.
      for (final theme in ['classic', 'depth']) {
        await open(
          tester,
          '/',
          theme: theme,
          prefs: {
            'homeBar.right': ['refresh', 'search'],
            'homeBar.centre': ['shows', 'downloads'],
          },
        );
        expect(find.byTooltip('Favorites'), findsNothing, reason: theme);
        expect(find.byTooltip('Settings'), findsOneWidget, reason: theme);
        final bar = find.byType(theme == 'classic' ? ClassicTabBar : TabPill);
        expect(find.descendant(of: bar, matching: find.text('Movies')), findsNothing, reason: theme);
        expect(find.descendant(of: bar, matching: find.text('Shows')), findsOneWidget, reason: theme);
        expect(find.descendant(of: bar, matching: find.text('Downloads')), findsOneWidget, reason: 'added among the tabs');
        await close(tester);
        await tester.pump(const Duration(seconds: 60));
      }

      // Only Home left: no tabs at all.
      await open(tester, '/', theme: 'classic', prefs: {'homeBar.centre': <String>[]});
      expect(find.byType(ClassicTabBar), findsNothing);
      await close(tester);
      await tester.pump(const Duration(seconds: 60));
    });

    testWidgets('tabs on a phone: five share the width, more slide sideways', (tester) async {
      final nav = find.byType(HomeBottomNav);
      final sliding = find.descendant(of: nav, matching: find.byType(Scrollable));

      await open(tester, '/', theme: 'classic', size: const Size(390, 844), prefs: {'homeBar.centre': ['movies', 'shows', 'downloads', 'favorites']});
      expect(sliding, findsNothing);
      expect(tester.takeException(), isNull);
      final home = find.descendant(of: nav, matching: find.text('Home'));
      final shows = find.descendant(of: nav, matching: find.text('Shows'));
      final five = (tester.getCenter(home), tester.getCenter(shows));
      await close(tester);
      await tester.pump(const Duration(seconds: 60));

      await open(
        tester,
        '/',
        theme: 'classic',
        size: const Size(390, 844),
        prefs: {'homeBar.centre': ['movies', 'shows', 'downloads', 'favorites', 'search', 'notifications', 'refresh']},
      );
      expect(sliding, findsOneWidget);
      expect(tester.takeException(), isNull);
      expect((tester.getCenter(home), tester.getCenter(shows)), five, reason: 'spaced just as five are');
      expect(tester.getTopLeft(find.descendant(of: nav, matching: find.text('Search'))).dx, greaterThanOrEqualTo(390 - 4), reason: 'the sixth waits past the five');
      await tester.drag(sliding, const Offset(-600, 0));
      await tester.pump(const Duration(seconds: 1));
      expect(find.descendant(of: nav, matching: find.text('Refresh')), findsOneWidget, reason: 'reached by sliding');
      await close(tester);
      await tester.pump(const Duration(seconds: 60));
    });

    testWidgets('Classic has the same main button, at the margin', (tester) async {
      await open(tester, '/item/ser1', size: const Size(390, 844), theme: 'classic', nextUp: [], firstPlayed: false);
      expect(find.text('Start S1:E1'), findsOneWidget);
      // First in its row: no gap before it.
      expect(tester.getTopLeft(find.ancestor(of: find.text('Start S1:E1'), matching: find.byType(FilledButton))).dx, 16);
      await close(tester);

      await open(tester, '/item/ser1', theme: 'classic', nextUp: [episode(2, position: 13 * 60 * 10000000)]);
      expect(find.text('Resume S1:E2 · 13:00'), findsOneWidget);
      await close(tester);

      await open(tester, '/item/ser1', theme: 'classic', nextUp: [episode(3)]);
      expect(find.text('Continue S1:E3'), findsOneWidget);
      await close(tester);

      await open(tester, '/item/ser1', theme: 'classic', nextUp: []);
      expect(find.text('Watch again S1:E1'), findsOneWidget);
      await close(tester);
    });

    testWidgets('swipes do what they\'re set to, in Classic too', (tester) async {
      await open(
        tester,
        '/item/ser1',
        size: const Size(390, 844),
        theme: 'classic',
        prefs: {'library.swipeLeft': 'none', 'library.swipeRight': 'favorite'},
      );
      final row = find.textContaining('Episode 3');
      await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<Text>(row.first).maxLines, 2, reason: 'a long title stays a line or two');

      Future<void> swipe(double by) async {
        await tester.timedDrag(row, Offset(by, 0), const Duration(milliseconds: 400));
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 150));
        }
      }

      await swipe(-160);
      expect(server.requestsTo('/UserPlayedItems/ep3'), isEmpty, reason: 'left is set to nothing');
      expect(server.requestsTo('/UserFavoriteItems/ep3'), isEmpty);

      await swipe(160);
      expect(server.requestsTo('/UserFavoriteItems/ep3').map((r) => r.method), ['POST']);
      expect(tester.takeException(), isNull);
      await close(tester);
      await tester.pump(const Duration(seconds: 60));
    });

    testWidgets('on a phone, swiping a row left marks it, and again unmarks it', (tester) async {
      await open(tester, '/item/ser1', size: const Size(390, 844));
      final row = find.widgetWithText(DepthEpisodeRow, 'Episode 3');
      await scrollTo(tester, row);
      Iterable<String> marks() => server.requestsTo('/UserPlayedItems/ep3').map((r) => r.method);

      Future<void> swipe(double by) async {
        await tester.timedDrag(row, Offset(by, 0), const Duration(milliseconds: 400));
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 150));
        }
      }

      await swipe(-40);
      expect(marks(), isEmpty, reason: 'not far enough');
      await swipe(160);
      expect(marks(), isEmpty, reason: 'right does nothing yet');
      expect(tester.getTopLeft(row).dx, tester.getTopLeft(find.widgetWithText(DepthEpisodeRow, 'Episode 4')).dx);

      await swipe(-160);
      expect(marks(), ['POST']);
      expect(find.descendant(of: row, matching: find.text('Watched')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));

      await swipe(-160);
      expect(marks(), ['POST', 'DELETE']);
      expect(find.descendant(of: row, matching: find.text('Watched')), findsNothing);
      expect(tester.takeException(), isNull);
      await close(tester);
      await tester.pump(const Duration(seconds: 60));
    });

    testWidgets('a film has no episodes', (tester) async {
      await open(tester, '/item/mov1');
      expect(find.byType(DepthSeriesPage), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('MOVIE · 2H 0M'), findsOneWidget);
      expect(find.byType(SeasonTabs), findsNothing);
      expect(find.text('Episodes'), findsNothing);
      await close(tester);
    });

    testWidgets('episode on a PC: resume, up next, the season, a row', (tester) async {
      await open(tester, '/item/ep2');
      expect(find.byType(DepthEpisodePage), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text('Resume from 13:00'), findsOneWidget);
      expect(find.text('· 13m left'), findsOneWidget);
      expect(find.text('From start'), findsOneWidget);
      expect(find.text('E2'), findsOneWidget);
      expect(find.text('Frieren'), findsOneWidget, reason: 'the chip back to the series');
      await scrollTo(tester, find.text('UP NEXT'));
      expect(find.text('S1:E3 · 26m'), findsOneWidget);
      expect(find.text('1 of 4 watched'), findsOneWidget);
      await scrollTo(tester, find.text('NOW VIEWING'));
      expect(find.text('NOW VIEWING'), findsOneWidget);
      await close(tester);
    });

    testWidgets('the last episode has no up next; watched says play again', (tester) async {
      await open(tester, '/item/ep4');
      expect(find.text('UP NEXT'), findsNothing);
      expect(find.text('Play'), findsOneWidget);
      await close(tester);
      await open(tester, '/item/ep1');
      expect(find.text('Play again'), findsOneWidget);
      expect(find.text('Watched'), findsOneWidget);
      await close(tester);
    });

    testWidgets('the chip goes to the series; another episode replaces the page', (tester) async {
      await open(tester, '/item/ep2');
      await tester.tap(find.text('Frieren'));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 150));
      }
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(DepthSeriesPage), findsOneWidget);
      await close(tester);
    });

    testWidgets('episode on a phone: up next and more episodes', (tester) async {
      await open(tester, '/item/ep2', size: const Size(390, 844));
      expect(tester.takeException(), isNull);
      expect(find.text('Resume from 13:00'), findsOneWidget);
      await scrollTo(tester, find.text('UP NEXT'));
      await scrollTo(tester, find.text('More episodes'));
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    testWidgets('Lite: no drifting picture, and it still all shows', (tester) async {
      await open(tester, '/item/ser1', effects: 'lite');
      expect(find.text('Resume S1:E2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    testWidgets('Classic keeps its own page', (tester) async {
      await open(tester, '/item/ser1', theme: 'classic');
      expect(find.byType(DepthSeriesPage), findsNothing);
      expect(find.text('Resume S1:E2 · 13:00'), findsOneWidget);
      await close(tester);
    });

  });
}
