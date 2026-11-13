import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/features/home/depth/library_doors.dart';
import 'package:jellyfin_client/features/library/library_screen.dart';
import 'package:jellyfin_client/features/library/widgets/item_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

Map<String, dynamic> _library(String id, String name, String type, {bool artwork = false}) => itemJson(
  id,
  name,
  type: 'CollectionFolder',
  extra: {'CollectionType': type, if (!artwork) 'ImageTags': <String, String>{}},
);

void main() {
  Future<void> open(
    WidgetTester tester,
    Size size, {
    String theme = 'depth',
    bool tv = false,
    List<Map<String, dynamic>>? libraries,
  }) async {
    SharedPreferences.setMockInitialValues({'theme.id': theme, 'appearance.animations': false});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final server = FakeServer({
      '/UserViews': (
        200,
        pageJson(libraries ?? [_library('lib1', 'Movies', 'movies'), _library('lib2', 'Anime', 'tvshows')]),
      ),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, []),
      '/Genres': (200, pageJson([])),
      '/Items': (200, pageJson([])),
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [...fakeServerOverrides(server), isTvProvider.overrideWithValue(tv)]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
  }

  /// Scrolls Home to the doors.
  Future<void> toDoors(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.byType(LibraryDoors), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  /// Within the doors: "Movies" is also a tab.
  Finder inDoors(Finder f) => find.descendant(of: find.byType(LibraryDoors), matching: f);

  /// The door a library's name is on, as its outermost clip.
  Finder doorOf(String name) => find
      .ancestor(
        of: inDoors(find.text(name)),
        matching: find.descendant(of: find.byType(LibraryDoors), matching: find.byType(ClipRRect)),
      )
      .last;

  double leafRight(WidgetTester tester, Finder door) {
    final transform = tester.widget<Transform>(find.descendant(of: door, matching: find.byType(Transform)).first);
    final size = tester.getSize(door);
    return MatrixUtils.transformPoint(transform.transform, Offset(size.width, size.height / 2)).dx;
  }

  testWidgets('on a PC: a door per library, side by side, under its heading', (tester) async {
    await open(tester, const Size(1400, 900));
    await toDoors(tester);
    expect(find.text('STEP INSIDE'), findsOneWidget);
    expect(inDoors(find.text('Movies')), findsOneWidget);
    expect(inDoors(find.text('Anime')), findsOneWidget);
    expect(inDoors(find.text('Open the library →')), findsNWidgets(2));
    expect(inDoors(find.byIcon(Icons.local_movies_outlined)), findsOneWidget);
    expect(inDoors(find.byIcon(Icons.live_tv_outlined)), findsOneWidget);
    final movies = tester.getRect(doorOf('Movies'));
    final anime = tester.getRect(doorOf('Anime'));
    expect(movies.height, 320);
    expect(movies.top, anime.top, reason: 'side by side');
    expect(movies.width, anime.width);
  });

  testWidgets('hovering swings the panel open, leaving room for the label, and shut again', (tester) async {
    await open(tester, const Size(1400, 900));
    await toDoors(tester);
    final door = doorOf('Movies');
    final width = tester.getSize(door).width;
    expect(leafRight(tester, door), moreOrLessEquals(width), reason: 'shut');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(door));
    await tester.pumpAndSettle();
    // The label's real width at 22px, plus the padding (the test font is wider).
    expect(width - leafRight(tester, door), greaterThan(238));
    Transform leaf() => tester.widget<Transform>(find.descendant(of: door, matching: find.byType(Transform)).first);
    expect(leaf().filterQuality, FilterQuality.medium, reason: 'open: drawn whole, then tilted, for a clean edge');

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(leafRight(tester, door), moreOrLessEquals(width), reason: 'shut again');
    expect(leaf().filterQuality, isNull, reason: 'shut: as sharp as it gets');
  });

  testWidgets('a door opens its library', (tester) async {
    await open(tester, const Size(1400, 900));
    await toDoors(tester);
    await tester.tap(doorOf('Anime'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
  });

  testWidgets("a library's picture is on its door; without one, the glyph", (tester) async {
    await open(
      tester,
      const Size(1400, 900),
      libraries: [_library('lib1', 'Movies', 'movies', artwork: true), _library('lib2', 'Anime', 'tvshows')],
    );
    await toDoors(tester);
    expect(find.descendant(of: doorOf('Movies'), matching: find.byType(ItemImage)), findsOneWidget);
    expect(inDoors(find.byIcon(Icons.local_movies_outlined)), findsNothing);
    expect(find.descendant(of: doorOf('Anime'), matching: find.byType(ItemImage)), findsNothing);
    expect(inDoors(find.byIcon(Icons.live_tv_outlined)), findsOneWidget);
    // The tint reaches past the picture on every side, for the clip to cut.
    final tint = tester.getRect(find.byKey(const ValueKey('door-tint')));
    final picture = tester.getRect(find.descendant(of: doorOf('Movies'), matching: find.byType(ItemImage)));
    expect(tint.top, lessThan(picture.top));
    expect(tint.left, lessThan(picture.left));
    expect(tint.right, greaterThan(picture.right));
    expect(tint.bottom, greaterThan(picture.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('backdrops from the library take turns on its door', (tester) async {
    SharedPreferences.setMockInitialValues({'theme.id': 'depth'});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final server = FakeServer({
      '/UserViews': (200, pageJson([_library('lib1', 'Anime', 'tvshows', artwork: true)])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, []),
      '/Genres': (200, pageJson([])),
      '/Items': (RequestOptions o) => (
        200,
        pageJson([
          if (o.uri.queryParameters['parentId'] == 'lib1' && o.uri.queryParameters['imageTypes'] == 'Backdrop')
            for (final id in ['a', 'b', 'c'])
              itemJson(
                id,
                id,
                type: 'Series',
                extra: {
                  'BackdropImageTags': ['tag-$id'],
                },
              ),
        ]),
      ),
    });
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    await tester.scrollUntilVisible(find.byType(LibraryDoors), 300, scrollable: find.byType(Scrollable).first);
    await settle();

    /// The picture on top: never the library's own banner.
    String shown() {
      final images = tester.widgetList<ItemImage>(
        find.descendant(of: find.byType(AnimatedSwitcher), matching: find.byType(ItemImage)),
      );
      return images.last.image!.itemId;
    }

    final first = shown();
    expect(['a', 'b', 'c'], contains(first));
    await tester.pump(const Duration(seconds: 14));
    await tester.pump(const Duration(seconds: 2));
    final second = shown();
    expect(['a', 'b', 'c'], contains(second));
    expect(second, isNot(first));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  test('a door a whole row wide still clears its label', () {
    const size = Size(1235, 320);
    final right = MatrixUtils.transformPoint(doorLeafMatrix(size, 1, 1300), const Offset(1235, 160)).dx;
    expect(size.width - right, greaterThan(238));
  });

  testWidgets('an odd last door takes the whole row', (tester) async {
    await open(
      tester,
      const Size(1400, 900),
      libraries: [
        _library('lib1', 'Movies', 'movies'),
        _library('lib2', 'Shows', 'tvshows'),
        _library('lib3', 'Music', 'music'),
      ],
    );
    await toDoors(tester);
    final movies = tester.getRect(doorOf('Movies'));
    final music = tester.getRect(doorOf('Music'));
    expect(music.top, greaterThan(movies.top));
    expect(music.width, greaterThan(movies.width * 2));
  });

  testWidgets('narrower PC windows: a short label, then one column', (tester) async {
    await open(tester, const Size(1000, 900));
    await toDoors(tester);
    expect(tester.getSize(doorOf('Movies')).width, lessThan(540));
    expect(inDoors(find.text('Open →')), findsNWidgets(2));
    expect(tester.getTopLeft(doorOf('Anime')).dy, tester.getTopLeft(doorOf('Movies')).dy);

    await open(tester, const Size(650, 900));
    await toDoors(tester);
    await tester.scrollUntilVisible(inDoors(find.text('Anime')), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(doorOf('Anime')).dx, tester.getTopLeft(doorOf('Movies')).dx);
    expect(tester.getSize(doorOf('Anime')).width, greaterThan(540));
    expect(inDoors(find.text('Open the library →')), findsNWidgets(2));
  });

  testWidgets('on a phone: two small doors, the label clear when pressed, and long names fit', (tester) async {
    await open(
      tester,
      const Size(390, 844),
      libraries: [_library('lib1', 'Movies', 'movies'), _library('lib2', 'A very long library name indeed', 'tvshows')],
    );
    await toDoors(tester);
    final door = doorOf('Movies');
    expect(tester.getSize(door).height, 150);
    expect(tester.getTopLeft(door).dy, tester.getTopLeft(doorOf('A very long library name indeed')).dy);
    expect(inDoors(find.text('Open →')), findsNWidgets(2));
    expect(inDoors(find.byIcon(Icons.local_movies_outlined)), findsNothing);
    expect(tester.takeException(), isNull);

    final press = await tester.startGesture(tester.getCenter(door));
    await tester.pumpAndSettle();
    expect(tester.getSize(door).width - leafRight(tester, door), greaterThan(66), reason: "'Open →' and its padding");
    await press.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('on a TV: the remote walks to a door, focus opens it, select goes in', (tester) async {
    await open(tester, const Size(1920, 1080), tv: true);
    await toDoors(tester);
    final door = doorOf('Movies');
    expect(tester.getSize(door).height, 360);
    final width = tester.getSize(door).width;
    expect(leafRight(tester, door), moreOrLessEquals(width));
    for (var i = 0; i < 60 && leafRight(tester, door) > width * 0.8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    expect(leafRight(tester, door), lessThan(width * 0.8), reason: 'focus reached it, and opened it');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
  });

  testWidgets('Classic keeps its row of cards', (tester) async {
    await open(tester, const Size(1400, 900), theme: 'classic');
    expect(find.byType(LibraryDoors), findsNothing);
    expect(find.text('Open the library →'), findsNothing);
  });

  test('the panel turns on its left edge, away from the viewer', () {
    const size = Size(600, 320);
    final open = doorLeafMatrix(size, 1, 1300);
    expect(MatrixUtils.transformPoint(open, const Offset(0, 160)).dx, moreOrLessEquals(0));
    expect(MatrixUtils.transformPoint(open, const Offset(600, 160)).dx, lessThan(450));
    expect(MatrixUtils.transformPoint(doorLeafMatrix(size, 0, 1300), const Offset(600, 160)).dx, moreOrLessEquals(600));
  });
}
