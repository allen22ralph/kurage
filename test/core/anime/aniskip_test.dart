import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/anime/anime_ids.dart';
import 'package:jellyfin_client/core/anime/aniskip.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/core/jellyfin/playback_api.dart';
import 'package:jellyfin_client/features/anime/anime_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

/// AniSkip's real answer for Frieren (MAL 52991) episode 1.
const _frierenEp1 = {
  'found': true,
  'results': [
    {'interval': {'startTime': 1417.135, 'endTime': 1507.135}, 'skipType': 'ed', 'episodeLength': 1510.1},
    {'interval': {'startTime': 3.221, 'endTime': 93.221}, 'skipType': 'op', 'episodeLength': 1559.9},
  ],
  'statusCode': 200,
};

void main() {
  test('maps op/ed to intro/credits, sorted; passes the episode length', () async {
    final server = FakeServer({'/v2/skip-times/52991/1': (200, _frierenEp1)});
    final api = AniSkipApi(dio: Dio(BaseOptions(baseUrl: 'https://api.aniskip.com/v2'))..httpClientAdapter = server);
    final segments = await api.skipTimes(52991, 1, episodeLength: const Duration(minutes: 24, seconds: 20));

    expect([for (final s in segments) s.type], [SegmentType.intro, SegmentType.outro]);
    expect(segments.first.start, const Duration(milliseconds: 3221));
    expect(segments.first.end, const Duration(milliseconds: 93221));
    final q = server.requests.single.uri.query;
    expect(q, contains('types%5B%5D=op'));
    expect(q, contains('episodeLength=1460'));
  });

  test('one segment per kind: closest length, plain over mixed', () async {
    final server = FakeServer({
      '/v2/skip-times/52991/1': (200, {
        'found': true,
        'results': [
          {'interval': {'startTime': 43.87, 'endTime': 133.87}, 'skipType': 'op', 'episodeLength': 1469.9},
          {'interval': {'startTime': 58.71, 'endTime': 148.71}, 'skipType': 'mixed-op', 'episodeLength': 1460.2},
          {'interval': {'startTime': 3.22, 'endTime': 93.22}, 'skipType': 'op', 'episodeLength': 1559.9},
        ],
      }),
    });
    final api = AniSkipApi(dio: Dio(BaseOptions(baseUrl: 'https://api.aniskip.com/v2'))..httpClientAdapter = server);
    final segments = await api.skipTimes(52991, 1, episodeLength: const Duration(seconds: 1460));
    expect(segments, hasLength(1));
    // 1460.2 (+0.5 for mixed) beats 1469.9; 1559.9 is a different release.
    expect(segments.single.start, const Duration(milliseconds: 58710));
  });

  test('nothing known (404 / found false) is just no segments', () async {
    final server = FakeServer({
      '/v2/skip-times/1/1': (404, {'found': false, 'results': [], 'statusCode': 404}),
    });
    final api = AniSkipApi(dio: Dio(BaseOptions(baseUrl: 'https://api.aniskip.com/v2'))..httpClientAdapter = server);
    expect(await api.skipTimes(1, 1), isEmpty);
  });

  test('looks up an episode through its MAL match, unless turned off', () async {
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    SharedPreferences.setMockInitialValues({});
    final ids = {'AniDB': '17617'};
    final server = FakeServer({
      '/Items/fr': (200, itemJson('fr', 'Frieren', type: 'Series', extra: {'ProviderIds': ids})),
      '/Items/fr1': (200, itemJson('fr1', 'Season 1', type: 'Season', extra: {'ProviderIds': ids})),
      '/v2/skip-times/52991/1': (200, _frierenEp1),
    });
    final c = ProviderContainer(
      overrides: fakeServerOverrides(
        server,
        animeIds: AnimeIdMapping.fromFribb([
          {'type': 'TV', 'anidb_id': 17617, 'mal_id': 52991},
        ]),
      ),
    );
    addTearDown(c.dispose);
    await c.read(sessionControllerProvider.future);
    final episode = BaseItem.fromJson({
      'Id': 'e1', 'Name': 'The Journey\'s End', 'Type': 'Episode', 'SeriesId': 'fr', 'SeasonId': 'fr1',
      'ParentIndexNumber': 1, 'IndexNumber': 1,
    });

    expect(await aniSkipSegments(c, episode), hasLength(2));

    SharedPreferences.setMockInitialValues({'anime.useAniSkip': false});
    final off = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(off.dispose);
    expect(await aniSkipSegments(off, episode), isEmpty);
  });
}
