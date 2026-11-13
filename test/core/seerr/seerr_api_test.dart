import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/seerr/seerr_api.dart';

import '../../support/fake_server.dart';

/// FakeServer plus a Set-Cookie header on the sign-in response.
class _CookieServer extends FakeServer {
  _CookieServer(super.routes);

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final body = await super.fetch(options, requestStream, cancelFuture);
    if (options.path.endsWith('/auth/jellyfin') && body.statusCode == 200) {
      body.headers['set-cookie'] = ['connect.sid=s%3Aabc123; Path=/; HttpOnly; SameSite=Lax'];
    }
    return body;
  }
}

void main() {
  final base = Uri.parse('https://seerr.home.arpa');
  late FakeServer server;

  SeerrApi api({String? cookie, String? apiKey}) =>
      SeerrApi(baseUrl: base, dio: Dio()..httpClientAdapter = server, cookie: cookie, apiKey: apiKey);

  const me = {'id': 3, 'displayName': 'sam', 'permissions': 32};

  setUp(() {
    server = _CookieServer({
      '/api/v1/status': (200, {'version': '3.5.1'}),
      'POST /api/v1/auth/jellyfin': (RequestOptions o) {
        final body = o.data as Map;
        return body['password'] == 'pw' ? (200, me) : (401, {'message': 'Unauthorized'});
      },
      '/api/v1/auth/me': (200, me),
      '/api/v1/search': (
        200,
        {
          'page': 1,
          'totalPages': 1,
          'results': [
            {'id': 209867, 'mediaType': 'tv', 'name': 'Frieren', 'firstAirDate': '2023-09-29', 'posterPath': '/p.jpg', 'mediaInfo': {'status': 5}},
            {'id': 1, 'mediaType': 'person', 'name': 'Someone'},
            {'id': 129, 'mediaType': 'movie', 'title': 'Spirited Away', 'releaseDate': '2001-07-20'},
          ],
        },
      ),
      '/api/v1/tv/65942': (
        200,
        {
          'id': 65942,
          'name': 'Re:Zero',
          'seasons': [
            {'seasonNumber': 0, 'name': 'Specials', 'episodeCount': 5},
            {'seasonNumber': 1, 'name': 'Season 1', 'episodeCount': 25},
            {'seasonNumber': 2, 'name': 'Season 2', 'episodeCount': 25},
          ],
          'mediaInfo': {
            'status': 4,
            'seasons': [
              {'seasonNumber': 1, 'status': 5},
            ],
          },
        },
      ),
      'POST /api/v1/request': (RequestOptions o) => (
            201,
            {
              'id': 77,
              'status': 1,
              'type': 'tv',
              'media': {'tmdbId': (o.data as Map)['mediaId'], 'mediaType': 'tv', 'status': 2},
              'requestedBy': me,
              'createdAt': '2026-10-27T10:00:00.000Z',
              'seasons': [
                for (final n in ((o.data as Map)['seasons'] is List ? (o.data as Map)['seasons'] as List : const [2]))
                  {'seasonNumber': n},
              ],
            },
          ),
      '/api/v1/request': (200, {'pageInfo': {'results': 1}, 'results': []}),
      'POST /api/v1/request/77/approve': (200, {}),
      'POST /api/v1/request/77/decline': (200, {}),
      'DELETE /api/v1/request/77': (204, null),
      '/api/v1/service/sonarr': (200, [{'id': 0, 'name': 'Sonarr'}]),
      '/api/v1/service/sonarr/0': (
        200,
        {
          'server': {'id': 0, 'name': 'Sonarr', 'isDefault': true, 'activeProfileId': 4, 'activeDirectory': '/anime'},
          'profiles': [{'id': 4, 'name': 'HD-1080p'}, {'id': 6, 'name': 'Any'}],
          'rootFolders': [{'id': 1, 'path': '/anime'}, {'id': 2, 'path': '/tv'}],
        },
      ),
    });
  });

  test('checks an address is Seerr', () async {
    expect(await api().version(), '3.5.1');
    expect(server.requests.single.uri.toString(), 'https://seerr.home.arpa/api/v1/status');
  });

  test('signs in with Jellyfin and keeps only the session cookie', () async {
    final session = await api().signInWithJellyfin('sam', 'pw');
    expect(session.cookie, 'connect.sid=s%3Aabc123');
    expect(session.user.displayName, 'sam');
    expect(jsonEncode(server.requests.single.data), '{"username":"sam","password":"pw"}');

    expect(
      () => api().signInWithJellyfin('sam', 'nope'),
      throwsA(isA<SeerrException>().having((e) => e.message, 'message', contains('Wrong'))),
    );
  });

  test('sends the cookie or API key on every request', () async {
    await api(cookie: 'connect.sid=x').me();
    expect(server.requests.last.headers['Cookie'], 'connect.sid=x');
    await api(apiKey: 'k').me();
    expect(server.requests.last.headers['X-Api-Key'], 'k');
  });

  test('search skips people and reads availability', () async {
    final results = await api(cookie: 'c').search('frieren');
    expect([for (final r in results) (r.title, r.type, r.year)], [
      ('Frieren', SeerrMediaType.tv, 2023),
      ('Spirited Away', SeerrMediaType.movie, 2001),
    ]);
    expect(results.first.status, SeerrMediaStatus.available);
    expect(results.first.status.requestable, isFalse);
    expect(results.last.status, SeerrMediaStatus.unknown);
    expect(results.first.poster().toString(), 'https://image.tmdb.org/t/p/w342/p.jpg');
  });

  test('TV details list requestable seasons with their status', () async {
    final d = await api(cookie: 'c').details(SeerrMediaType.tv, 65942);
    expect([for (final s in d.seasons) (s.number, s.status)], [
      (1, SeerrMediaStatus.available),
      (2, SeerrMediaStatus.unknown),
    ]);
    expect(d.media.status, SeerrMediaStatus.partiallyAvailable);
  });

  test('requests seasons (or all), with optional server/profile/folder', () async {
    final r = await api(cookie: 'c').request(SeerrMediaType.tv, 65942, seasons: [2], serverId: 0, profileId: 4, rootFolder: '/anime');
    expect(server.requests.last.data, {
      'mediaType': 'tv',
      'mediaId': 65942,
      'seasons': [2],
      'is4k': false,
      'serverId': 0,
      'profileId': 4,
      'rootFolder': '/anime',
    });
    expect((r.id, r.status), (77, SeerrRequestStatus.pending));
    expect(r.seasons, [2]);

    await api(cookie: 'c').request(SeerrMediaType.tv, 65942);
    expect((server.requests.last.data as Map)['seasons'], 'all');
    await api(cookie: 'c').request(SeerrMediaType.movie, 129);
    expect((server.requests.last.data as Map).containsKey('seasons'), isFalse);
  });

  test('lists, approves, declines and cancels requests', () async {
    await api(cookie: 'c').requests(requestedBy: 3, filter: 'pending');
    expect(server.requests.last.queryParameters, {'take': 50, 'skip': 0, 'filter': 'pending', 'sort': 'added', 'requestedBy': 3});
    await api(cookie: 'c').approve(77);
    await api(cookie: 'c').decline(77);
    await api(cookie: 'c').cancel(77);
    expect([for (final r in server.requests.skip(1)) '${r.method} ${r.path}'], [
      'POST /request/77/approve',
      'POST /request/77/decline',
      'DELETE /request/77',
    ]);
  });

  test('servers come with profiles and root folders', () async {
    final s = (await api(cookie: 'c').services(SeerrMediaType.tv)).single;
    expect((s.name, s.isDefault, s.activeProfileId, s.activeDirectory), ('Sonarr', true, 4, '/anime'));
    expect([for (final p in s.profiles) p.name], ['HD-1080p', 'Any']);
    expect(s.rootFolders, ['/anime', '/tv']);
  });

  test('permissions: admin implies all; request per type', () {
    const user = SeerrUser(id: 1, displayName: 'u', permissions: SeerrPermission.requestTv);
    expect(user.canRequest(SeerrMediaType.tv), isTrue);
    expect(user.canRequest(SeerrMediaType.movie), isFalse);
    expect(user.canManageRequests, isFalse);
    const admin = SeerrUser(id: 1, displayName: 'a', permissions: SeerrPermission.admin);
    expect((admin.canManageRequests, admin.canRequestAdvanced, admin.canRequest4k(SeerrMediaType.movie)), (true, true, true));
  });

  test('server messages come through; no answer means unreachable', () async {
    server.routes['/api/v1/auth/me'] = (403, {'message': 'You do not have permission'});
    await expectLater(api(cookie: 'c').me(), throwsA(isA<SeerrException>().having((e) => e.message, 'm', 'You do not have permission')));
    server.routes['/api/v1/auth/me'] = unreachable;
    await expectLater(api(cookie: 'c').me(), throwsA(isA<SeerrException>().having((e) => e.message, 'm', contains("Couldn't reach"))));
  });
}
