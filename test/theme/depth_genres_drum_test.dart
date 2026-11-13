import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/features/home/depth/drum_section.dart';
import 'package:jellyfin_client/features/home/depth/genre_tiles.dart';
import 'package:jellyfin_client/features/library/library_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

const _genres = [
  'Action',
  'Adventure',
  'Anime',
  'Comedy',
  'Drama',
  'Fantasy',
  'Horror',
  'Isekai',
  'Mystery',
  'Romance',
  'Sci-Fi',
  'Slice of Life',
];

void main() {
  late FakeServer server;

  Future<void> open(WidgetTester tester, Size size, {String theme = 'depth', bool tv = false}) async {
    SharedPreferences.setMockInitialValues({'theme.id': theme, 'appearance.animations': false});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    server = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, []),
      '/Genres': (200, pageJson([for (final g in _genres) itemJson(g, g, type: 'Genre')])),
      '/Items': (RequestOptions o) => (
        200,
        pageJson([if (o.uri.queryParameters['genres'] == 'Sci-Fi') itemJson('m1', 'Your Name', type: 'Movie')]),
      ),
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [...fakeServerOverrides(server), isTvProvider.overrideWithValue(tv)]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
  }

  Future<void> toTiles(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.byType(GenreTiles), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  Finder inTiles(Finder f) => find.descendant(of: find.byType(GenreTiles), matching: f);
  Finder words() => inTiles(find.byWidgetPredicate((w) => w is Text && _genres.contains(w.data)));

  group('Browse by genre', () {
    testWidgets('on a PC: as many tiles as fit two full rows, under its heading', (tester) async {
      await open(tester, const Size(1400, 900));
      await toTiles(tester);
      expect(find.text('FIND A MOOD'), findsOneWidget);
      expect(find.text('Browse by genre'), findsOneWidget);
      // (1400 - 2 x 32) wide: five at 210 or more.
      expect(words(), findsNWidgets(10));
      expect(tester.getSize(words().first).height, lessThanOrEqualTo(130));
      expect(tester.takeException(), isNull);
    });

    testWidgets('on a phone: two columns of 96; on a TV: four of 170', (tester) async {
      await open(tester, const Size(390, 844));
      await toTiles(tester);
      expect(words(), findsNWidgets(6));
      final tile = find.ancestor(of: words().first, matching: find.byType(SizedBox)).first;
      expect(tester.getSize(find.ancestor(of: tile, matching: find.byType(Semantics)).first).height, 96);

      await open(tester, const Size(1920, 1080), tv: true);
      await toTiles(tester);
      expect(words(), findsNWidgets(8));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('hovering flips a tile to its coloured back, and back again', (tester) async {
      await open(tester, const Size(1400, 900));
      await toTiles(tester);
      final word = words().first;
      final genre = tester.widget<Text>(word).data!;
      final centre = tester.getCenter(word);
      expect(find.text('Browse $genre →'), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(centre);
      await tester.pumpAndSettle();
      expect(find.text('Browse $genre →'), findsOneWidget);

      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(find.text('Browse $genre →'), findsNothing);
    });

    testWidgets("a tile opens that genre's films and shows, across libraries", (tester) async {
      await open(tester, const Size(1400, 900));
      await toTiles(tester);
      // Any tile: the one drawn first.
      final genre = tester.widget<Text>(words().first).data!;
      await tester.tap(words().first);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(find.text(genre), findsOneWidget, reason: 'its title');
      final asked = server.requestsTo('/Items').last.uri.queryParameters;
      expect(asked['genres'], genre);
      expect(asked['includeItemTypes'], 'Movie,Series');
      expect(asked['filters'], isNull, reason: 'not only the favorites');
    });

    test('a different selection by the day, always from the list, the same all day', () {
      final monday = genresOfTheDay(_genres, 6, DateTime(2026, 11, 2));
      expect(monday, hasLength(6));
      expect(monday.toSet(), hasLength(6));
      expect(_genres, containsAll(monday));
      expect(genresOfTheDay(_genres, 6, DateTime(2026, 11, 2, 23)), monday);
      expect(genresOfTheDay(_genres, 6, DateTime(2026, 11, 3)), isNot(monday));
      expect(genresOfTheDay(const ['Anime'], 6, DateTime(2026, 11, 3)), ['Anime']);
    });

    testWidgets('Classic: a row of chips, opening the same page', (tester) async {
      await open(tester, const Size(1400, 900), theme: 'classic');
      expect(find.byType(GenreTiles), findsNothing);
      await tester.scrollUntilVisible(find.byType(ActionChip).first, 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, 'Action'));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
    });
  });

  group('the drum', () {
    final spec = DrumSpec.of(FormFactor.desktop);

    test('as the design: rolls in, flat while read, tilts away', () {
      final start = spec.frameAt(0);
      expect((start.tilt, start.dy, start.scale, start.opacity), (38.0, 90.0, 0.92, 0.0));
      final halfIn = spec.frameAt(0.12);
      expect(halfIn.tilt, moreOrLessEquals(19));
      expect(halfIn.opacity, moreOrLessEquals(0.5));
      for (final p in [0.24, 0.5, 0.76]) {
        final flat = spec.frameAt(p);
        expect((flat.tilt, flat.dy, flat.scale, flat.opacity), (0.0, 0.0, 1.0, 1.0));
      }
      final end = spec.frameAt(1);
      expect(end.tilt, -16);
      expect(end.dy, -30);
      expect(end.opacity, moreOrLessEquals(0.35));
      expect(spec.frameAt(-1).opacity, 0, reason: 'below the screen');
      expect(spec.frameAt(2).opacity, moreOrLessEquals(0.35), reason: 'above it');
    });

    test('progress: by position on screen, however long the page is', () {
      expect(drumProgress(top: 900, height: 300, viewport: 900), 0);
      expect(drumProgress(top: -300, height: 300, viewport: 900), 1);
      expect(drumProgress(top: 300, height: 300, viewport: 900), 0.5);
      expect(drumProgress(top: 0, height: 0, viewport: 0), 0);
    });

    /// Sections in a list, on the drum.
    Future<ScrollController> list(WidgetTester tester, {bool animations = true}) async {
      SharedPreferences.setMockInitialValues({'appearance.animations': animations});
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: const Size(1000, 800), disableAnimations: !animations),
              child: ListView(
                controller: scroll,
                children: [
                  for (var i = 0; i < 6; i++)
                    DrumSection(
                      key: ValueKey(i),
                      child: SizedBox(height: 400, child: Text('section $i')),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return scroll;
    }

    RenderDrum drum(WidgetTester tester, int i) => tester.renderObject<RenderDrum>(
      find.descendant(
        of: find.byKey(ValueKey(i)),
        matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Drum'),
      ),
    );

    testWidgets('moves with the scroll, and taps land on the flat section', (tester) async {
      final scroll = await list(tester);
      // Section 1 starts at 400, halfway down an 800 screen: flat by then?
      final entering = drum(tester, 1);
      expect(entering.lastOpacity, 1);
      expect(entering.lastTilt, 0);

      // Its top at 700: only just coming in.
      scroll.jumpTo(0);
      await tester.pump();
      final second = drum(tester, 1);
      scroll.jumpTo(100);
      await tester.pump();
      expect(second.lastOpacity, 1);

      scroll.jumpTo(700);
      await tester.pump();
      // Section 1 (top at -300, 100 still on screen): tilting away.
      expect(drum(tester, 1).lastTilt, lessThan(0));
      expect(drum(tester, 1).lastOpacity, lessThan(1));
      // Section 2 (top at 100): flat.
      expect(drum(tester, 2).lastTilt, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a section just coming in is tilted and faint', (tester) async {
      final scroll = await list(tester);
      scroll.jumpTo(390);
      await tester.pump();
      // Section 2 is at 410: on the way in, not yet at 24%? (800 - 410) / 1200 is 32%: flat.
      expect(drum(tester, 2).lastTilt, 0);
      scroll.jumpTo(100);
      await tester.pump();
      // Section 2 at 700: (800 - 700) / 1200 is 8%.
      expect(drum(tester, 2).lastTilt, greaterThan(0));
      expect(drum(tester, 2).lastOpacity, lessThan(1));
    });

    testWidgets('without animations it stays out of the way', (tester) async {
      await list(tester, animations: false);
      expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Drum'), findsNothing);
      expect(find.text('section 0'), findsOneWidget);
    });

    testWidgets('Depth wraps Home in it; Classic does not', (tester) async {
      SharedPreferences.setMockInitialValues({'theme.id': 'depth', 'appearance.animations': false});
      await open(tester, const Size(1400, 900));
      expect(find.byType(DrumSection), findsWidgets);
      await open(tester, const Size(1400, 900), theme: 'classic');
      expect(find.byType(DrumSection), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
