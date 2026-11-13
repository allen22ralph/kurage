import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/core/seerr/seerr_api.dart';
import 'package:jellyfin_client/features/home/home_components.dart';
import 'package:jellyfin_client/theme/components.dart';
import 'package:jellyfin_client/theme/theme_choice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

/// A theme that restyles some of Home: Continue watching as a test
/// "stage", the top bar as a test "pill" (TV: as a "tvpill"), Seerr rows as
/// a style no app has.
const _test = {
  'schema': 1,
  'id': 'test',
  'name': 'Test',
  'components': {
    'home.row.continueWatching': {'variant': 'stage', 'size': 3},
    'home.topBar': {'variant': 'pill'},
    'home.row.seerr': {'variant': 'from-the-future'},
  },
  'devices': {
    'tv': {
      'components': {'home.topBar': {'variant': 'tvpill'}},
    },
  },
};

void main() {
  setUp(() {
    // The test styles, as a theme's new components would register them.
    HomeComponents.libraryRows[Slots.continueWatching]!.register(
      'stage',
      (context, d, style) => Text('Stage: ${d.title} (size ${style.param('size', 0)})'),
    );
    HomeComponents.topBarActions.register(
      'pill',
      (context, d, style) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [Text('Pill of ${d.actions.length} tools'), for (final a in d.actions) Tooltip(message: a.tooltip, child: const SizedBox(width: 1))],
      ),
    );
  });

  tearDown(() {
    HomeComponents.libraryRows[Slots.continueWatching]!.unregister('stage');
    HomeComponents.topBarActions.unregister('pill');
  });

  ProviderContainer container({bool tv = false, String theme = 'test'}) {
    final c = ProviderContainer(overrides: [
      isTvProvider.overrideWithValue(tv),
      availableThemesProvider.overrideWithValue(const [
        {'id': 'classic', 'name': 'Classic'},
        _test,
      ]),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test("a theme's style for each slot, per device; Classic where it says nothing", () async {
    SharedPreferences.setMockInitialValues({'theme.id': 'test'});
    final c = container();
    await c.read(themeChoiceProvider.future);
    expect(c.read(componentStyleProvider(Slots.continueWatching)), const ComponentStyle('stage', {'size': 3}));
    expect(c.read(componentStyleProvider(Slots.homeTopBar)).variant, 'pill');
    expect(c.read(componentStyleProvider(Slots.nextUp)), ComponentStyle.classic);

    final tv = container(tv: true);
    await tv.read(themeChoiceProvider.future);
    expect(tv.read(componentStyleProvider(Slots.homeTopBar)).variant, 'tvpill');
    expect(tv.read(componentStyleProvider(Slots.continueWatching)).variant, 'stage', reason: 'shared value');
  });

  test('parameters: the right type, or the fallback', () {
    const s = ComponentStyle('deck', {'depth': 150, 'interval': '9', 'dim': 0.5});
    expect(s.param('depth', 0), 150);
    expect(s.param('depth', 0.0), 150.0, reason: 'a whole number where a decimal is wanted');
    expect(s.param('interval', 12), 12, reason: 'a string is not a number');
    expect(s.param('missing', true), isTrue);
  });

  testWidgets("Home draws the theme's styles; one this app doesn't have falls back to Classic", (tester) async {
    SharedPreferences.setMockInitialValues({'theme.id': 'test'});
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
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([itemJson('r1', 'Resumed Show', type: 'Series')])),
      '/Shows/NextUp': (200, pageJson([itemJson('n1', 'Next Show', type: 'Series')])),
      '/Items': (200, pageJson([])),
      '/api/v1/discover/trending': (200, {
        'results': [
          {'id': 7, 'mediaType': 'tv', 'name': 'Seerr Pick', 'firstAirDate': '2026-10-01'},
        ],
      }),
    });
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [
      ...fakeServerOverrides(server),
      availableThemesProvider.overrideWithValue(const [
        {'id': 'classic', 'name': 'Classic'},
        _test,
      ]),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();

    expect(find.text('Stage: Continue watching (size 3)'), findsOneWidget);
    expect(find.text('Next Show'), findsWidgets, reason: 'Next up: Classic (the theme says nothing)');
    expect(find.textContaining('Pill of'), findsOneWidget);
    expect(find.byTooltip('Refresh (F5)'), findsOneWidget, reason: 'the tools reach any style');
    expect(find.text('Seerr Pick'), findsWidgets, reason: 'unknown Seerr style: Classic');
  });

  testWidgets("Classic top bar on a phone: what doesn't fit folds into More", (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final server = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items': (200, pageJson([])),
    });
    Future<void> show(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();
    }

    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await show(const Size(400, 850));
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'no overflow');
    expect(find.byTooltip('Search'), findsOneWidget, reason: 'pinned');
    expect(find.byTooltip('Notifications'), findsOneWidget, reason: 'pinned');
    expect(find.byTooltip('Refresh (F5)'), findsNothing);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Search'), findsNothing, reason: 'pinned ones are not in the menu');
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsWidgets, reason: 'the menu opens what the button did');

    // A wide window: every tool, no menu.
    await tester.pageBack();
    await show(const Size(1600, 900));
    expect(find.byTooltip('Refresh (F5)'), findsOneWidget);
    expect(find.byTooltip('More'), findsNothing);
  });
}
