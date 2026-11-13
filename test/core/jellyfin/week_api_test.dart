import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/jellyfin_api.dart';
import 'package:jellyfin_client/core/jellyfin/week_api.dart';

import '../../support/fake_server.dart';

void main() {
  // A Monday.
  final monday = DateTime(2026, 11, 2);

  WeekApi api(FakeServer server) => WeekApi(
        JellyfinApi(
          baseUrl: Uri.parse('https://jellyfin.home.arpa'),
          clientInfo: testClientInfo,
          accessToken: 'tok',
          dio: Dio()..httpClientAdapter = server,
        ),
        userId: 'u1',
      );

  Map<String, Object?> episode(String id, DateTime at, {bool hasFile = false, String? episodeId, String? itemId}) => {
        'id': id,
        'source': 'Sonarr',
        'type': 'Series',
        'title': 'Frieren',
        'episodeTitle': 'The Journey',
        'seasonNumber': 2,
        'episodeNumber': 5,
        'releaseDate': at.toUtc().toIso8601String(),
        'releaseType': 'Episode',
        'hasFile': hasFile,
        'posterUrl': 'https://artworks.thetvdb.com/p.jpg',
        'itemId': itemId,
        'itemEpisodeId': episodeId,
      };

  test("weekStart: the local Monday at midnight, from any day of its week", () {
    expect(weekStart(DateTime(2026, 11, 2, 9)), monday);
    expect(weekStart(DateTime(2026, 11, 8, 23, 59)), monday);
    expect(weekStart(DateTime(2026, 11, 9)), DateTime(2026, 11, 9));
  });

  test("Sonarr/Radarr through the server's plugin: each entry matched to the library", () async {
    final server = FakeServer({
      '/JellyfinEnhanced/arr/calendar': (
        200,
        {
          'events': [
            episode('7', DateTime(2026, 11, 4, 21, 30), hasFile: true, itemId: 'aaaa-1', episodeId: 'bbbb-2'),
            episode('8', DateTime(2026, 11, 6, 18), itemId: 'aaaa-1'),
            {
              'id': '3-DigitalRelease',
              'source': 'Radarr',
              'type': 'Movie',
              'title': 'Your Name',
              'releaseDate': DateTime(2026, 11, 3, 0, 5).toUtc().toIso8601String(),
              'releaseType': 'DigitalRelease',
              'hasFile': false,
            },
          ],
          'errors': [
            {'source': 'Radarr', 'instanceName': '4K', 'reason': 'timed out'},
          ],
        },
      ),
      '/Items': (
        200,
        pageJson([
          itemJson('aaaa1', 'Frieren', type: 'Series'),
          itemJson('bbbb2', 'The Journey', type: 'Episode', extra: {'SeriesName': 'Frieren'}),
        ]),
      ),
    });
    final week = await api(server).week(monday);

    expect(week.source, WeekSource.arr);
    expect(week.problems.single, contains('4K'));
    expect([for (final e in week.entries) e.title], ['Your Name', 'Frieren', 'Frieren'], reason: 'in order');
    final film = week.entries[0];
    expect(film.movie, isTrue);
    expect(film.release, 'Digital');
    expect(film.item, isNull, reason: 'not in Jellyfin');

    final aired = week.entries[1];
    expect(aired.code, 'S2:E5');
    expect(aired.inLibrary, isTrue);
    expect(aired.item?.id, 'bbbb2', reason: 'the episode itself');
    expect(aired.at, DateTime(2026, 11, 4, 21, 30));
    expect(week.entries[2].item?.id, 'aaaa1', reason: 'not in yet: its show');
    expect(week.entries[2].imageUrl, 'https://artworks.thetvdb.com/p.jpg');

    expect(week.day(2).single.id, 'Sonarr:7', reason: 'Wednesday');
    expect(week.day(0), isEmpty);

    final asked = server.requestsTo('/JellyfinEnhanced/arr/calendar').single.uri.queryParameters;
    expect(DateTime.parse(asked['start']!), monday.toUtc());
    expect(DateTime.parse(asked['end']!), DateTime(2026, 11, 9).toUtc());
    final ids = server.requestsTo('/Items').single.uri.queryParameters['ids']!.split(',');
    expect(ids, unorderedEquals(['aaaa1', 'bbbb2']), reason: 'one request, the ids without dashes');
  });

  test('no plugin on the server: Jellyfin, aired this week and upcoming', () async {
    final server = FakeServer({
      // (No calendar route: a 404.)
      '/Items': (
        200,
        pageJson([
          itemJson('e1', 'Ep 1', type: 'Episode', extra: {
            'SeriesName': 'Silent Witch',
            'IndexNumber': 1,
            'ParentIndexNumber': 1,
            'PremiereDate': '2026-11-03T00:00:00.0000000Z',
          }),
        ]),
      ),
      '/Shows/Upcoming': (
        200,
        pageJson([
          itemJson('e2', 'Ep 2', type: 'Episode', extra: {
            'SeriesName': 'Silent Witch',
            'IndexNumber': 2,
            'ParentIndexNumber': 1,
            'PremiereDate': '2026-11-10T00:00:00.0000000Z',
            'LocationType': 'Virtual',
          }),
          itemJson('e3', 'Ep 3', type: 'Episode', extra: {
            'SeriesName': 'Silent Witch',
            'PremiereDate': '2026-11-07T00:00:00.0000000Z',
            'LocationType': 'Virtual',
          }),
        ]),
      ),
    });
    final week = await api(server).week(monday);

    expect(week.source, WeekSource.jellyfin);
    expect([for (final e in week.entries) e.id], ['e1', 'e3'], reason: "next week's left out");
    expect(week.entries.first.at, DateTime(2026, 11, 3), reason: 'the day it aired, not shifted by the time zone');
    expect(week.entries.first.inLibrary, isTrue);
    expect(week.entries.last.inLibrary, isFalse, reason: 'a placeholder from the metadata');
  });

  test("the plugin with nothing this week (or no Sonarr set up): Jellyfin's instead", () async {
    final server = FakeServer({
      '/JellyfinEnhanced/arr/calendar': (200, {'events': <Object>[], 'errors': <Object>[]}),
      '/Items': (200, pageJson([])),
      '/Shows/Upcoming': (200, pageJson([])),
    });
    final week = await api(server).week(monday);
    expect(week.source, WeekSource.jellyfin);
    expect(server.requestsTo('/Shows/Upcoming'), hasLength(1));
  });

  test('the plugin failing: Jellyfin instead, not an error', () async {
    final server = FakeServer({
      '/JellyfinEnhanced/arr/calendar': (500, {'message': 'boom'}),
      '/Items': (200, pageJson([])),
      '/Shows/Upcoming': (200, pageJson([])),
    });
    expect((await api(server).week(monday)).source, WeekSource.jellyfin);
  });

  test("what Sonarr isn't tracking is left out, unless it's already in the library", () async {
    final server = FakeServer({
      '/JellyfinEnhanced/arr/calendar': (
        200,
        {
          'events': [
            {...episode('1', DateTime(2026, 11, 3, 20)), 'monitored': true},
            {...episode('2', DateTime(2026, 11, 4, 20)), 'monitored': false},
            {...episode('3', DateTime(2026, 11, 5, 20), hasFile: true), 'monitored': false},
            episode('4', DateTime(2026, 11, 6, 20)), // (an older plugin: no such field)
          ],
          'errors': <Object>[],
        },
      ),
    });
    final week = await api(server).week(monday);
    expect([for (final e in week.entries) e.id], ['Sonarr:1', 'Sonarr:3', 'Sonarr:4']);
  });

  group('the chosen source', () {
    FakeServer stopped() => FakeServer({
          '/JellyfinEnhanced/arr/calendar': (
            200,
            {
              'events': <Object>[],
              'errors': [
                {'source': 'Sonarr', 'instanceName': 'TV', 'reason': 'connection refused'},
              ],
            },
          ),
          '/Items': (200, pageJson([])),
          '/Shows/Upcoming': (200, pageJson([])),
        });

    test('automatic: Sonarr out of reach, Jellyfin instead, and it says why', () async {
      final week = await api(stopped()).week(monday);
      expect(week.source, WeekSource.jellyfin);
      expect(week.note, contains("couldn't reach"));
      expect(week.problems.single, contains('TV'));
      expect(week.failed, isFalse);
      expect(week.troubled, isTrue);
      expect(week.rowNote, 'Sonarr and Radarr unavailable, showing Jellyfin');
    });

    test("the row's note: only for what should be there and isn't", () {
      WeekSchedule of({
        WeekSource source = WeekSource.jellyfin,
        bool unreachable = false,
        bool failed = false,
        List<String> problems = const [],
        String? note,
      }) => WeekSchedule(
        start: monday,
        entries: const [],
        source: source,
        unreachable: unreachable,
        failed: failed,
        problems: problems,
        note: note,
      );

      // No plugin, or Jellyfin chosen: nothing is wrong.
      expect(of(note: "the server doesn't have the Jellyfin Enhanced calendar").rowNote, isNull);
      expect(of().rowNote, isNull);
      expect(of().troubled, isFalse);
      // Sonarr and Radarr simply have nothing this week.
      expect(of(note: 'Sonarr and Radarr have nothing this week').rowNote, isNull);
      // One of two answered.
      expect(of(source: WeekSource.arr, problems: ['Radarr "x": failed']).rowNote, contains('incomplete'));
      // Asked for alone: the row says so itself.
      expect(of(source: WeekSource.arr, unreachable: true, failed: true).rowNote, isNull);
    });

    test("Sonarr and Radarr alone: no Jellyfin instead, and it's a failure, not an empty week", () async {
      final server = stopped();
      final week = await api(server).week(monday, choice: WeekSourceChoice.arr);
      expect(week.source, WeekSource.arr);
      expect(week.entries, isEmpty);
      expect(week.failed, isTrue);
      expect(server.requestsTo('/Shows/Upcoming'), isEmpty);
    });

    test('Sonarr and Radarr alone, without the plugin: says so', () async {
      final week = await api(FakeServer({})).week(monday, choice: WeekSourceChoice.arr);
      expect(week.failed, isTrue);
      expect(week.note, contains('Jellyfin Enhanced'));
    });

    test('Sonarr and Radarr alone, with nothing this week: simply empty', () async {
      final server = FakeServer({
        '/JellyfinEnhanced/arr/calendar': (200, {'events': <Object>[], 'errors': <Object>[]}),
      });
      final week = await api(server).week(monday, choice: WeekSourceChoice.arr);
      expect(week.failed, isFalse);
      expect(week.entries, isEmpty);
    });

    test("Jellyfin only: the plugin isn't asked", () async {
      final server = stopped();
      final week = await api(server).week(monday, choice: WeekSourceChoice.jellyfin);
      expect(week.source, WeekSource.jellyfin);
      expect(week.note, isNull);
      expect(server.requestsTo('/JellyfinEnhanced/arr/calendar'), isEmpty);
    });
  });
}
