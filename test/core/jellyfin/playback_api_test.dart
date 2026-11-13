import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/jellyfin_api.dart';
import 'package:jellyfin_client/core/jellyfin/playback_api.dart';

import '../../support/fake_server.dart';

void main() {
  late FakeServer server;
  late PlaybackApi playback;

  PlaybackApi build({String base = 'https://jellyfin.home.arpa'}) => PlaybackApi(
        JellyfinApi(
          baseUrl: Uri.parse(base),
          clientInfo: testClientInfo,
          accessToken: 'tok',
          dio: Dio()..httpClientAdapter = server,
        ),
        userId: 'u1',
      );

  setUp(() {
    server = FakeServer({
      '/MediaSegments/ep1': (
        200,
        {
          'Items': [
            {'Type': 'Outro', 'StartTicks': 13000000000, 'EndTicks': 14000000000},
            {'Type': 'Intro', 'StartTicks': 600000000, 'EndTicks': 1500000000},
          ],
        },
      ),
      '/Sessions/Playing': (204, null),
      '/Sessions/Playing/Progress': (204, null),
      '/Sessions/Playing/Stopped': (204, null),
    });
    playback = build();
  });

  PlaybackInfo info(Map<String, Object?> source, {String? error}) =>
      PlaybackInfo.fromJson({
        'MediaSources': [
          {'Id': 'src1', 'Container': 'mkv', ...source},
        ],
        'PlaySessionId': 'ps1',
        'ErrorCode': ?error,
      });

  test('device profile allows direct play of any container', () {
    final profile = mpvDeviceProfile();
    final direct = profile['DirectPlayProfiles']! as List;
    expect(direct, anyElement(equals({'Type': 'Video'})));
    final subs = (profile['SubtitleProfiles']! as List).cast<Map>();
    expect(subs, anyElement(equals({'Format': 'ass', 'Method': 'Embed'})));
    expect(subs, anyElement(equals({'Format': 'pgssub', 'Method': 'Embed'})));
  });

  test('direct play uses the static original-file URL', () {
    final plan = playback.plan('ep1', info({'SupportsDirectPlay': true}));
    expect(plan.method, PlayMethod.directPlay);
    expect(plan.url.path, '/Videos/ep1/stream');
    expect(plan.url.queryParameters, {
      'static': 'true',
      'mediaSourceId': 'src1',
      'playSessionId': 'ps1',
      'deviceId': 'test-device',
    }, reason: 'no token in the address: the player sends it as a header');
    expect(plan.transcodeReasons, isEmpty);
  });

  test('transcode resolves the server URL under a base path', () {
    final api = build(base: 'https://host/jellyfin');
    final plan = api.plan(
      'ep1',
      info({
        'SupportsTranscoding': true,
        'TranscodingUrl': '/videos/ep1/master.m3u8?MediaSourceId=src1'
            '&TranscodeReasons=ContainerBitrateExceedsLimit,AudioCodecNotSupported',
      }),
    );
    expect(plan.method, PlayMethod.transcode);
    expect(plan.url.toString(), startsWith('https://host/jellyfin/videos/ep1/master.m3u8?'));
    expect(plan.url.queryParameters['api_key'], 'tok');
    expect(plan.transcodeReasons, ['ContainerBitrateExceedsLimit', 'AudioCodecNotSupported']);
  });

  test('server refusals become readable errors', () {
    expect(
      () => playback.plan('ep1', info({}, error: 'NotAllowed')),
      throwsA(isA<JellyfinException>().having(
        (e) => e.message,
        'message',
        contains('isn\'t allowed'),
      )),
    );
    expect(
      () => playback.plan('ep1', PlaybackInfo.fromJson(const {})),
      throwsA(isA<JellyfinException>()),
    );
  });

  test('external subtitle URL carries the token', () {
    final plan = playback.plan('ep1', info({'SupportsDirectPlay': true}));
    const sub = MediaStream(index: 3, type: 'Subtitle', codec: 'ass', isExternal: true);
    final url = playback.subtitleUrl(plan, sub);
    expect(url.path, '/Videos/ep1/src1/Subtitles/3/0/Stream.ass');
    expect(url.queryParameters['api_key'], 'tok');
  });

  test('segments are parsed and sorted; missing endpoint means none', () async {
    final segments = await playback.getSegments('ep1');
    expect(segments.map((s) => s.type), [SegmentType.intro, SegmentType.outro]);
    expect(segments.first.start, const Duration(seconds: 60));
    expect(segments.first.end, const Duration(seconds: 150));
    expect(segments.first.contains(const Duration(seconds: 100)), isTrue);

    expect(await playback.getSegments('unknown'), isEmpty);
  });

  test('reports carry session, method and position in ticks', () async {
    final plan = playback.plan('ep1', info({'SupportsDirectPlay': true}));
    await playback.reportStart(plan, const Duration(seconds: 90));
    await playback.reportProgress(plan, const Duration(seconds: 100), paused: true);
    await playback.reportStopped(plan, const Duration(seconds: 120));

    final start = server.requestsTo('/Sessions/Playing').single.data as Map;
    expect(start['PlaySessionId'], 'ps1');
    expect(start['PlayMethod'], 'DirectPlay');
    expect(start['PositionTicks'], 900000000);

    final progress = server.requestsTo('/Sessions/Playing/Progress').single.data as Map;
    expect(progress['IsPaused'], true);

    final stopped = server.requestsTo('/Sessions/Playing/Stopped').single.data as Map;
    expect(stopped['PositionTicks'], 1200000000);
    expect(stopped.containsKey('IsPaused'), isFalse);
  });
}
