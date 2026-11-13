import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/router.dart';
import 'package:jellyfin_client/app/glow_backdrop.dart';
import 'package:jellyfin_client/core/seerr/seerr_api.dart';
import 'package:jellyfin_client/features/home/depth/preview.dart';
import 'package:jellyfin_client/features/home/home_header_settings.dart';
import 'package:jellyfin_client/core/jellyfin/week_api.dart';
import 'package:jellyfin_client/features/home/this_week.dart';
import 'package:jellyfin_client/features/library/library_providers.dart';
import 'package:jellyfin_client/features/library/widgets/card_actions.dart';
import 'package:jellyfin_client/theme/components.dart';
import 'package:jellyfin_client/theme/theme_choice.dart';
import 'package:jellyfin_client/theme/theme_spec.dart';
import 'package:jellyfin_client/theme/themes/depth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

void main() {
  test('Depth reads as a theme: its palette, fonts and styles', () {
    final depth = ThemeSpec.fromJson(depthThemeJson, device: ThemeDevice.desktop);
    expect(depth.name, 'Depth');
    expect(depth.tokens.background, const Color(0xFF06070B));
    expect(depth.tokens.accent, const Color(0xFF8F84FF));
    expect(depth.tokens.accent2, const Color(0xFF8EE6F5));
    expect(depth.tokens.displayFont, const FontRef('Bricolage Grotesque'));
    expect(depth.tokens.glass.blur, 18);
    expect(depth.adjustable, isNot(contains(Adjustable.accent)), reason: 'its own palette');
    expect(depth.components[Slots.homeTopBar]?['variant'], 'pill');
    expect(ThemeSpec.fromJson(depthThemeJson, device: ThemeDevice.tv).tokens.radius.panel, 36);
  });

  test("an artwork's main colour: the colourful part, never black or white", () {
    // Mostly grey, some red: red wins.
    final pixels = [
      for (var i = 0; i < 90; i++) ...[128, 128, 128, 255],
      for (var i = 0; i < 10; i++) ...[220, 30, 30, 255],
    ];
    final c = HSLColor.fromColor(mainColor(pixels)!);
    expect(c.hue, anyOf(lessThan(20), greaterThan(340)));
    expect(c.lightness, inInclusiveRange(0.45, 0.60));
    expect(HSLColor.fromColor(mainColor([for (var i = 0; i < 50; i++) ...[0, 0, 0, 255]])!).lightness, closeTo(0.45, 0.01));
    expect(mainColor(const []), isNull);
  });

  group('Home in Depth', () {
    late ProviderContainer c;

    Future<void> open(WidgetTester tester, Size size) async {
      // Without animations: the glow breathes forever otherwise.
      SharedPreferences.setMockInitialValues({'theme.id': 'depth', 'appearance.animations': false});
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
      final server = FakeServer({
        '/UserViews': (200, pageJson([itemJson('lib1', 'Shows', type: 'CollectionFolder', extra: {'CollectionType': 'tvshows'})])),
        '/UserItems/Resume': (200, pageJson([])),
        '/Shows/NextUp': (200, pageJson([])),
        '/Items/Latest': (200, [itemJson('s1', 'Frieren', type: 'Series', extra: {'ProductionYear': 2023})]),
        '/Items': (200, pageJson([])),
        '/api/v1/discover/trending': (200, {
          'results': [
            {'id': 7, 'mediaType': 'tv', 'name': 'Dandadan', 'firstAirDate': '2024-10-03', 'mediaInfo': {'status': 5}},
          ],
        }),
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      c = ProviderContainer(overrides: [
        ...fakeServerOverrides(server),
        // No network images in tests: every artwork is one red.
        imagePixelsProvider.overrideWithValue((url) async => [for (var i = 0; i < 16; i++) ...[200, 40, 40, 255]]),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
      await tester.pumpAndSettle();
      expect(c.read(activeThemeProvider).id, 'depth');
    }

    testWidgets('on a PC: the pill bar, tools out of the avatar, tiles with kickers and status', (tester) async {
      await open(tester, const Size(1600, 1000));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('jellyfin'), findsWidgets, reason: 'the brand pill');
      expect(find.text('FROM SEERR'), findsWidgets);
      expect(find.text('JUST ADDED'), findsOneWidget);
      expect(find.text('Frieren'), findsOneWidget);
      expect(find.text('2024'), findsOneWidget, reason: 'tiles: the year, no description');
      expect(find.text('AVAILABLE'), findsOneWidget, reason: 'the status pill');

      // The tools: folded until the mouse comes over the avatar.
      final search = find.byTooltip('Search');
      expect(search.hitTestable(), findsNothing, reason: 'folded');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byTooltip('sam (signed in) · Accounts')));
      await tester.pumpAndSettle();
      expect(search.hitTestable(), findsOneWidget, reason: 'open');
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsWidgets, reason: 'Search opened');
    });

    late FakeServer server;

    Future<void> header(
      WidgetTester tester,
      Size size, {
      ThemeDevice device = ThemeDevice.desktop,
      bool starting = false,
    }) async {
      SharedPreferences.setMockInitialValues({'theme.id': 'depth', 'appearance.animations': false});
      FlutterSecureStorage.setMockInitialValues(signedInStorage());
      Map<String, Object?> show(int i) => itemJson('s$i', ['Re:ZERO', 'Frieren', 'Silent Witch'][i], type: 'Series', extra: {
            'BackdropImageTags': ['b$i'],
            'Overview': 'Overview $i',
            'ProductionYear': 2020 + i,
            'Genres': ['Anime', 'Fantasy'],
          });
      server = FakeServer({
        '/UserViews': (200, pageJson([])),
        '/UserItems/Resume': (200, pageJson([])),
        '/Shows/NextUp': (200, pageJson([])),
        // The server still starting: 503 until it's up.
        '/Items': starting ? (503, null) : (200, pageJson([show(0), show(1), show(2)])),
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: [
        ...fakeServerOverrides(server, header: true),
        imagePixelsProvider.overrideWithValue((url) async => null),
        themeDeviceProvider.overrideWithValue(device),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(tester.takeException(), isNull);
    }

    Future<void> close(WidgetTester tester) async {
      // The header's timer: stop it with the page.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets("a PC: the programme; the current show's details; another picked from the list", (tester) async {
      await header(tester, const Size(1600, 1000));
      expect(find.text('FEATURED TONIGHT'), findsOneWidget);
      expect(find.text('01 / 03'), findsOneWidget);
      for (final title in ['Re:ZERO', 'Frieren', 'Silent Witch']) {
        expect(find.text(title), findsOneWidget, reason: 'every show listed');
      }
      expect(find.text('Overview 0'), findsOneWidget, reason: 'only the current show opened up');
      expect(find.text('Overview 1'), findsNothing);
      expect(find.text('ANIME · FANTASY'), findsOneWidget, reason: 'genres down the frame');
      await tester.tap(find.text('Frieren'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Overview 1'), findsOneWidget);
      expect(find.text('02 / 03'), findsOneWidget);
      await close(tester);
    });

    testWidgets('a PC: the pointer holds the show only over the list and the video', (tester) async {
      await header(tester, const Size(1600, 1000));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      Future<void> wait() async {
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      // Over the list: it stays, past its time.
      await mouse.moveTo(tester.getCenter(find.text('Frieren')));
      await wait();
      expect(find.text('01 / 03'), findsOneWidget);

      // In the empty space under the list: the clock runs.
      await mouse.moveTo(tester.getBottomLeft(find.text('Silent Witch')) + const Offset(0, 80));
      await wait();
      expect(find.text('01 / 03'), findsNothing);
      await close(tester);
    });

    testWidgets("a phone: cards stacked to the side; the front one's details; a swipe to the next", (tester) async {
      await header(tester, const Size(400, 860), device: ThemeDevice.phone);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('FEATURED TONIGHT'), findsNothing);
      expect(find.textContaining('2020'), findsOneWidget, reason: "the front card's details, once settled");
      await tester.drag(find.textContaining('2020'), const Offset(-250, 0));
      // The new front card, then its details a moment after it settles.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('2021'), findsOneWidget, reason: 'swiped to the next');
      expect(find.textContaining('2020'), findsNothing);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('2021'), findsOneWidget, reason: 'scrolling keeps the details');
      await close(tester);
    });

    testWidgets('Continue watching on a PC: the stage for the picked one; another picked from the list', (tester) async {
      await header(tester, const Size(1600, 1400));
      Map<String, Object?> ep(String id, String show, int n, double pct) => itemJson(id, 'Episode $n', type: 'Episode', extra: {
            'SeriesName': show,
            'SeriesId': 'series-$id',
            'ParentIndexNumber': 1,
            'IndexNumber': n,
            'RunTimeTicks': 24 * 600000000,
            'UserData': {'Played': false, 'PlaybackPositionTicks': (24 * 600000000 * pct).round(), 'PlayedPercentage': pct * 100},
          });
      server.routes['/UserItems/Resume'] = (200, pageJson([ep('e1', 'Frieren', 1, 0.25), ep('e2', 'Fate/strange Fake', 3, 0.5)]));
      final c = ProviderScope.containerOf(tester.element(find.byType(JellyfinClientApp)));
      c.invalidate(resumeProvider);
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(tester.takeException(), isNull);
      expect(find.text('PICK UP WHERE YOU LEFT OFF'), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Start over'), findsOneWidget);
      expect(find.text('S1:E1 · Episode 1'), findsOneWidget, reason: 'the stage: the first, picked');
      expect(find.text('18m left'), findsWidgets);
      await tester.tap(find.text('Fate/strange Fake').first);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('S1:E3 · Episode 3'), findsOneWidget, reason: 'the stage follows the pick');
      expect(find.text('12m left'), findsWidgets);
      // The stage's picture: the episode's own page, not the show's.
      final resume = tester.getRect(find.text('Resume'));
      final at = Offset(resume.right + 500, resume.top - 20);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.read(routerProvider).routerDelegate.currentConfiguration.last.matchedLocation, '/item/e2');
      await close(tester);
    });

    testWidgets("a phone: Continue watching's stage fits a long title and large text", (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await header(tester, const Size(400, 1400), device: ThemeDevice.phone);
      server.routes['/UserItems/Resume'] = (
        200,
        pageJson([
          for (final (id, show) in [('e1', 'Frieren: Beyond Journey’s End'), ('e2', 'Re:Zero - Starting Life in Another World')])
            itemJson(id, 'The Journey’s End', type: 'Episode', extra: {
              'SeriesName': show,
              'IndexNumber': 1,
              'ParentIndexNumber': 1,
              'RunTimeTicks': 24 * 600000000,
              'UserData': {'Played': false, 'PlaybackPositionTicks': 3 * 600000000, 'PlayedPercentage': 12},
            }),
        ]),
      );
      final c = ProviderScope.containerOf(tester.element(find.byType(JellyfinClientApp)));
      c.invalidate(resumeProvider);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 400));
      }
      final resume = find.text('Resume');
      expect(resume, findsOneWidget);
      expect(find.byTooltip('Start over'), findsOneWidget, reason: 'a round button on a phone');
      // The title: inside the stage, not cut off at its top.
      final stage = tester.getRect(find.ancestor(of: resume, matching: find.byType(ClipRRect)).first);
      final title = tester.getRect(find.text('Frieren: Beyond Journey’s End').first);
      expect(title.top, greaterThanOrEqualTo(stage.top));
      expect(tester.getRect(find.byTooltip('Start over')).bottom, lessThanOrEqualTo(stage.bottom));
      // The picked row stays in line (it stepped out past the edge).
      for (final row in tester.widgetList<Material>(find.byType(Material))) {
        final r = tester.getRect(find.byWidget(row));
        if (r.top > stage.bottom) expect(r.right, lessThanOrEqualTo(stage.right + 0.5), reason: 'lined up with the stage, not off the edge');
      }
      await close(tester);
    });

    testWidgets('a phone: Next up is swiped; the case at the left edge opens, the row snapping to one', (tester) async {
      await header(tester, const Size(400, 1400), device: ThemeDevice.phone);
      server.routes['/Shows/NextUp'] = (
        200,
        pageJson([
          for (final (i, show) in ['Show A', 'Show B', 'Show C', 'Show D', 'Show E', 'Show F', 'Show G', 'Show H'].indexed)
            itemJson('n$i', 'Ep ${'ABCDEFGH'[i]}', type: 'Episode', extra: {
              'SeriesName': show,
              'IndexNumber': i + 1,
              'ParentIndexNumber': 1,
            }),
        ]),
      );
      final c = ProviderScope.containerOf(tester.element(find.byType(JellyfinClientApp)));
      c.invalidate(nextUpProvider);
      c.invalidate(visibleNextUpProvider);
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 150));
        }
      }

      await settle();
      expect(find.text('Ep A'), findsOneWidget, reason: 'the first open');
      await tester.ensureVisible(find.text('Ep A'));
      await settle();
      final scrollable = tester.state<ScrollableState>(
        find.ancestor(of: find.text('Ep A'), matching: find.byType(Scrollable)).first,
      );
      // (Found by a spine that stays one until the end.)
      final shelf = find.ancestor(of: find.text('Show D'), matching: find.byType(Scrollable)).first;
      ScrollPosition position() => scrollable.position;
      final shelfAt = tester.getCenter(shelf);

      // A swipe of a little over half a step (after the drag's first 18px,
      // which only start it; the shelf moves at 0.6 of the finger): the next
      // one opens, landing at the edge.
      await tester.drag(shelf, const Offset(-18 - 75, 0));
      await settle();
      expect(find.text('Ep B'), findsOneWidget);
      expect(find.text('Ep A'), findsNothing, reason: 'folded back to a spine');
      expect(position().pixels, 72, reason: 'snapped: one step (spine 62 + gap 10)');

      // Less than half: back where it was.
      await tester.drag(shelf, const Offset(-18 - 42, 0));
      await settle();
      expect(find.text('Ep B'), findsOneWidget);
      expect(position().pixels, 72);

      // A tap on a spine slides to it.
      await tester.tap(find.text('Show D'));
      await settle();
      expect(find.text('Ep D'), findsOneWidget);
      expect(position().pixels, 216);

      // However hard the flick: at most two cases on from where it's let go.
      await tester.flingFrom(shelfAt, const Offset(-60, 0), 8000);
      await settle();
      expect(position().pixels, 216 + 2 * 72.0);
      expect(find.text('Ep F'), findsOneWidget);

      // A short one still moves on, and back the same way.
      await tester.flingFrom(shelfAt, const Offset(60, 0), 1000);
      await settle();
      expect(position().pixels, anyOf(216.0, 288.0));
      await close(tester);
    });

    testWidgets("This week: the days on a line, today lit; a day's card, its +N listing the rest", (tester) async {
      await header(tester, const Size(1600, 2600));
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      Map<String, Object?> event(String id, String title, DateTime at) => {
            'id': id,
            'source': 'Sonarr',
            'type': 'Series',
            'title': title,
            'episodeTitle': 'Episode $id',
            'seasonNumber': 1,
            'episodeNumber': int.parse(id),
            'releaseDate': at.toUtc().toIso8601String(),
            'releaseType': 'Episode',
            'hasFile': false,
          };
      server.routes['/JellyfinEnhanced/arr/calendar'] = (
        200,
        {
          'events': [
            event('1', 'Kaiju No. 8', today.add(const Duration(hours: 21))),
            event('2', 'Dandadan', today.add(const Duration(hours: 22))),
          ],
          'errors': <Object>[],
        },
      );
      final c = ProviderScope.containerOf(tester.element(find.byType(JellyfinClientApp)));
      c.invalidate(thisWeekProvider);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.text('This week'), findsOneWidget);
      expect(find.text('ON AIR'), findsOneWidget, reason: 'the kicker');
      expect(find.text('TODAY'), findsOneWidget);
      expect(find.text('Kaiju No. 8'), findsOneWidget, reason: "today's first");
      expect(find.text('+1'), findsOneWidget, reason: 'and one more');
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('Kaiju No. 8'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kaiju No. 8'));
      await tester.pumpAndSettle();
      expect(find.text('Dandadan'), findsOneWidget, reason: "the day's list");
      expect(find.textContaining('S1:E2'), findsOneWidget);
      await close(tester);
    });

    testWidgets('This week on a phone: the days scroll sideways, today in view', (tester) async {
      await header(tester, const Size(400, 2600), device: ThemeDevice.phone);
      final now = DateTime.now();
      server.routes['/JellyfinEnhanced/arr/calendar'] = (
        200,
        {
          'events': [
            for (var d = 0; d < 7; d++)
              {
                'id': '$d',
                'source': 'Sonarr',
                'title': 'Show $d',
                'seasonNumber': 1,
                'episodeNumber': d + 1,
                'releaseDate': weekStart(now).add(Duration(days: d, hours: 20)).toUtc().toIso8601String(),
              },
          ],
        },
      );
      final c = ProviderScope.containerOf(tester.element(find.byType(JellyfinClientApp)));
      c.invalidate(thisWeekProvider);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.ensureVisible(find.text('This week'));
      await tester.pumpAndSettle();
      final todayCard = find.text('Show ${now.weekday - 1}');
      final rect = tester.getRect(todayCard);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(400), reason: "today's card on screen");
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    testWidgets("a phone: Continue watching's preview waits until it's on screen", (tester) async {
      await header(tester, const Size(400, 700), device: ThemeDevice.phone);
      server.routes['/UserItems/Resume'] = (
        200,
        pageJson([
          itemJson('e1', 'Episode 1', type: 'Episode', extra: {
            'SeriesName': 'Frieren',
            'RunTimeTicks': 24 * 600000000,
            'UserData': {'Played': false, 'PlaybackPositionTicks': 6 * 600000000, 'PlayedPercentage': 25},
          }),
        ]),
      );
      final c = ProviderScope.containerOf(tester.element(find.byType(JellyfinClientApp)));
      c.invalidate(resumeProvider);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.text('Resume', skipOffstage: false), findsOneWidget, reason: 'the stage is there, below the header');
      expect(Preview.playing.value, isNull, reason: "off screen: the header's trailer keeps playing");
      await close(tester);
    });

    testWidgets('the server still starting: the header comes once it answers', (tester) async {
      await header(tester, const Size(1600, 1000), starting: true);
      expect(find.text('FEATURED TONIGHT'), findsNothing);
      server.routes['/Items'] = (
        200,
        pageJson([
          itemJson('s0', 'Re:ZERO', type: 'Series', extra: {
            'BackdropImageTags': ['b0'],
            'Overview': 'Overview 0',
          }),
        ]),
      );
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('FEATURED TONIGHT'), findsOneWidget, reason: 'tried again by itself');
      await close(tester);
    });

    testWidgets('a phone: switching the header to banners and back keeps it', (tester) async {
      await header(tester, const Size(400, 860), device: ThemeDevice.phone);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('2020'), findsOneWidget);
      final c = ProviderScope.containerOf(tester.element(find.byType(JellyfinClientApp)));
      final settings = c.read(homeHeaderSettingsProvider.notifier);
      for (final style in [HeaderStyle.banners, HeaderStyle.trailers]) {
        await tester.runAsync(() => settings.save(c.read(homeHeaderSettingsProvider).value!.copyWith(style: style)));
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(tester.takeException(), isNull);
        expect(find.textContaining('202'), findsOneWidget, reason: 'the header after switching to ${style.name}');
      }
      await close(tester);
    });

    testWidgets('on a phone: a tap on the avatar opens the tools; nothing runs off the screen', (tester) async {
      await open(tester, const Size(400, 860));
      expect(tester.takeException(), isNull);
      final avatar = find.byTooltip('sam (signed in) · Accounts');
      await tester.tap(avatar);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'the open tools fit');
      final refresh = find.byTooltip('Refresh (F5)');
      expect(refresh.hitTestable(), findsOneWidget);
      expect(tester.getRect(refresh).left, greaterThanOrEqualTo(0), reason: 'the furthest tool is on screen');
      await tester.tap(avatar);
      await tester.pumpAndSettle();
      expect(refresh.hitTestable(), findsNothing, reason: 'a second tap closes them');
    });
  });
}
