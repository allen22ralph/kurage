import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/glow_backdrop.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/app/user_avatar.dart';
import 'package:jellyfin_client/features/home/depth/side_deck.dart';
import 'package:jellyfin_client/features/home/depth/tab_nav.dart';
import 'package:jellyfin_client/theme/theme_choice.dart';
import 'package:jellyfin_client/theme/theme_spec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

void main() {
  late FakeServer server;

  List<RequestOptions> listings(String type) => [
    for (final r in server.requestsTo('/Items'))
      if (r.uri.queryParameters['includeItemTypes'] == type && !r.uri.queryParameters.containsKey('parentId')) r,
  ];

  Future<void> open(WidgetTester tester, Size size, {String theme = 'depth', bool tv = false}) async {
    SharedPreferences.setMockInitialValues({'theme.id': theme, 'appearance.animations': false});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    server = FakeServer({
      '/UserViews': (
        200,
        pageJson([
          itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {'CollectionType': 'tvshows'}),
        ]),
      ),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, [itemJson('s1', 'Frieren', type: 'Series')]),
      // (Only the tabs': Home's own row of genres would push the rows this looks at down the page.)
      '/Genres': (RequestOptions o) => (
        200,
        pageJson([if (o.uri.queryParameters['includeItemTypes'] != null) itemJson('g1', 'Fantasy', type: 'Genre')]),
      ),
      '/Items': (RequestOptions o) => switch (o.uri.queryParameters['includeItemTypes']) {
        'Movie' => (200, pageJson([itemJson('m1', 'Your Name', type: 'Movie')])),
        'Series' => (200, pageJson([itemJson('t1', 'Dandadan', type: 'Series')])),
        _ => (200, pageJson([])),
      },
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [...fakeServerOverrides(server), if (tv) isTvProvider.overrideWithValue(true)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a PC: the tabs in the true centre; each page lists all of its kind and stays as it was left', (
    tester,
  ) async {
    await open(tester, const Size(1600, 1000));
    expect(tester.getCenter(find.byType(TabPill)).dx, 800, reason: 'truly centred');
    final tabHeight = tester.getSize(find.widgetWithText(InkWell, 'Movies')).height;
    expect(tester.getSize(find.byType(TabPill)).height, lessThanOrEqualTo(tabHeight + 10), reason: 'hugs its tabs');
    expect(find.byType(HomeBottomNav), findsNothing);
    expect(find.text('Frieren').hitTestable(), findsOneWidget);
    expect(listings('Movie'), isEmpty, reason: 'not loaded until opened');

    await tester.tap(find.widgetWithText(InkWell, 'Movies'));
    await tester.pumpAndSettle();
    expect(find.text('Your Name').hitTestable(), findsOneWidget);
    expect(find.text('Frieren').hitTestable(), findsNothing, reason: "Home's behind it");
    expect(listings('Movie'), hasLength(1));
    final genres = server.requestsTo('/Genres').where((r) => r.uri.queryParameters['includeItemTypes'] == 'Movie');
    expect(genres, isNotEmpty, reason: "only films' genres");
    expect(tester.takeException(), isNull);

    // A filter stays when coming back, without loading again.
    await tester.tap(find.text('Favorites').hitTestable());
    await tester.pumpAndSettle();
    final loaded = listings('Movie').length;
    await tester.tap(find.widgetWithText(InkWell, 'Shows'));
    await tester.pumpAndSettle();
    expect(find.text('Dandadan').hitTestable(), findsOneWidget);
    await tester.tap(find.widgetWithText(InkWell, 'Movies'));
    await tester.pumpAndSettle();
    expect(listings('Movie'), hasLength(loaded));
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Favorites').hitTestable()).selected, isTrue);

    await tester.tap(find.widgetWithText(InkWell, 'Home'));
    await tester.pumpAndSettle();
    expect(find.text('Frieren').hitTestable(), findsOneWidget);
    await close(tester);
  });

  testWidgets("a narrow window: opening the tools folds the tabs out of their way; a wide one needn't", (tester) async {
    await open(tester, const Size(1000, 800));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byTooltip('sam (signed in) · Accounts')));
    await tester.pumpAndSettle();

    expect(find.text('···').hitTestable(), findsOneWidget);
    expect(find.widgetWithText(InkWell, 'Movies').hitTestable(), findsNothing);
    final furthest = tester.getRect(find.byTooltip('Refresh (F5)'));
    expect(tester.getRect(find.widgetWithText(InkWell, 'Home')).right, lessThanOrEqualTo(furthest.left));
    expect(tester.takeException(), isNull);

    // Off the avatar: back in the centre, all three.
    await mouse.moveTo(const Offset(500, 500));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InkWell, 'Movies').hitTestable(), findsOneWidget);
    expect(tester.getCenter(find.byType(TabPill)).dx, 500);
    await mouse.removePointer();
    await close(tester);
  });

  testWidgets('a phone: the tabs along the bottom, and Back returns to Home before leaving', (tester) async {
    await open(tester, const Size(390, 844));
    expect(find.byType(HomeBottomNav), findsOneWidget);
    expect(find.byType(TabPill), findsNothing, reason: 'not in the bar');
    expect(tester.getBottomLeft(find.byType(HomeBottomNav)).dy, 844);

    await tester.tap(find.text('Shows'));
    await tester.pumpAndSettle();
    expect(find.text('Dandadan').hitTestable(), findsOneWidget);
    // (The page's heading and the tab's label.)
    expect(find.text('Shows'), findsNWidgets(2));
    expect(tester.getBottomLeft(find.text('Dandadan')).dy, lessThan(tester.getTopLeft(find.byType(HomeBottomNav)).dy));
    expect(tester.takeException(), isNull);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Dandadan').hitTestable(), findsNothing, reason: 'Home');
    expect(find.byType(HomeBottomNav), findsOneWidget);
    await close(tester);
  });

  testWidgets('a phone with large text: the bottom bar still fits', (tester) async {
    await open(tester, const Size(320, 640));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a TV: the remote reaches the tabs, and the open tools leave them room', (tester) async {
    await open(tester, const Size(960, 540), tv: true);
    expect(find.byType(TabPill), findsOneWidget);
    expect(find.byType(HomeBottomNav), findsNothing);
    final movies = Focus.of(tester.element(find.text('Movies')));
    movies.requestFocus();
    await tester.pumpAndSettle();
    expect(movies.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    // (Its card is built; the first row sits low on a 540-high TV layout.)
    expect(find.text('Your Name'), findsOneWidget);
    expect(find.text('Frieren').hitTestable(), findsNothing);
    expect(movies.hasFocus, isTrue, reason: 'the page leaves the focus on its tab');
    expect(tester.takeException(), isNull);

    // Focus on the avatar opens the tools; they don't reach the active tab.
    final avatar = Focus.of(tester.element(find.byType(CurrentUserAvatar).last));
    avatar.requestFocus();
    await tester.pumpAndSettle();
    expect(find.text('···').hitTestable(), findsOneWidget);
    final furthest = tester.getRect(find.byTooltip('Refresh (F5)'));
    expect(tester.getRect(find.widgetWithText(InkWell, 'Movies')).right, lessThanOrEqualTo(furthest.left));
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  Future<void> openHeader(WidgetTester tester, Size size, ThemeDevice device, {double statusBar = 0}) async {
    SharedPreferences.setMockInitialValues({'theme.id': 'depth', 'appearance.animations': false});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    Map<String, Object?> show(int i) => itemJson(
      's$i',
      'Show $i',
      type: 'Series',
      extra: {
        'BackdropImageTags': ['b$i'],
        'Overview': 'O',
        'Genres': ['Anime'],
      },
    );
    server = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items': (200, pageJson([for (var i = 0; i < 5; i++) show(i)])),
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    if (statusBar > 0) {
      tester.view.padding = FakeViewPadding(top: statusBar);
      tester.view.viewPadding = FakeViewPadding(top: statusBar);
    }
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [
        ...fakeServerOverrides(server, header: true),
        imagePixelsProvider.overrideWithValue((url) async => null),
        themeDeviceProvider.overrideWithValue(device),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  // (The bar's height was counted twice: inside Home's page, "padding"
  // already includes it.)
  testWidgets('a PC: the header starts just under the bar', (tester) async {
    await openHeader(tester, const Size(1600, 1000), ThemeDevice.desktop);
    expect(tester.getTopLeft(find.text('FEATURED TONIGHT')).dy, lessThan(200));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a phone: the header starts just under the bar', (tester) async {
    await openHeader(tester, const Size(390, 844), ThemeDevice.phone);
    // The chip at the top of its front card, which starts 76 from the top
    // (it was 140 with the bar counted twice).
    final texts = find.descendant(of: find.byType(SideDeck), matching: find.byType(Text));
    final bottoms = [for (final e in texts.evaluate()) tester.getBottomLeft(find.byWidget(e.widget).first).dy];
    expect(bottoms.reduce(math.min), lessThan(140));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  // (Scaffold takes the status bar out of "viewPadding" inside Home's page too,
  // which slid the front card up under the bar on a real phone.)
  testWidgets('a phone with a status bar: the front card clears the bar', (tester) async {
    await openHeader(tester, const Size(360, 800), ThemeDevice.phone, statusBar: 41);
    final barBottom = tester.getBottomLeft(find.byType(UserAvatar).first).dy;
    final texts = find.descendant(of: find.byType(SideDeck), matching: find.byType(Text));
    final tops = [for (final e in texts.evaluate()) tester.getTopLeft(find.byWidget(e.widget).first).dy];
    expect(tops.reduce(math.min), greaterThan(barBottom + 12));
    // And no blank band: the card still starts close under it.
    expect(tops.reduce(math.min), lessThan(barBottom + 60));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Classic has the tabs too, in its bar', (tester) async {
    await open(tester, const Size(1600, 1000), theme: 'classic');
    expect(find.byType(ClassicTabBar), findsOneWidget);
    expect(find.byType(TabPill), findsNothing);
    expect(find.byType(HomeBottomNav), findsNothing);
    expect(find.descendant(of: find.byType(ClassicTabBar), matching: find.text('Movies')), findsOneWidget);
    expect(find.text('Frieren'), findsOneWidget);
    await close(tester);
  });
}
