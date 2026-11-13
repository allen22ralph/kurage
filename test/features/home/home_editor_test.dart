import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:dio/dio.dart';
import 'package:jellyfin_client/core/seerr/seerr_api.dart';
import 'package:jellyfin_client/core/seerr/seerr_discover.dart';
import 'package:jellyfin_client/features/home/home_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  late FakeServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = FakeServer({
      '/UserViews': (200, pageJson([itemJson('lib1', 'Anime', type: 'CollectionFolder', extra: {'CollectionType': 'tvshows'})])),
      '/UserItems/Resume': (200, pageJson([itemJson('r1', 'Resumed Show', type: 'Series')])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, [itemJson('n1', 'New Show', type: 'Series')]),
      '/Items': (200, pageJson([itemJson('f1', 'Filtered Show', type: 'Series', extra: {'UserData': {'UnplayedItemCount': 12}})])),
      '/Genres': (200, pageJson([itemJson('g1', 'Fantasy', type: 'Genre')])),
      '/api/v1/discover/tv': (200, {
        'results': [
          {'id': 7, 'mediaType': 'tv', 'name': 'Seerr Pick', 'firstAirDate': '2026-10-01'},
        ],
      }),
    });
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester, {bool seerr = false}) async {
    FlutterSecureStorage.setMockInitialValues({
      ...signedInStorage(),
      if (seerr)
        'seerr.account': jsonEncode({
          'baseUrl': 'https://seerr.home.arpa',
          'userId': 3,
          'displayName': 'sam',
          'permissions': SeerrPermission.request,
          'cookie': 'connect.sid=s%3Aabc',
        }),
    });
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('hiding a built-in row takes it off Home, and it stays hidden', (tester) async {
    final c = await pumpApp(tester);
    expect(find.text('Continue watching'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home rows'));
    await tester.pumpAndSettle();
    final tile = find.ancestor(of: find.text('Continue watching'), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: tile, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    // Saved for this account.
    final saved = (await SharedPreferences.getInstance()).getString('home.layout.srv1.u1');
    expect(saved, contains('"kind":"continueWatching"'));
    expect(c.read(homeLayoutProvider).value!.firstWhere((r) => r.id == 'continueWatching').visible, isFalse);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsNothing);
    expect(find.text('Next up'), findsNothing, reason: 'empty rows stay hidden as before');
    expect(find.text('Recently added in Anime'), findsOneWidget);
  });

  testWidgets('adding a Jellyfin row: live preview, then it shows on Home', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home rows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add row'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('From your Jellyfin libraries'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Row name'), 'Unwatched fantasy');
    await tester.tap(find.text('Everything'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unwatched').last);
    await tester.pumpAndSettle();
    expect(find.text('Filtered Show'), findsOneWidget, reason: 'live preview');
    final query = server.requestsTo('/Items').last.queryParameters;
    expect((query['filters'], query['includeItemTypes']), ('IsUnplayed', 'Series'));

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Unwatched fantasy'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Unwatched fantasy'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Filtered Show'), findsOneWidget);
  });

  testWidgets('a custom Seerr row on Home asks Seerr for its filters', (tester) async {
    SharedPreferences.setMockInitialValues({
      'home.layout.srv1.u1': jsonEncode([
        SeerrHomeRow(
          id: 'custom-1',
          title: 'Korean dramas',
          spec: const SeerrRowSpec(
            genres: [SeerrOption('18', 'Drama')],
            originalLanguages: [SeerrOption('ko', 'Korean')],
            ratingMin: 7,
          ),
        ).toJson(),
      ]),
    });
    await pumpApp(tester, seerr: true);
    await tester.scrollUntilVisible(find.text('Korean dramas'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Seerr Pick'), findsWidgets);
    // The built-in Seerr rows (restored into the saved layout) call discover
    // too; this row's request is the one with its filters.
    final q = server.requestsTo('/api/v1/discover/tv').map((r) => r.queryParameters).singleWhere((q) => q['language'] == 'ko');
    expect((q['genre'], q['voteAverageGte'], q['sortBy']), ('18', 7.0, 'popularity.desc'));
  });

  testWidgets('recommendation rows: because you watched, from the library, minus what the server has', (tester) async {
    // Library: Frieren is a favourite (TMDB 1); "Rec On Server" (TMDB 11) is already on the server.
    server.routes['/Items'] = (RequestOptions o) {
      final filters = o.queryParameters['filters'] as String? ?? '';
      return (
        200,
        pageJson([
          if (filters.contains('IsFavorite'))
            itemJson('fr', 'Frieren', type: 'Series', extra: {'ProviderIds': {'Tmdb': '1'}}),
          if (filters.isEmpty && o.queryParameters['includeItemTypes'] == 'Series,Movie') ...[
            itemJson('fr', 'Frieren', type: 'Series', extra: {'ProviderIds': {'Tmdb': '1'}}),
            itemJson('os', 'Rec On Server', type: 'Series', extra: {'ProviderIds': {'Tmdb': '11'}}),
          ],
        ]),
      );
    };
    server.routes['/api/v1/tv/1/recommendations'] = (200, {
      'results': [
        {'id': 10, 'mediaType': 'tv', 'name': 'Rec New', 'genreIds': [16, 10765], 'originalLanguage': 'ja'},
        {'id': 11, 'mediaType': 'tv', 'name': 'Rec On Server', 'genreIds': [16], 'originalLanguage': 'ja'},
        // The default filter set (Anime) leaves these out.
        {'id': 12, 'mediaType': 'tv', 'name': 'Live Action Drama', 'genreIds': [18], 'originalLanguage': 'ja'},
        {'id': 13, 'mediaType': 'tv', 'name': 'Western Cartoon', 'genreIds': [16], 'originalLanguage': 'en'},
      ],
    });
    SharedPreferences.setMockInitialValues({
      'home.layout.srv1.u1': jsonEncode([
        const SeerrHomeRow(id: 'r1', title: '', spec: SeerrRowSpec(source: SeerrSource.becauseYouWatched, hideAvailable: true)).toJson(),
        const SeerrHomeRow(id: 'r2', title: '', spec: SeerrRowSpec(source: SeerrSource.recommendedForYou, hideAvailable: true)).toJson(),
      ]),
    });
    await pumpApp(tester, seerr: true);

    expect(find.text('Because you watched Frieren'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Recommended for you'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Recommended for you'), findsOneWidget);
    expect(find.text('Rec New'), findsWidgets);
    expect(find.text('Rec On Server'), findsNothing, reason: 'on the server (TMDB id in the library)');
    expect(find.text('Live Action Drama'), findsNothing, reason: 'Anime filters: Animation');
    expect(find.text('Western Cartoon'), findsNothing, reason: 'Anime filters: Japanese');
    // One seed recommends it: the card says why.
    expect(find.text('Because you watched Frieren'), findsWidgets);
  });
}
