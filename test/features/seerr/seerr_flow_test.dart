import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/core/seerr/seerr_api.dart';
import 'package:jellyfin_client/features/seerr/seerr_providers.dart';
import 'package:jellyfin_client/features/seerr/widgets/seerr_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

const _me = {'id': 3, 'displayName': 'sam', 'permissions': SeerrPermission.request};
const _admin = {'id': 1, 'displayName': 'admin', 'permissions': SeerrPermission.admin};

String _account(Map<String, Object> user) => jsonEncode({
      'baseUrl': 'https://seerr.home.arpa',
      'userId': user['id'],
      'displayName': user['displayName'],
      'permissions': user['permissions'],
      'cookie': 'connect.sid=s%3Aabc',
    });

Map<String, Object?> _tv(int id, String name, {int? status, String? jellyfinId}) => {
      'id': id,
      'mediaType': 'tv',
      'name': name,
      'firstAirDate': '2026-10-01',
      if (status != null) 'mediaInfo': {'status': status, 'jellyfinMediaId': ?jellyfinId},
    };

void main() {
  late FakeServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = FakeServer({
      // Jellyfin home, kept minimal.
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items': (200, pageJson([])),
      // Seerr.
      '/api/v1/status': (200, {'version': '3.5.1'}),
      'POST /api/v1/auth/jellyfin': (200, _me),
      '/api/v1/auth/me': (200, _me),
      '/api/v1/discover/trending': (200, {'results': [_tv(1, 'Trending Show')]}),
      '/api/v1/discover/tv': (200, {'results': [_tv(2, 'Dandadan', status: 5), _tv(3, 'New Anime')]}),
      '/api/v1/search': (
        200,
        {
          'results': [
            _tv(2, 'Dandadan', status: 5, jellyfinId: 'dandadan-1'),
            _tv(4, 'Saga of Tanya the Evil', status: 5, jellyfinId: 'tanya-1'),
            _tv(3, 'New Anime'),
          ],
        },
      ),
      '/api/v1/tv/3': (
        200,
        {
          'id': 3,
          'name': 'New Anime',
          'overview': 'Fresh this season.',
          'seasons': [
            {'seasonNumber': 1, 'name': 'Season 1', 'episodeCount': 12},
            {'seasonNumber': 2, 'name': 'Season 2', 'episodeCount': 12},
          ],
          'mediaInfo': {'status': 4, 'seasons': [{'seasonNumber': 1, 'status': 5}]},
        },
      ),
      'POST /api/v1/request': (201, {
        'id': 9, 'status': 1, 'type': 'tv', 'media': {'tmdbId': 3, 'status': 2}, 'requestedBy': _me,
        'createdAt': '2026-10-27T10:00:00Z',
      }),
      '/api/v1/request': (200, {'results': []}),
    });
    server.responseHeaders['/api/v1/auth/jellyfin'] = {
      'set-cookie': ['connect.sid=s%3Aabc; Path=/; HttpOnly'],
    };
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester, {Map<String, Object>? seerrUser}) async {
    FlutterSecureStorage.setMockInitialValues({
      ...signedInStorage(),
      if (seerrUser != null) 'seerr.account': _account(seerrUser),
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

  testWidgets('sign in from Settings with the suggested address', (tester) async {
    final c = await pumpApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Seerr'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in to Seerr'));
    await tester.pumpAndSettle();

    // jellyfin.home.arpa -> seerr.home.arpa answered /status.
    expect(find.text('https://seerr.home.arpa'), findsOneWidget);
    expect(find.text('sam'), findsWidgets, reason: 'Jellyfin username pre-filled');
    await tester.enterText(find.widgetWithText(TextField, 'Jellyfin password'), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    final account = c.read(seerrAccountProvider).value!;
    expect((account.user.displayName, account.cookie), ('sam', 'connect.sid=s%3Aabc'));
    expect(find.text('Signed in as sam'), findsOneWidget);
    final login = server.requestsTo('/api/v1/auth/jellyfin').single;
    expect(login.uri.host, 'seerr.home.arpa');
  });

  testWidgets("Seerr out of reach: Check connection says so on the row, and the sign-in is kept", (tester) async {
    await pumpApp(tester, seerrUser: _me);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Seerr'));
    await tester.pumpAndSettle();
    expect(find.textContaining("can't be reached right now"), findsNothing);

    server.routes['/api/v1/status'] = unreachable;
    await tester.tap(find.text('Check connection'));
    await tester.pumpAndSettle();
    expect(find.text('Signed in as sam'), findsOneWidget, reason: 'kept');
    expect(find.textContaining("can't be reached right now"), findsOneWidget);

    // Back home: it clears.
    server.routes['/api/v1/status'] = (200, {'version': '3.5.1'});
    await tester.tap(find.text('Check connection'));
    await tester.pumpAndSettle();
    expect(find.textContaining("can't be reached right now"), findsNothing);
  });

  testWidgets('sign in with a Seerr-only account (email)', (tester) async {
    server.routes['POST /api/v1/auth/local'] = (200, _me);
    server.responseHeaders['/api/v1/auth/local'] = {
      'set-cookie': ['connect.sid=s%3Alocal; Path=/; HttpOnly'],
    };
    final c = await pumpApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Seerr'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in to Seerr'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byWidgetPredicate((w) => w is SegmentedButton), matching: find.text('Seerr')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'me@example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Seerr password'), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(c.read(seerrAccountProvider).value!.cookie, 'connect.sid=s%3Alocal');
    expect(server.requestsTo('/api/v1/auth/local').single.data, {'email': 'me@example.com', 'password': 'pw'});
  });

  testWidgets("the owner's email sign-in: permissions from Seerr itself, not the sign-in's reply", (tester) async {
    // The reply leaves the permissions out (it saved 0: no Request buttons).
    server.routes['POST /api/v1/auth/local'] = (200, {'id': 1, 'displayName': 'sam'});
    server.responseHeaders['/api/v1/auth/local'] = {
      'set-cookie': ['connect.sid=s%3Alocal; Path=/; HttpOnly'],
    };
    server.routes['/api/v1/auth/me'] = (200, {'id': 1, 'displayName': 'sam', 'permissions': SeerrPermission.admin});
    final c = await pumpApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Seerr'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in to Seerr'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byWidgetPredicate((w) => w is SegmentedButton), matching: find.text('Seerr')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'me@example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Seerr password'), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    final user = c.read(seerrAccountProvider).value!.user;
    expect(user.permissions, SeerrPermission.admin);
    expect(user.canRequest(SeerrMediaType.tv), isTrue);
    expect(find.textContaining('Owner'), findsOneWidget, reason: 'Settings > Seerr shows the role');
    expect(server.requestsTo('/api/v1/auth/me').single.headers['Cookie'], 'connect.sid=s%3Alocal');
  });

  test("a saved account's permissions catch up with Seerr on start", () async {
    FlutterSecureStorage.setMockInitialValues({...signedInStorage(), 'seerr.account': _account({'id': 3, 'displayName': 'sam', 'permissions': 0})});
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    expect((await c.read(seerrAccountProvider.future))!.user.permissions, 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.read(seerrAccountProvider).value!.user.permissions, SeerrPermission.request, reason: '/auth/me says so');
  });

  testWidgets("titles in the library by TMDB id show 'On your server' even when Seerr doesn't know", (tester) async {
    // Seerr has no status for "New Anime" (TMDB 3), but the server has it
    // (e.g. TMDB has one long season where the server has several).
    server.routes['/Items'] = (RequestOptions o) => (
          200,
          pageJson([
            if (o.queryParameters['includeItemTypes'] == 'Series,Movie')
              itemJson('jf-new', 'New Anime', type: 'Series', extra: {
                'ProviderIds': {'Tmdb': '3'},
              }),
          ]),
        );
    server.routes['/Items/jf-new'] = (200, itemJson('jf-new', 'New Anime', type: 'Series'));
    server.routes['/Items/jf-new/Similar'] = (200, pageJson([]));
    server.routes['/Shows/jf-new/Seasons'] = (200, pageJson([]));
    await pumpApp(tester, seerrUser: _me);
    expect(find.text('On your server'), findsWidgets);

    await tester.tap(find.text('New Anime').first);
    await tester.pumpAndSettle();
    expect(server.requestsTo('/api/v1/tv/3'), isEmpty, reason: 'opens the library item, not Seerr');
    expect(server.requestsTo('/Items/jf-new'), isNotEmpty);
  });

  testWidgets('home shows discover rows; requesting the missing season', (tester) async {
    await pumpApp(tester, seerrUser: _me);
    expect(find.text('Trending'), findsOneWidget);
    expect(find.text('Popular anime'), findsOneWidget);
    expect(find.text('Available'), findsWidgets, reason: 'status badges');

    // Discover requests carry the anime keyword and the season's dates.
    final seasonal = server.requests.where((r) => r.path == '/discover/tv' && r.queryParameters.containsKey('firstAirDateGte'));
    expect(seasonal.first.queryParameters['keywords'], '210024');
    expect(seasonal.first.headers['Cookie'], 'connect.sid=s%3Aabc');

    await tester.tap(find.text('New Anime').first);
    await tester.pumpAndSettle();
    expect(find.text('Fresh this season.'), findsOneWidget);
    expect(find.text('Partly available'), findsOneWidget);

    await tester.tap(find.text('Request more'));
    await tester.pumpAndSettle();
    // Season 1 is on the server already; only season 2 is offered.
    final s1 = tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Season 1'));
    expect((s1.value, s1.onChanged), (true, null));
    await tester.tap(find.widgetWithText(FilledButton, 'Request'));
    await tester.pumpAndSettle();

    final sent = server.requestsTo('/api/v1/request').where((r) => r.method == 'POST').single.data as Map;
    expect(sent, {'mediaType': 'tv', 'mediaId': 3, 'seasons': [2], 'is4k': false});
    expect(find.text('Requested New Anime.'), findsOneWidget);
  });

  TestGesture? mouse;
  Future<void> hover(WidgetTester tester, String title) async {
    final card = find.ancestor(of: find.text(title).first, matching: find.byType(SeerrCard));
    final at = tester.getCenter(find.descendant(of: card, matching: find.byType(AspectRatio)));
    if (mouse == null) {
      mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse!.addPointer(location: at);
      addTearDown(() {
        mouse!.removePointer();
        mouse = null;
      });
    } else {
      await mouse!.moveTo(at);
    }
    await tester.pumpAndSettle();
  }

  testWidgets('Request on a card: a small window, without opening the page', (tester) async {
    await pumpApp(tester, seerrUser: _me);
    // Available titles have no Request button.
    await hover(tester, 'Dandadan');
    expect(find.widgetWithText(FilledButton, 'Request'), findsNothing);

    await hover(tester, 'New Anime');
    await tester.tap(find.widgetWithText(FilledButton, 'Request'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget, reason: 'centred by default');
    expect(find.text('Request New Anime'), findsOneWidget);
    expect(find.text('Fresh this season.'), findsNothing, reason: 'not the page');
    await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.widgetWithText(FilledButton, 'Request')));
    await tester.pumpAndSettle();
    final sent = server.requestsTo('/api/v1/request').where((r) => r.method == 'POST').single.data as Map;
    expect(sent['seasons'], [2]);
    expect(find.text('Requested New Anime.'), findsOneWidget);
  });

  testWidgets("anime: the form shows Sonarr's anime defaults (as Seerr will use), and sends none", (tester) async {
    const advanced = {'id': 3, 'displayName': 'sam', 'permissions': SeerrPermission.request | SeerrPermission.requestAdvanced};
    server.routes['/api/v1/auth/me'] = (200, advanced);
    final details = Map<String, Object?>.from((server.routes['/api/v1/tv/3']! as (int, Object?)).$2! as Map)
      ..['keywords'] = [
        {'id': 210024, 'name': 'anime'},
      ];
    server.routes['/api/v1/tv/3'] = (200, details);
    server.routes['/api/v1/service/sonarr'] = (200, [
      {'id': 0, 'name': 'sonarr', 'is4k': false, 'isDefault': true},
    ]);
    server.routes['/api/v1/service/sonarr/0'] = (200, {
      'server': {
        'id': 0, 'name': 'sonarr', 'is4k': false, 'isDefault': true, //
        'activeProfileId': 1, 'activeDirectory': '/media/tv',
        'activeAnimeProfileId': 2, 'activeAnimeDirectory': '/media/anime',
      },
      'profiles': [
        {'id': 1, 'name': 'TV 1080p'},
        {'id': 2, 'name': 'Anime 1080p'},
      ],
      'rootFolders': [
        {'path': '/media/tv', 'freeSpace': 900000000000},
        {'path': '/media/anime', 'freeSpace': 445520000000},
      ],
    });
    await pumpApp(tester, seerrUser: advanced);
    await hover(tester, 'New Anime');
    await tester.tap(find.widgetWithText(FilledButton, 'Request'));
    await tester.pumpAndSettle();
    expect(find.text('Anime 1080p (Default)'), findsOneWidget);
    expect(find.text('/media/anime (445.52 GB) (Default)'), findsOneWidget);
    expect(find.text('* This series is an anime.'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.widgetWithText(FilledButton, 'Request')));
    await tester.pumpAndSettle();
    final sent = server.requestsTo('/api/v1/request').where((r) => r.method == 'POST').single.data as Map;
    expect(sent.containsKey('rootFolder'), isFalse, reason: "left alone: Seerr's own anime routing applies");
    expect(sent.containsKey('profileId'), isFalse);
  });

  testWidgets('"From the card": the window opens beside the card', (tester) async {
    SharedPreferences.setMockInitialValues({'seerr.requestWindow': 'fromCard'});
    await pumpApp(tester, seerrUser: _me);
    final card = tester.getRect(find.ancestor(of: find.text('New Anime').first, matching: find.byType(SeerrCard)));
    await hover(tester, 'New Anime');
    await tester.tap(find.widgetWithText(FilledButton, 'Request'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    final title = tester.getRect(find.text('Request New Anime'));
    expect(title.left, greaterThan(card.right), reason: 'to the right of the card');
    expect((title.center.dy - card.center.dy).abs(), lessThan(400), reason: 'at its height');
  });

  testWidgets('right-click a Seerr card: Request… and Details', (tester) async {
    await pumpApp(tester, seerrUser: _me);
    final card = find.ancestor(of: find.text('New Anime').first, matching: find.byType(SeerrCard));
    await tester.tapAt(tester.getCenter(card), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    await tester.tap(find.text('Request…'));
    await tester.pumpAndSettle();
    expect(find.text('Request New Anime'), findsOneWidget);
  });

  testWidgets('blocklisted titles never show, and never as "Deleted"', (tester) async {
    // Seerr 3: 6 = blocklisted, 7 = deleted.
    server.routes['/api/v1/discover/tv'] = (200, {
      'results': [_tv(2, 'Dandadan', status: 5), _tv(3, 'New Anime'), _tv(9, "Adam's Sweet Agony", status: 6), _tv(8, 'Gone Show', status: 7)],
    });
    await pumpApp(tester, seerrUser: _me);
    expect(find.text("Adam's Sweet Agony"), findsNothing);
    expect(find.text('Gone Show'), findsWidgets, reason: 'deleted titles show (and can be requested again)');
    expect(find.text('Deleted'), findsWidgets);
    expect(SeerrMediaStatus.of(6), SeerrMediaStatus.blocklisted);
    expect(SeerrMediaStatus.blocklisted.requestable, isFalse);
  });

  testWidgets('search offers titles that are not on the server', (tester) async {
    await pumpApp(tester, seerrUser: _me);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    // Jellyfin finds Dandadan; Tanya is on the server under its romaji name.
    server.routes['/Items'] = (200, pageJson([itemJson('dandadan-1', 'Dandadan', type: 'Series')]));
    await tester.enterText(find.byType(TextField), 'dan of');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('From Seerr'), findsOneWidget);
    expect(server.requestsTo('/api/v1/search').last.uri.query, contains('query=dan%20of'));
    expect(find.text('New Anime'), findsOneWidget);
    expect(find.text('Dandadan'), findsOneWidget, reason: 'once, in the Jellyfin row');
    expect(find.text('Saga of Tanya the Evil'), findsOneWidget, reason: 'available but not found by Jellyfin');

    // An available title opens the library item, not the Seerr page.
    await tester.tap(find.text('Saga of Tanya the Evil'));
    await tester.pumpAndSettle();
    expect(server.requests.any((r) => r.path.contains('tanya-1')), isTrue);
  });

  testWidgets('Seerr search errors are shown, not hidden', (tester) async {
    server.routes['/api/v1/search'] = (500, {'message': 'boom'});
    await pumpApp(tester, seerrUser: _me);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'tanya');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.textContaining('From Seerr:'), findsOneWidget);
  });

  testWidgets('admins approve pending requests', (tester) async {
    server.routes['/api/v1/request'] = (RequestOptions o) => (
          200,
          {
            'results': [
              {
                'id': 21, 'status': 1, 'type': 'tv', 'media': {'tmdbId': 3, 'status': 2},
                'requestedBy': _me, 'createdAt': '2026-10-26T10:00:00Z', 'seasons': [{'seasonNumber': 2}],
              },
            ],
          },
        );
    server.routes['POST /api/v1/request/21/approve'] = (200, {});
    // Seerr agrees it's the admin (the app asks again on start).
    server.routes['/api/v1/auth/me'] = (200, _admin);
    await pumpApp(tester, seerrUser: _admin);
    await tester.tap(find.byTooltip('Requests'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.textContaining('by sam'), findsOneWidget);
    await tester.tap(find.byTooltip('Approve'));
    await tester.pumpAndSettle();
    expect(server.requestsTo('/api/v1/request/21/approve'), hasLength(1));
  });

  test('announces a request once it becomes available (not old news)', () async {
    FlutterSecureStorage.setMockInitialValues({...signedInStorage(), 'seerr.account': _account(_me)});
    var status = 3; // processing
    server.routes['/api/v1/request'] = (RequestOptions o) => (
          200,
          {
            'results': [
              {'id': 9, 'status': 2, 'type': 'tv', 'media': {'tmdbId': 3, 'status': status}, 'requestedBy': _me, 'createdAt': '2026-10-27T10:00:00Z'},
            ],
          },
        );
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await c.read(seerrAccountProvider.future);
    final announced = <String>[];
    c.listen(seerrAvailabilityProvider, (_, next) {
      if (next case AsyncData(:final value)) announced.add(value.media.title);
    });
    await Future<void>.delayed(const Duration(milliseconds: 50)); // first check: records only
    expect(announced, isEmpty);

    status = 5; // available; the next check (a rebuild) announces it
    c.invalidate(seerrAvailabilityProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(announced, ['New Anime']);
  });

  test('an airing series is announced when its first episodes land, then when complete', () async {
    FlutterSecureStorage.setMockInitialValues({...signedInStorage(), 'seerr.account': _account(_me)});
    var status = 3; // processing
    server.routes['/api/v1/request'] = (RequestOptions o) => (
          200,
          {
            'results': [
              {'id': 9, 'status': 2, 'type': 'tv', 'media': {'tmdbId': 3, 'status': status}, 'requestedBy': _me, 'createdAt': '2026-10-27T10:00:00Z'},
            ],
          },
        );
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await c.read(seerrAccountProvider.future);
    final announced = <String>[];
    // As the home screen does: each alert once, even across rebuilds.
    void listen() => c.listen(seerrAvailabilityProvider, (previous, next) {
          if (next case AsyncData(:final value) when !identical(value, previous?.value)) {
            announced.add(value.message);
          }
        });
    Future<void> check(int next) async {
      status = next;
      c.invalidate(seerrAvailabilityProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    listen();
    await Future<void>.delayed(const Duration(milliseconds: 50)); // records "processing"
    await check(4); // partly available
    await check(4); // no change: not repeated
    await check(5); // complete
    expect(server.requestsTo('/api/v1/tv/3'), hasLength(2), reason: 'details fetched per announcement');
    expect(announced, ['New Anime: first episodes are available.', 'New Anime is now available.']);
  });
}
