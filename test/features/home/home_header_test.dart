import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/features/home/home_header.dart';
import 'package:jellyfin_client/features/library/item_detail_screen.dart';
import 'package:jellyfin_client/features/home/home_actions.dart';
import 'package:jellyfin_client/features/home/home_header_settings.dart';
import 'package:jellyfin_client/features/library/library_providers.dart';
import 'package:jellyfin_client/features/settings/appearance.dart';
import 'package:jellyfin_client/theme/theme_choice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  group('"A mix" of featured titles', () {
    List<BaseItem> items(String prefix, int n) => [
      for (var i = 0; i < n; i++) BaseItem.fromJson(itemJson('$prefix$i', '$prefix$i', type: 'Series')),
    ];
    List<String> mix({int watching = 6, int fresh = 6, int random = 20, void Function(List<BaseItem>)? shuffle}) => [
      for (final i in composeFeaturedMix(
        watching: items('w', watching),
        fresh: items('f', fresh),
        random: items('r', random),
        count: 10,
        shuffle: shuffle ?? (_) {},
      ))
        i.id,
    ];

    test('random picks always reach the five on screen, however much is being watched', () {
      final first = mix().take(5).toList();
      expect(first.where((id) => id.startsWith('w')), hasLength(2));
      expect(first.where((id) => id.startsWith('f')), hasLength(1));
      expect(first.where((id) => id.startsWith('r')), hasLength(2));
      expect(mix(), hasLength(10));
    });

    test('a new selection each time, not always the same five', () {
      void reversed(List<BaseItem> l) {
        final r = l.reversed.toList();
        l.setAll(0, r);
      }

      final seen = mix(shuffle: reversed).take(5).toSet();
      expect(seen, isNot(equals(mix().take(5).toSet())));
    });

    test('nothing being watched or new: all random, still five', () {
      expect(mix(watching: 0, fresh: 0).take(5), hasLength(5));
      expect(mix(watching: 0, fresh: 0).toSet(), hasLength(10));
    });

    test('a title in two lists shows once', () {
      final shared = items('x', 3);
      final out = composeFeaturedMix(watching: shared, fresh: shared, random: shared, count: 10, shuffle: (_) {});
      expect([for (final i in out) i.id], unorderedEquals(['x0', 'x1', 'x2']));
    });
  });

  group('how long a trailer plays', () {
    const theme = Duration(seconds: 30);
    const long = Duration(minutes: 2);
    const short = Duration(seconds: 20);

    test('the theme\'s limit by default', () {
      expect(TrailerLength.standard.playFor(theme, long), theme);
      expect(TrailerLength.standard.playFor(theme, null), theme);
    });

    test('the chosen limit, or less for a shorter trailer', () {
      expect(TrailerLength.s60.playFor(theme, long), const Duration(minutes: 1));
      expect(TrailerLength.s60.playFor(theme, short), short);
    });

    test('the full trailer, however long', () {
      expect(TrailerLength.full.playFor(theme, long), long);
      expect(TrailerLength.full.playFor(theme, null), greaterThan(long), reason: 'its end moves it on');
    });
  });

  group('settings that can\'t apply are greyed', () {
    Future<void> pump(WidgetTester tester, {required String theme, required String effects}) async {
      SharedPreferences.setMockInitialValues({'theme.id': theme, 'appearance.effects': effects});
      FlutterSecureStorage.setMockInitialValues(signedInStorage());
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: fakeServerOverrides(FakeServer({}), header: true));
      addTearDown(c.dispose);
      await tester.runAsync(() async {
        await c.read(appearanceProvider.future);
        await c.read(themeChoiceProvider.future);
        await c.read(homeHeaderSettingsProvider.future);
      });
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: HomeHeaderSection(isTv: false)))),
      ));
      await tester.pump();
    }

    bool canUse(WidgetTester tester, String title) =>
        tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title)).onChanged != null;

    testWidgets('Depth on Lite: everything about trailers and previews', (tester) async {
      await pump(tester, theme: 'depth', effects: 'lite');
      expect(canUse(tester, 'Trailers start muted'), isFalse);
      expect(canUse(tester, 'Previews in rows'), isFalse);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Play each trailer for')).enabled, isFalse);
      expect(find.text('Off while Appearance > Effects is Lite'), findsWidgets);
    });

    testWidgets('Depth on Balanced: previews only', (tester) async {
      await pump(tester, theme: 'depth', effects: 'balanced');
      expect(canUse(tester, 'Trailers start muted'), isTrue);
      expect(canUse(tester, 'Previews in rows'), isFalse);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Play each trailer for')).enabled, isTrue);
    });

    testWidgets('Classic doesn\'t follow Effects', (tester) async {
      await pump(tester, theme: 'classic', effects: 'lite');
      expect(canUse(tester, 'Trailers start muted'), isTrue);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Play each trailer for')).enabled, isTrue);
    });
  });

  test('a genre added by an earlier build is dropped from the bar', () async {
    SharedPreferences.setMockInitialValues({
      'homeBar.centre': ['movies', 'genre:Fantasy'],
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect((await c.read(homeBarSettingsProvider.future)).centre, ['movies']);
  });

  testWidgets('the top bar\'s settings: add from what isn\'t on it, libraries too; remove', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: fakeServerOverrides(FakeServer({
        '/UserViews': (200, pageJson([itemJson('lib1', 'Anime', type: 'CollectionFolder')])),
        '/Items': (200, pageJson([itemJson('pl1', 'Road trip', type: 'Playlist')])),
      })),
    );
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await c.read(sessionControllerProvider.future);
      await c.read(homeBarSettingsProvider.future);
      await c.read(viewsProvider.future);
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: HomeBarSection()))),
    ));
    // The section asks for the playlists: let that arrive.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    HomeBarSettings bar() => c.read(homeBarSettingsProvider).requireValue;

    // Home, Settings and the account can't be removed.
    expect(find.byTooltip('Remove Home'), findsNothing);
    expect(find.byTooltip('Remove Settings'), findsNothing);

    await tester.tap(find.byTooltip('Remove Downloads'));
    await tester.pump();
    expect(bar().right, isNot(contains('downloads')));

    // It can go in the centre now, with the library.
    await tester.tap(find.byTooltip('Add to Centre tabs'));
    await tester.pumpAndSettle();
    expect(find.text('Anime'), findsOneWidget);
    expect(find.widgetWithText(SimpleDialogOption, 'Movies'), findsNothing, reason: 'already here');
    expect(find.text('Moves from the right toolbar'), findsWidgets, reason: 'Search and the like can move here');
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'Downloads'));
    await tester.pumpAndSettle();
    expect(bar().centre, ['movies', 'shows', 'downloads']);

    // From the right to the centre: Search moves, and is only on one side.
    await tester.tap(find.byTooltip('Add to Centre tabs'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'Search'));
    await tester.pumpAndSettle();
    expect(bar().centre, contains('search'));
    expect(bar().right, isNot(contains('search')));

    await tester.tap(find.byTooltip('Add to Right toolbar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'Anime'));
    await tester.pumpAndSettle();
    expect(bar().right.last, 'library:lib1');

    // A playlist, from its own group.
    await tester.tap(find.byTooltip('Add to Centre tabs'));
    await tester.pumpAndSettle();
    expect(find.text('SINGLE PLAYLISTS'), findsOneWidget);
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'Road trip'));
    await tester.pumpAndSettle();
    expect(bar().centre.last, 'playlist:pl1');
    expect(find.widgetWithText(InputChip, 'Road trip'), findsOneWidget);
  });

  Map<String, Object?> show(String id, String name, {int seasons = 2}) => itemJson(id, name, type: 'Series', extra: {
        'Overview': '$name overview.',
        'Genres': ['Adventure', 'Fantasy'],
        'CommunityRating': 8.4,
        'ProductionYear': 2023,
        'OfficialRating': 'TV-14',
        'ChildCount': seasons,
        'BackdropImageTags': ['b-$id'],
        'LocalTrailerCount': 0,
      });

  late FakeServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final shows = {'dd': show('dd', 'Delicious in Dungeon', seasons: 1), 'fr': show('fr', 'Frieren')};
    FakeResponse nextUp(RequestOptions r) => r.queryParameters['seriesId'] == 'dd'
        ? (200, pageJson([itemJson('e5', 'Episode 5', type: 'Episode', extra: {'IndexNumber': 5, 'ParentIndexNumber': 1, 'SeriesId': 'dd', 'SeriesName': 'Delicious in Dungeon'})]))
        : (200, pageJson([]));
    FakeResponse items(RequestOptions r) {
      final ids = (r.queryParameters['ids'] as String?)?.split(',');
      return (200, pageJson([for (final id in ids ?? shows.keys.toList()) ?shows[id]]));
    }

    server = FakeServer({
      '/UserViews': (200, pageJson([itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {'CollectionType': 'tvshows'})])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': nextUp,
      '/Items/Latest': (200, [shows['dd'], shows['fr']]),
      '/Items': items,
    });
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester, {Size size = const Size(1600, 1000)}) async {
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(server, header: true));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return c;
  }

  testWidgets('the header features a show: title, details, overview, Play S1:E5; moves on by itself', (tester) async {
    await pumpApp(tester);
    final header = find.byType(HomeHeader);
    expect(header, findsOneWidget);
    Finder inHeader(Finder f) => find.descendant(of: header, matching: f);
    expect(inHeader(find.text('Delicious in Dungeon')), findsOneWidget, reason: 'no logo: the title instead');
    expect(inHeader(find.text('★ 8.4')), findsOneWidget);
    expect(inHeader(find.text('1 season')), findsOneWidget);
    expect(inHeader(find.text('TV-14')), findsOneWidget);
    expect(inHeader(find.text('Adventure · Fantasy')), findsOneWidget);
    expect(inHeader(find.text('Play S1:E5')), findsOneWidget);
    expect(inHeader(find.text('1 / 2')), findsOneWidget);

    // No trailer: 10 seconds, then the next show.
    for (var i = 0; i < 44; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(inHeader(find.text('2 / 2')), findsOneWidget);
    expect(inHeader(find.text('Frieren')), findsWidgets);

    // The arrow on hover goes back.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(header));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(inHeader(find.byTooltip('Previous')));
    await tester.pump(const Duration(milliseconds: 700));
    expect(inHeader(find.text('1 / 2')), findsOneWidget);
    await gesture.removePointer();
    await tester.pumpWidget(const SizedBox()); // stop the header's timer
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('on a phone, pause and mute stay clear of the buttons', (tester) async {
    await pumpApp(tester, size: const Size(390, 844));
    final pause = tester.getRect(find.byTooltip('Pause'));
    final favourite = tester.getRect(find.byTooltip('Add to favourites'));
    expect(pause.overlaps(favourite), isFalse);
    expect(pause.bottom, lessThan(favourite.top));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets("a click on the header's picture opens the show; its buttons keep their own action", (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ItemDetailScreen), findsNothing, reason: 'a button does its own thing');
    await tester.tapAt(tester.getCenter(find.byType(HomeHeader)) + const Offset(300, -120));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ItemDetailScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('pause stops it moving on; the header can be turned off', (tester) async {
    final c = await pumpApp(tester);
    await tester.tap(find.byTooltip('Pause'));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('1 / 2'), findsOneWidget, reason: 'paused');

    await c.read(homeHeaderSettingsProvider.notifier).save(const HomeHeaderSettings(style: HeaderStyle.off));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HomeHeader), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  test('header settings are kept', () async {
    var c = ProviderContainer();
    await c.read(homeHeaderSettingsProvider.future);
    await c.read(homeHeaderSettingsProvider.notifier).save(
          const HomeHeaderSettings(featured: HeaderFeatured.random, muted: false, volume: 30, trailersOnMobileData: true),
        );
    c.dispose();
    c = ProviderContainer();
    addTearDown(c.dispose);
    final s = await c.read(homeHeaderSettingsProvider.future);
    expect((s.featured, s.muted, s.volume, s.trailersOnMobileData), (HeaderFeatured.random, false, 30.0, true));
    expect(s.enabled, isTrue, reason: 'on by default');
  });

  test('older settings carry over: header off is Off, trailers off is Banners', () async {
    for (final (prefs, style) in [
      ({'homeHeader.enabled': false}, HeaderStyle.off),
      ({'homeHeader.enabled': true, 'homeHeader.trailers': false}, HeaderStyle.banners),
      (<String, Object>{}, HeaderStyle.trailers),
    ]) {
      SharedPreferences.setMockInitialValues(prefs);
      final c = ProviderContainer();
      expect((await c.read(homeHeaderSettingsProvider.future)).style, style, reason: '$prefs');
      c.dispose();
    }
  });

  testWidgets('Settings: each header style shows only its own options', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: HomeHeaderSection(isTv: false)))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Trailers start muted'), findsOneWidget);
    expect(find.text('Slow pan'), findsNothing);
    await tester.tap(find.text('Banners'));
    await tester.pumpAndSettle();
    expect(find.text('Slow pan'), findsOneWidget);
    expect(find.text('Trailers start muted'), findsNothing);
    final banners = await c.read(homeHeaderSettingsProvider.future);
    expect((banners.trailers, banners.pan), (false, true));
    await c.read(homeHeaderSettingsProvider.notifier).save(banners.copyWith(bannerPan: false));
    expect(c.read(homeHeaderSettingsProvider).value!.pan, isFalse, reason: 'still banners');
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(c.read(homeHeaderSettingsProvider).value!.enabled, isFalse);
  });
}
