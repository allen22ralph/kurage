import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/core/seerr/seerr_api.dart';
import 'package:jellyfin_client/core/seerr/seerr_recommend.dart';
import 'package:jellyfin_client/features/home/more_for_you.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

SeerrDetails _details(int id, {required List<int> genres, List<int> keywords = const [], List<int> networks = const []}) =>
    SeerrDetails(
      media: SeerrMedia(tmdbId: id, type: SeerrMediaType.tv, title: 'T$id'),
      genres: [for (final g in genres) (id: g, name: g == 16 ? 'Animation' : 'Fantasy')],
      keywords: [for (final k in keywords) (id: k, name: 'isekai')],
      originalLanguage: 'ja',
      companies: [for (final n in networks) (id: n, name: 'Tokyo MX')],
    );

(int, Object) _page(RequestOptions o, List<int> ids) => (
      200,
      {
        'results': [
          if ('${o.queryParameters['page'] ?? 1}' == '1')
            for (final id in ids) {'id': id, 'mediaType': 'tv', 'name': 'Show $id'},
        ],
      },
    );

void main() {
  test('after the first ideas, more from further down the profile (the section keeps going)', () {
    final profile = buildTasteProfile([
      (3, _details(1, genres: [for (var g = 1; g <= 12; g++) g], keywords: [5, 6, 7], networks: [9])),
    ]);
    final first = moreRowIdeas(seeds: const [], profile: profile);
    final keys = [for (final i in first) i.key];
    expect(keys.where((k) => k.startsWith('best:')), isNotEmpty, reason: 'top-rated per genre');
    expect(keys.where((k) => k.startsWith('new:')), isNotEmpty, reason: 'new per genre');
    expect(keys.where((k) => k.startsWith('pair:')), isNotEmpty, reason: 'genre + keyword pairs');
    expect(keys.where((k) => k.startsWith('genre:')).length, 12, reason: 'beyond the top 8 genres');
    // The first set comes first, so rows already shown keep their order.
    final firstSetEnd = keys.lastIndexWhere((k) => k.startsWith('gem:'));
    expect(keys.indexWhere((k) => k.startsWith('best:')), greaterThan(firstSetEnd));
    expect(keys.toSet().length, keys.length, reason: 'no row twice');
  });

  test('row ideas take turns between kinds and skip "not interested"', () {
    final profile = buildTasteProfile([
      (3, _details(1, genres: [16, 14], keywords: [5], networks: [9])),
      (2, _details(2, genres: [16, 14], keywords: [5], networks: [9])),
      (1, _details(3, genres: [16], keywords: [5])),
    ]);
    const seeds = [
      TasteSeed(type: SeerrMediaType.tv, tmdbId: 1, name: 'Frieren', weight: 3),
      TasteSeed(type: SeerrMediaType.tv, tmdbId: 2, name: 'Mushoku Tensei', weight: 2),
    ];
    final ideas = moreRowIdeas(
      seeds: seeds,
      profile: profile,
      libraryGenres: const ['Fantasy'],
      languageNames: const {'ja': 'Japanese'},
      notInterested: const {'keyword:5'},
    );
    expect([for (final i in ideas.take(6)) i.title], [
      'Because you watched Mushoku Tensei', // the first seed is the user's own row
      'More animation series',
      'Hidden gems: animation',
      'From Tokyo MX',
      'Unwatched fantasy in your library',
      'Top-rated Japanese series',
    ]);
    expect(ideas.any((i) => i.key == 'keyword:5'), isFalse);
  });

  group('on Home', () {
    late FakeServer server;

    setUp(() {
      SharedPreferences.setMockInitialValues({
        'home.more.srv1.u1': jsonEncode(const MoreForYouSettings(enabled: true, fromLibrary: false).toJson()),
        // Only the section: no built-in rows to scroll past.
        'home.layout.srv1.u1': jsonEncode([
          for (final k in ['continueWatching', 'nextUp', 'libraries', 'seerrTrending', 'seerrPopularAnime', 'seerrSeasonalAnime', 'seerrUpcomingAnime'])
            {'type': 'builtin', 'kind': k, 'visible': false},
        ]),
      });
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
      server = FakeServer({
        '/UserViews': (200, pageJson([])),
        '/UserItems/Resume': (200, pageJson([])),
        '/Shows/NextUp': (200, pageJson([])),
        '/Items': (RequestOptions o) => (
              200,
              pageJson([
                if ((o.queryParameters['filters'] as String? ?? '').contains('IsFavorite')) ...[
                  itemJson('a', 'Frieren', type: 'Series', extra: {'ProviderIds': {'Tmdb': '1'}}),
                  itemJson('b', 'Mushoku Tensei', type: 'Series', extra: {'ProviderIds': {'Tmdb': '2'}}),
                ],
              ]),
            ),
        '/api/v1/tv/1': (200, {'id': 1, 'name': 'Frieren', 'genres': [{'id': 16, 'name': 'Animation'}], 'originalLanguage': 'ja'}),
        '/api/v1/tv/2': (200, {'id': 2, 'name': 'Mushoku Tensei', 'genres': [{'id': 16, 'name': 'Animation'}], 'originalLanguage': 'ja'}),
        '/api/v1/languages': (200, [{'iso_639_1': 'ja', 'english_name': 'Japanese'}]),
        // Mushoku's recommendations, then "More animation" (shares Show 20).
        // One page each (a later page is empty).
        '/api/v1/tv/2/recommendations': (RequestOptions o) => _page(o, [20, for (var i = 21; i < 30; i++) i]),
        '/api/v1/discover/tv': (RequestOptions o) => _page(o, [20, for (var i = 30; i < 40; i++) i]),
      });
    });

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: fakeServerOverrides(server));
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
      await tester.pumpAndSettle();
    }

    testWidgets('rows from the taste profile; a title shown above isn\'t repeated', (tester) async {
      await pumpApp(tester);
      expect(find.text('More for you'), findsOneWidget);
      expect(find.text('Because you watched Mushoku Tensei'), findsOneWidget);
      expect(find.text('More animation series'), findsOneWidget);
      expect(find.text('Show 20'), findsOneWidget, reason: 'only in the first row that has it');
      expect(find.text('Show 30'), findsWidgets);
    });

    testWidgets('scrolling back up finds the same rows (no reload, no jumps)', (tester) async {
      // Many rows (a genre each, with its own titles), so the first is far
      // off screen at the bottom.
      const genres = [16, 18, 35, 80, 9648, 10759, 10765, 10768];
      for (final id in [1, 2]) {
        server.routes['/api/v1/tv/$id'] = (200, {
          'id': id,
          'name': id == 1 ? 'Frieren' : 'Mushoku Tensei',
          'genres': [for (final g in genres) {'id': g, 'name': 'Genre $g'}],
          'originalLanguage': 'ja',
        });
      }
      server.routes['/api/v1/discover/tv'] = (RequestOptions o) {
        final g = int.tryParse('${o.queryParameters['genre']}') ?? 1;
        return _page(o, [for (var i = 0; i < 10; i++) g * 100 + i]);
      };
      await pumpApp(tester);
      tester.view.physicalSize = const Size(1600, 700);
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
      final first = find.text('Because you watched Mushoku Tensei');
      expect(first, findsOneWidget);

      for (var i = 0; i < 6; i++) {
        await tester.drag(list, const Offset(0, -1500));
        await tester.pumpAndSettle();
      }
      expect(first, findsNothing, reason: 'scrolled far away');
      final loaded = server.requests.length;
      // Back to the top, without pulling to refresh there.
      final position = tester.state<ScrollableState>(list).position;
      while (position.pixels > 0) {
        position.jumpTo((position.pixels - 500).clamp(0, double.infinity));
        await tester.pumpAndSettle();
      }
      expect(first.hitTestable(), findsOneWidget);
      expect(find.text('Show 21'), findsOneWidget, reason: 'the same titles');
      expect(server.requests.length, loaded, reason: 'rows kept, not loaded again');
    });

    testWidgets('Seerr down for a moment: a note on Home, then the rows come back by themselves', (tester) async {
      final working = server.routes['/api/v1/discover/tv']!;
      // Seerr up, but it can't reach TMDB (its VPN reconnecting): 500s.
      server.routes['/api/v1/discover/tv'] = (500, {'message': 'getaddrinfo EAI_AGAIN api.themoviedb.org'});
      await pumpApp(tester);
      expect(find.text('More animation series'), findsNothing);
      expect(find.textContaining("Seerr isn't reachable"), findsOneWidget);

      server.routes['/api/v1/discover/tv'] = working;
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('More animation series'), findsOneWidget);
      expect(find.textContaining("Seerr isn't reachable"), findsNothing);
    });

    testWidgets('Seerr down when Home opens: "Waiting for Seerr…", then all the rows, not a few', (tester) async {
      final tv1 = server.routes['/api/v1/tv/1']!;
      final tv2 = server.routes['/api/v1/tv/2']!;
      // No taste profile while Seerr is down.
      server.routes['/api/v1/tv/1'] = (500, {'message': 'getaddrinfo EAI_AGAIN'});
      server.routes['/api/v1/tv/2'] = (500, {'message': 'getaddrinfo EAI_AGAIN'});
      await pumpApp(tester);
      expect(find.text('Waiting for Seerr…'), findsOneWidget);
      expect(find.text('More animation series'), findsNothing);

      server.routes['/api/v1/tv/1'] = tv1;
      server.routes['/api/v1/tv/2'] = tv2;
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for Seerr…'), findsNothing);
      // The profile's rows, not just the few that need no profile.
      expect(find.text('More animation series'), findsOneWidget);
      expect(find.text('Because you watched Mushoku Tensei'), findsOneWidget);
    });

    testWidgets('a row with only a few titles is left out', (tester) async {
      server.routes['/api/v1/tv/2/recommendations'] = (200, {
        'results': [for (final id in [21, 22]) {'id': id, 'mediaType': 'tv', 'name': 'Show $id'}],
      });
      await pumpApp(tester);
      expect(find.text('Because you watched Mushoku Tensei'), findsNothing);
      expect(find.text('More animation series'), findsOneWidget);
    });

    testWidgets('"Not interested" takes the row away', (tester) async {
      await pumpApp(tester);
      final row = find.ancestor(of: find.text('More animation series'), matching: find.byType(Row)).first;
      await tester.tap(find.descendant(of: row, matching: find.byTooltip('Not interested')));
      await tester.pumpAndSettle();
      expect(find.text('More animation series'), findsNothing);
      final saved = (await SharedPreferences.getInstance()).getString('home.more.srv1.u1')!;
      expect(saved, contains('genre:16'));
    });
  });
}
