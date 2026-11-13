import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/core/jellyfin/jellyfin_api.dart';
import 'package:jellyfin_client/core/jellyfin/library_api.dart';
import 'package:jellyfin_client/core/jellyfin/playback_api.dart';
import 'package:jellyfin_client/features/player/media_engine.dart';
import 'package:jellyfin_client/features/player/playback_controller.dart';
import 'package:jellyfin_client/features/settings/playback_settings.dart';
import 'package:jellyfin_client/features/settings/series_tracks.dart';

import '../../support/fake_server.dart';

/// Records engine calls and lets tests drive position/completion.
class FakeEngine implements MediaEngine {
  final _position = StreamController<Duration>.broadcast(sync: true);
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _completed = StreamController<bool>.broadcast(sync: true);
  final _error = StreamController<String>.broadcast(sync: true);
  final _duration = StreamController<Duration>.broadcast(sync: true);
  final _buffering = StreamController<bool>.broadcast(sync: true);

  /// Like mpv waiting for (true) or getting (false) more of the stream.
  void buffer(bool waiting) => _buffering.add(waiting);

  Uri? openedUrl;
  Map<String, String>? openedHeaders;
  Duration? openedStart;
  int opens = 0;
  String? audioLanguages;
  String? subtitleLanguages;
  bool subtitlesOff = false;
  final addedSubtitles = <Uri>[];
  /// Chapters mpv would report for the file, once loaded.
  List<Chapter> fileChapters = const [];
  final seeks = <Duration>[];
  @override
  int jumps = 0;
  bool disposed = false;

  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(minutes: 24);
  @override
  bool isPlaying = true;

  /// Moves the playhead and emits it, like mpv does while playing.
  void moveTo(Duration p) {
    position = p;
    _position.add(p);
  }

  void complete() => _completed.add(true);

  /// Like mpv finishing loading the file: reports the duration.
  void loaded() => _duration.add(duration);
  void fail(String message) => _error.add(message);

  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;
  @override
  Stream<String> get errorStream => _error.stream;
  @override
  Stream<bool> get bufferingStream => _buffering.stream;

  @override
  Future<void> setLanguagePreferences({
    required String audio,
    required String subtitles,
    bool subtitlesOff = false,
  }) async {
    audioLanguages = audio;
    subtitleLanguages = subtitles;
    this.subtitlesOff = subtitlesOff;
  }

  @override
  Future<void> open(Uri url, {required Map<String, String> headers, Duration start = Duration.zero}) async {
    openedUrl = url;
    openedHeaders = headers;
    openedStart = start;
    opens++;
    jumps++;
  }

  @override
  Future<void> addSubtitle(Uri url, {String? title, String? language}) async =>
      addedSubtitles.add(url);

  @override
  Future<List<Chapter>> chapters() async => fileChapters;

  @override
  Future<void> seek(Duration p) async {
    jumps++;
    seeks.add(p);
    moveTo(p);
  }

  @override
  Future<void> playOrPause() async => isPlaying = !isPlaying;
  @override
  Future<void> play() async => isPlaying = true;
  @override
  Future<void> pause() async => isPlaying = false;
  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> dispose() async => disposed = true;
}

const _minute = 60 * ticksPerSecond;

Map<String, Object> _routes({
  int positionTicks = 5 * _minute,
  bool withSegments = true,
  bool withNext = true,
  bool withPrevious = false,
  bool played = false,
  List<int> jellyfinChapterMinutes = const [],
  String? errorCode,
}) =>
    {
      '/Items/ep1': (
        200,
        itemJson('ep1', 'Episode 1', type: 'Episode', extra: {
          'SeriesId': 'ser1',
          'SeriesName': 'Frieren',
          'RunTimeTicks': 24 * _minute,
          'UserData': {'PlaybackPositionTicks': positionTicks, 'PlayedPercentage': 20, 'Played': played},
          'Chapters': [
            for (final m in jellyfinChapterMinutes)
              {'Name': 'Chapter', 'StartPositionTicks': m * _minute},
          ],
        }),
      ),
      '/Items/ep1/PlaybackInfo': (
        200,
        {
          'PlaySessionId': 'ps1',
          'ErrorCode': ?errorCode,
          'MediaSources': [
            {
              'Id': 'src1',
              'SupportsDirectPlay': true,
              'MediaStreams': [
                {'Index': 0, 'Type': 'Video', 'Codec': 'hevc'},
                {'Index': 1, 'Type': 'Audio', 'Language': 'jpn'},
                {'Index': 2, 'Type': 'Subtitle', 'Codec': 'ass', 'Language': 'eng'},
                {
                  'Index': 3,
                  'Type': 'Subtitle',
                  'Codec': 'srt',
                  'Language': 'spa',
                  'IsExternal': true,
                  'DeliveryMethod': 'External',
                },
              ],
            },
          ],
        },
      ),
      '/MediaSegments/ep1': (
        200,
        {
          'Items': [
            if (withSegments) ...[
              {'Type': 'Intro', 'StartTicks': 1 * _minute, 'EndTicks': 2 * _minute},
              {'Type': 'Outro', 'StartTicks': 22 * _minute, 'EndTicks': 24 * _minute},
            ],
          ],
        },
      ),
      '/Shows/ser1/Episodes': (
        200,
        pageJson([
          if (withPrevious) itemJson('ep0', 'Episode 0', type: 'Episode'),
          itemJson('ep1', 'Episode 1', type: 'Episode'),
          if (withNext) itemJson('ep2', 'Episode 2', type: 'Episode'),
        ]),
      ),
      '/Sessions/Playing': (204, null),
      '/Sessions/Playing/Progress': (204, null),
      '/Sessions/Playing/Stopped': (204, null),
      '/UserPlayedItems/ep1': (200, {'Played': true}),
    };

/// Lets pending requests finish: Dio completes them via zero-length timers,
/// which flushMicrotasks alone doesn't run.
void settle(FakeAsync async) => async.elapse(const Duration(milliseconds: 5));

void main() {
  late FakeServer server;
  late FakeEngine engine;

  PlaybackController build(
    Map<String, Object> routes, {
    PlaybackSettings settings = const PlaybackSettings(),
    Future<List<MediaSegment>> Function(BaseItem item)? fallbackSegments,
    Future<bool> Function()? preferFallbackSegments,
    SeriesTrackChoice? Function(BaseItem item)? trackChoiceFor,
    ({String path, Map<String, dynamic> item})? Function(String itemId)? localCopy,
    void Function(String itemId, Duration position, bool finished)? onUnreportedStop,
    void Function(String message)? onNotice,
    DateTime Function()? now,
    StreamQuality? quality,
    String? playlistId,
  }) {
    server = FakeServer(routes);
    engine = FakeEngine();
    PlaybackController.forgetAutoLevel(picked: quality);
    final api = JellyfinApi(
      baseUrl: Uri.parse('https://jellyfin.home.arpa'),
      clientInfo: testClientInfo,
      accessToken: 'tok',
      dio: Dio()..httpClientAdapter = server,
    );
    return PlaybackController(
      engine: engine,
      playback: PlaybackApi(api, userId: 'u1'),
      library: LibraryApi(api, userId: 'u1'),
      settings: settings,
      authorizationHeader: api.authorizationHeader,
      fallbackSegments: fallbackSegments,
      preferFallbackSegments: preferFallbackSegments,
      trackChoiceFor: trackChoiceFor,
      localCopy: localCopy,
      onUnreportedStop: onUnreportedStop,
      onNotice: onNotice,
      now: now ?? DateTime.now,
      playlistId: playlistId,
    );
  }

  void loadIn(FakeAsync async, PlaybackController c, {bool fromStart = false}) {
    c.load('ep1', fromStart: fromStart);
    settle(async);
  }

  test('a downloaded item plays its file, offline too; unreported progress is kept', () {
    fakeAsync((async) {
      final unreported = <(String, Duration, bool)>[];
      final saved = itemJson('ep1', 'Episode 1', type: 'Episode', extra: {
        'UserData': {'Played': false, 'PlaybackPositionTicks': 3 * _minute},
        'MediaSources': [{'Id': 'src1', 'Container': 'mkv'}],
      });
      // No server at all.
      final c = build(
        {'/Items/ep1': (-1, null)},
        localCopy: (id) => id == 'ep1' ? (path: '/data/downloads/ep1.mkv', item: saved) : null,
        onUnreportedStop: (id, p, done) => unreported.add((id, p, done)),
      );
      loadIn(async, c);
      expect(c.error, isNull);
      expect(engine.openedUrl, Uri.file('/data/downloads/ep1.mkv'));
      expect(engine.openedStart, const Duration(minutes: 3), reason: 'resume point saved with it');
      expect(server.requestsTo('/Items/ep1/PlaybackInfo'), isEmpty);

      engine.moveTo(const Duration(minutes: 7));
      c.stop();
      settle(async);
      expect(unreported.last, ('ep1', const Duration(minutes: 7), false));
    });
  });

  test('offline, progress is kept as it plays; once the server takes it again, the kept one goes', () {
    fakeAsync((async) {
      final kept = <(String, Duration, bool)>[];
      final dropped = <String>[];
      final saved = itemJson('ep1', 'Episode 1', type: 'Episode', extra: {
        'MediaSources': [{'Id': 'src1', 'Container': 'mkv'}],
      });
      var down = true;
      final server = FakeServer({});
      final routes = <String, Object>{
        '/Items/ep1': (RequestOptions o) => (-1, null),
        '/Sessions/Playing': (RequestOptions o) => down ? (-1, null) : (204, null),
        '/Sessions/Playing/Progress': (RequestOptions o) => down ? (-1, null) : (204, null),
        '/Sessions/Playing/Stopped': (RequestOptions o) => down ? (-1, null) : (204, null),
      };
      server.routes.addAll(routes);
      engine = FakeEngine();
      final api = JellyfinApi(
        baseUrl: Uri.parse('https://jellyfin.home.arpa'),
        clientInfo: testClientInfo,
        accessToken: 'tok',
        dio: Dio()..httpClientAdapter = server,
      );
      final c = PlaybackController(
        engine: engine,
        playback: PlaybackApi(api, userId: 'u1'),
        library: LibraryApi(api, userId: 'u1'),
        settings: const PlaybackSettings(),
        authorizationHeader: api.authorizationHeader,
        localCopy: (id) => (path: '/data/downloads/ep1.mkv', item: saved),
        onUnreportedStop: (id, p, done) => kept.add((id, p, done)),
        onReportedAgain: dropped.add,
      );
      c.load('ep1');
      settle(async);

      // Playing on with no server: the position is kept as it goes, without
      // waiting for the player to close (closing the app, a crash).
      engine.moveTo(const Duration(minutes: 2));
      async.elapse(const Duration(seconds: 10));
      settle(async);
      expect(kept, isNotEmpty);
      expect(kept.last.$1, 'ep1');
      expect(kept.last.$2, const Duration(minutes: 2));
      expect(dropped, isEmpty);

      // The server answers again: what was kept is stale.
      down = false;
      async.elapse(const Duration(seconds: 10));
      settle(async);
      expect(dropped, ['ep1']);
      c.stop();
      settle(async);
    });
  });

  test('resumes, applies language prefs, loads external subtitles', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);

      expect(c.error, isNull);
      expect(c.plan?.method, PlayMethod.directPlay);
      expect(engine.openedStart, const Duration(minutes: 5));
      expect(engine.openedUrl?.path, '/Videos/ep1/stream');
      expect(engine.openedHeaders?['Authorization'], contains('Token="tok"'));
      expect(engine.audioLanguages, 'jpn,ja');
      expect(engine.subtitleLanguages, 'eng,en');
      // Only the sidecar file is added; the embedded ASS track is in the file.
      expect(engine.addedSubtitles.single.path, '/Videos/ep1/src1/Subtitles/3/0/Stream.srt');
      expect(c.nextEpisode?.id, 'ep2');

      final start = server.requestsTo('/Sessions/Playing').single.data as Map;
      expect(start['PositionTicks'], 5 * _minute);
    });
  });

  test('from start ignores the saved position', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c, fromStart: true);
      expect(engine.openedStart, Duration.zero);
    });
  });

  test('reports progress every 10 seconds and when pausing', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);

      engine.position = const Duration(minutes: 6);
      async.elapse(const Duration(seconds: 25));
      expect(server.requestsTo('/Sessions/Playing/Progress'), hasLength(2));

      engine.isPlaying = false;
      engine._playing.add(false);
      settle(async);
      final last = server.requestsTo('/Sessions/Playing/Progress').last.data as Map;
      expect(last['IsPaused'], true);
    });
  });

  test('offers skip during the intro and seeks to its end', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);

      engine.moveTo(const Duration(seconds: 30));
      expect(c.activeSegment, isNull);
      engine.moveTo(const Duration(seconds: 75));
      expect(c.activeSegment?.type, SegmentType.intro);

      c.skipSegment();
      settle(async);
      expect(engine.seeks, [const Duration(minutes: 2)]);
      expect(c.activeSegment, isNull);
    });
  });

  test('auto-skips the intro once when enabled', () {
    fakeAsync((async) {
      final c = build(
        _routes(),
        settings: const PlaybackSettings(autoSkipIntro: true),
      );
      loadIn(async, c);

      engine.moveTo(const Duration(seconds: 61));
      expect(engine.seeks, [const Duration(minutes: 2)]);

      // Seeking back into the intro doesn't skip it again.
      engine.moveTo(const Duration(seconds: 70));
      expect(engine.seeks, hasLength(1));
    });
  });

  test('up next counts down the last 30 seconds of the file, then requests next once', () {
    fakeAsync((async) {
      final c = build(_routes());
      final requested = <String>[];
      c.nextRequests.listen((e) => requested.add(e.id));
      loadIn(async, c);

      // Not when the credits start.
      engine.moveTo(const Duration(minutes: 22, seconds: 1));
      expect(c.activeSegment?.type, SegmentType.outro);
      expect(c.upNextCountdown, isNull);

      engine.moveTo(const Duration(minutes: 23, seconds: 30));
      expect(c.upNextCountdown, 30);
      // Paused: time passes, the countdown doesn't.
      async.elapse(const Duration(seconds: 5));
      expect(c.upNextCountdown, 30);
      engine.moveTo(const Duration(minutes: 23, seconds: 50, milliseconds: 500));
      expect(c.upNextCountdown, 10);
      expect(requested, isEmpty);

      engine.moveTo(const Duration(minutes: 24));
      engine.complete();
      settle(async);
      expect(requested, ['ep2']);
    });
  });

  test('seeking back out of the credits hides up next; cancel dismisses', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);

      engine.moveTo(const Duration(minutes: 23, seconds: 40));
      expect(c.upNextCountdown, isNotNull);
      engine.moveTo(const Duration(minutes: 10));
      expect(c.upNextCountdown, isNull);

      engine.moveTo(const Duration(minutes: 23, seconds: 40));
      c.dismissUpNext();
      engine.moveTo(const Duration(minutes: 23, seconds: 45));
      expect(c.upNextCountdown, isNull);
    });
  });

  test('a chapter after the credits: skip credits lands on it, next waits for the end', () {
    fakeAsync((async) {
      final c = build(_routes(jellyfinChapterMinutes: const [0, 22, 23]));
      final requested = <String>[];
      c.nextRequests.listen((e) => requested.add(e.id));
      loadIn(async, c);

      // Credits, no countdown yet; skipping goes to the scene, not ep2.
      engine.moveTo(const Duration(minutes: 22, seconds: 10));
      expect(c.activeSegment?.type, SegmentType.outro);
      expect(c.upNextCountdown, isNull);
      c.skipSegment();
      settle(async);
      expect(engine.seeks, [const Duration(minutes: 23)]);
      expect(c.activeSegment, isNull);
      expect(requested, isEmpty);

      // The scene plays; the countdown only runs out at the end of the file.
      engine.moveTo(const Duration(minutes: 23, seconds: 20));
      expect(c.upNextCountdown, isNull);
      engine.moveTo(const Duration(minutes: 23, seconds: 40));
      expect(c.upNextCountdown, 20);
      async.elapse(const Duration(seconds: 25));
      expect(requested, isEmpty);
      engine.moveTo(const Duration(minutes: 24));
      settle(async);
      expect(requested, ['ep2']);
    });
  });

  test('an "Outro" chapter after an "ED" chapter is the post-credits scene', () {
    fakeAsync((async) {
      final c = build(_routes());
      final requested = <String>[];
      c.nextRequests.listen((e) => requested.add(e.id));
      engine.fileChapters = const [
        Chapter(Duration.zero, title: 'Part A'),
        Chapter(Duration(minutes: 22), title: 'ED'),
        Chapter(Duration(minutes: 23, seconds: 3), title: 'Outro'),
      ];
      loadIn(async, c);
      engine.loaded();
      settle(async);

      engine.moveTo(const Duration(minutes: 22, seconds: 10));
      c.skipSegment();
      settle(async);
      expect(engine.seeks, [const Duration(minutes: 23, seconds: 3)]);
      expect(requested, isEmpty);
    });
  });

  test('an "Ending" chapter a little after the credits start is still the credits', () {
    fakeAsync((async) {
      final c = build(_routes());
      final requested = <String>[];
      c.nextRequests.listen((e) => requested.add(e.id));
      engine.fileChapters = const [
        Chapter(Duration.zero, title: 'Part B'),
        Chapter(Duration(minutes: 22, seconds: 20), title: 'Ending'),
      ];
      loadIn(async, c);
      engine.loaded();
      settle(async);

      engine.moveTo(const Duration(minutes: 22, seconds: 30));
      c.skipSegment();
      settle(async);
      expect(requested, ['ep2']);
    });
  });

  test('a preview chapter after the credits is not a post-credits scene', () {
    fakeAsync((async) {
      final c = build(_routes());
      final requested = <String>[];
      c.nextRequests.listen((e) => requested.add(e.id));
      engine.fileChapters = const [
        Chapter(Duration.zero, title: 'Part A'),
        Chapter(Duration(minutes: 22), title: 'Ending'),
        Chapter(Duration(minutes: 23, seconds: 30), title: 'Preview'),
      ];
      loadIn(async, c);
      engine.loaded();
      settle(async);

      engine.moveTo(const Duration(minutes: 22, seconds: 10));
      c.skipSegment();
      settle(async);
      expect(requested, ['ep2']);
    });
  });

  test('a stream that comes back at the start by itself goes back to where it was', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);

      engine.moveTo(const Duration(minutes: 16, seconds: 10));
      // The player reconnects after the server restarts, from the start.
      engine.moveTo(const Duration(seconds: 1));
      settle(async);
      expect(engine.seeks, [const Duration(minutes: 16, seconds: 10)]);
      expect(engine.position, const Duration(minutes: 16, seconds: 10));
    });
  });

  test('seeking to the start yourself stays there', () {
    fakeAsync((async) {
      loadIn(async, build(_routes()));

      engine.moveTo(const Duration(minutes: 16));
      unawaited(engine.seek(Duration.zero));
      engine.moveTo(const Duration(seconds: 1));
      settle(async);
      expect(engine.seeks, [Duration.zero]);
      expect(engine.position, const Duration(seconds: 1));
    });
  });

  int maxBitrateOf(Object? request) => ((request as dynamic).data as Map)['MaxStreamingBitrate'] as int;

  test('quality: a fixed one is asked for; picking another reopens where it was', () {
    fakeAsync((async) {
      final c = build(_routes(), quality: StreamQuality.mbps4);
      loadIn(async, c);
      final infos = server.requestsTo('/Items/ep1/PlaybackInfo');
      expect(maxBitrateOf(infos.single), 4000000);

      engine.moveTo(const Duration(minutes: 7));
      unawaited(c.setQuality(StreamQuality.original));
      settle(async);
      expect(maxBitrateOf(server.requestsTo('/Items/ep1/PlaybackInfo').last), 200000000);
      expect(engine.opens, 2);
      expect(engine.openedStart, const Duration(minutes: 7));
      expect(server.requestsTo('/Sessions/Playing/Stopped'), hasLength(1), reason: 'the old stream ends');
      expect(c.quality, StreamQuality.original);
    });
  });

  test("another of the server's addresses: the stream reopens from it, where it was", () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      expect(engine.openedUrl!.host, 'jellyfin.home.arpa');

      engine.moveTo(const Duration(minutes: 12));
      final away = JellyfinApi(
        baseUrl: Uri.parse('https://jf.example.ts.net'),
        clientInfo: testClientInfo,
        accessToken: 'tok',
        dio: Dio()..httpClientAdapter = server,
      );
      unawaited(c.moveTo(playback: PlaybackApi(away, userId: 'u1'), library: LibraryApi(away, userId: 'u1')));
      settle(async);
      expect(engine.opens, 2);
      expect(engine.openedUrl!.host, 'jf.example.ts.net');
      expect(engine.openedStart, const Duration(minutes: 12));
      expect(server.requestsTo('/Items/ep1/PlaybackInfo').last.uri.host, 'jf.example.ts.net');
    });
  });

  test("the server not answering a quality change is an address problem: asked about, no notice", () {
    fakeAsync((async) {
      var asked = 0;
      final notices = <String>[];
      final c = build(_routes(), quality: StreamQuality.mbps4);
      final watched = PlaybackController(
        engine: engine,
        playback: c.playback,
        library: c.library,
        settings: const PlaybackSettings(),
        authorizationHeader: c.authorizationHeader,
        onLongWait: () => asked++,
        onNotice: notices.add,
      );
      loadIn(async, watched);
      server.routes['/Items/ep1/PlaybackInfo'] = unreachable;
      unawaited(watched.setQuality(StreamQuality.original));
      settle(async);
      expect(notices, isEmpty);
      expect(asked, 1);
    });
  });

  test('a long wait for the stream asks whether the address still answers, whatever the quality', () {
    fakeAsync((async) {
      var asked = 0;
      server = FakeServer(_routes());
      final c = build(_routes(), quality: StreamQuality.original);
      final watched = PlaybackController(
        engine: engine,
        playback: c.playback,
        library: c.library,
        settings: const PlaybackSettings(),
        authorizationHeader: c.authorizationHeader,
        onLongWait: () => asked++,
      );
      loadIn(async, watched);
      engine.buffer(true);
      async.elapse(const Duration(seconds: 3));
      engine.buffer(false);
      expect(asked, 0, reason: 'a short wait');
      engine.buffer(true);
      async.elapse(const Duration(seconds: 7));
      expect(asked, 1);
      async.elapse(const Duration(seconds: 6));
      expect(asked, 2, reason: 'asked again while it still waits');
      engine.buffer(false);
      async.elapse(const Duration(seconds: 20));
      expect(asked, 2);
    });
  });

  test('quality: the default applies until one is picked; a pick lasts for the next episode', () {
    fakeAsync((async) {
      final c = build(_routes(), settings: const PlaybackSettings(defaultQuality: StreamQuality.mbps10));
      loadIn(async, c);
      expect(c.quality, StreamQuality.mbps10);
      expect(maxBitrateOf(server.requestsTo('/Items/ep1/PlaybackInfo').single), 10000000);
      unawaited(c.setQuality(StreamQuality.mbps2));
      settle(async);

      // The next episode, same run of the app: the pick, not the default.
      final next = PlaybackController(
        engine: FakeEngine(),
        playback: c.playback,
        library: c.library,
        settings: const PlaybackSettings(defaultQuality: StreamQuality.mbps10),
        authorizationHeader: 'x',
      );
      expect(next.quality, StreamQuality.mbps2);
    });
  });
  test('auto: playback that keeps stalling steps the quality down', () {
    fakeAsync((async) {
      final clock = async.getClock(DateTime(2026, 11, 12));
      final notices = <String>[];
      final c = build(_routes(), onNotice: notices.add, now: clock.now);
      loadIn(async, c);
      expect(c.quality, StreamQuality.auto);
      expect(maxBitrateOf(server.requestsTo('/Items/ep1/PlaybackInfo').single), 200000000);

      // Loading after the open isn't a stall.
      engine.buffer(true);
      async.elapse(const Duration(seconds: 3));
      engine.buffer(false);
      // A hiccup doesn't count; three real stalls do.
      engine.buffer(true);
      async.elapse(const Duration(milliseconds: 500));
      engine.buffer(false);
      for (var i = 0; i < 3; i++) {
        async.elapse(const Duration(seconds: 10));
        engine.buffer(true);
        async.elapse(const Duration(seconds: 2));
        engine.buffer(false);
      }
      settle(async);
      expect(maxBitrateOf(server.requestsTo('/Items/ep1/PlaybackInfo').last), 20000000);
      expect(c.qualityLabel, 'Auto · 20 Mbps');
      expect(notices.single, contains('20 Mbps'));
      expect(c.quality, StreamQuality.auto, reason: 'still Auto, just lower');
    });
  });

  test("auto: one long stall steps down; a seek's loading never does", () {
    fakeAsync((async) {
      final clock = async.getClock(DateTime(2026, 11, 12));
      final c = build(_routes(), now: clock.now);
      loadIn(async, c);
      engine.buffer(true);
      engine.buffer(false);

      unawaited(engine.seek(const Duration(minutes: 12)));
      engine.buffer(true);
      async.elapse(const Duration(seconds: 8));
      engine.buffer(false);
      expect(server.requestsTo('/Items/ep1/PlaybackInfo'), hasLength(1));

      async.elapse(const Duration(seconds: 30));
      engine.buffer(true);
      async.elapse(const Duration(seconds: 7));
      settle(async);
      expect(server.requestsTo('/Items/ep1/PlaybackInfo'), hasLength(2));
      expect(c.qualityLabel, 'Auto · 20 Mbps');
    });
  });

  test('a fixed quality never steps down', () {
    fakeAsync((async) {
      final clock = async.getClock(DateTime(2026, 11, 12));
      final c = build(_routes(), quality: StreamQuality.original, now: clock.now);
      loadIn(async, c);
      engine.buffer(true);
      engine.buffer(false);
      engine.buffer(true);
      async.elapse(const Duration(seconds: 20));
      settle(async);
      expect(server.requestsTo('/Items/ep1/PlaybackInfo'), hasLength(1));
    });
  });

  test('without segments, up next shows in the last 30 seconds', () {
    fakeAsync((async) {
      final c = build(_routes(withSegments: false));
      loadIn(async, c);

      engine.moveTo(const Duration(minutes: 23, seconds: 20));
      expect(c.upNextCountdown, isNull);
      engine.moveTo(const Duration(minutes: 23, seconds: 31));
      expect(c.upNextCountdown, isNotNull);
    });
  });

  test('no up next for the last episode', () {
    fakeAsync((async) {
      final c = build(_routes(withNext: false));
      loadIn(async, c);
      expect(c.nextEpisode, isNull);
      engine.moveTo(const Duration(minutes: 23));
      expect(c.upNextCountdown, isNull);
    });
  });

  test('stop reports the final position and releases the engine', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      engine.position = const Duration(minutes: 20);

      c.stop();
      settle(async);
      c.stop();
      settle(async);

      final stopped = server.requestsTo('/Sessions/Playing/Stopped');
      expect(stopped, hasLength(1));
      expect((stopped.single.data as Map)['PositionTicks'], 20 * _minute);
      expect(engine.disposed, isTrue);

      // No more progress reports after stopping.
      final before = server.requestsTo('/Sessions/Playing/Progress').length;
      async.elapse(const Duration(seconds: 30));
      expect(server.requestsTo('/Sessions/Playing/Progress').length, before);
    });
  });

  group('a watched episode', () {
    Iterable<String> marks() => server.requestsTo('/UserPlayedItems/ep1').map((r) => r.method);

    test('stays watched when stopped part-way, after the report', () {
      fakeAsync((async) {
        final c = build(_routes(played: true));
        loadIn(async, c);
        engine.position = const Duration(minutes: 3);
        c.stop();
        settle(async);
        expect(server.requestsTo('/Sessions/Playing/Stopped'), hasLength(1));
        expect(marks(), ['POST']);
      });
    });

    test('an unwatched one stopped part-way is left alone', () {
      fakeAsync((async) {
        final c = build(_routes());
        loadIn(async, c);
        engine.position = const Duration(minutes: 3);
        c.stop();
        settle(async);
        expect(marks(), isEmpty);
      });
    });
  });

  test('a refused stream shows an error and never opens the engine', () {
    fakeAsync((async) {
      final c = build(_routes(errorCode: 'NoCompatibleStream'));
      loadIn(async, c);
      expect(c.error, contains('no playable stream'));
      expect(engine.openedUrl, isNull);
      expect(c.loading, isFalse);
    });
  });

  test('engine errors are surfaced', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      engine.fail('Failed to open');
      expect(c.error, 'Playback error: Failed to open');
    });
  });

  test('an error says what was playing and how; Retry reopens where it stopped', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      engine.moveTo(const Duration(minutes: 7));
      engine.fail('codec error');
      expect(c.error, 'Playback error: codec error');
      final details = c.errorDetails!;
      expect(details, contains('Item: '));
      expect(details, contains('Position: 0:07:00'));
      expect(details, contains('Playing: '));
      expect(details, contains('Device: '));

      engine.openedStart = null;
      c.retry();
      settle(async);
      expect(c.error, isNull);
      expect(engine.openedStart, const Duration(minutes: 7));
    });
  });

  test('after leaving, nothing reopens the stream (a reconnect, Retry)', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      engine.moveTo(const Duration(minutes: 7));
      c.leave();
      expect(engine.isPlaying, isFalse, reason: 'quiet at once');
      engine.openedStart = null;
      engine.fail('tcp: connection reset');
      async.elapse(const Duration(seconds: 10));
      c.retry();
      settle(async);
      expect(engine.openedStart, isNull, reason: 'not opened again');
    });
  });

  test('reporting failures do not interrupt playback', () {
    fakeAsync((async) {
      final routes = _routes()..['/Sessions/Playing'] = (500, null);
      final c = build(routes);
      loadIn(async, c);
      expect(c.error, isNull);
      expect(c.plan, isNotNull);
    });
  });

  test('previous and next episode come from the series order', () {
    fakeAsync((async) {
      final c = build(_routes(withPrevious: true));
      final requested = <String>[];
      c.nextRequests.listen((e) => requested.add(e.id));
      loadIn(async, c);

      expect(c.previousEpisode?.id, 'ep0');
      expect(c.nextEpisode?.id, 'ep2');
      c.playPrevious();
      settle(async);
      expect(requested, ['ep0']);
      // The whole series is fetched once with minimal fields.
      final query = server.requestsTo('/Shows/ser1/Episodes').single.queryParameters;
      expect(query['fields'], 'ParentId');
      expect(query.containsKey('startItemId'), isFalse);
    });
  });

  test('first episode has no previous', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      expect(c.previousEpisode, isNull);
      c.playPrevious(); // no-op
    });
  });

  test('chapters: next, restart current, previous, with a notice', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      engine.fileChapters = const [
        Chapter(Duration.zero, title: 'Prologue'),
        Chapter(Duration(minutes: 2), title: 'Opening'),
        Chapter(Duration(minutes: 12)),
        Chapter(Duration(minutes: 22), title: 'Ending'),
      ];
      engine.loaded();
      settle(async);
      expect(c.chapters, hasLength(4));

      engine.moveTo(const Duration(minutes: 5));
      expect(c.currentChapter, 1);
      c.seekChapter(forward: true);
      settle(async);
      expect(engine.position, const Duration(minutes: 12));
      expect(c.currentChapter, 2);
      expect(c.chapterNotice, 2);
      expect(c.chapterLabel(2), 'Chapter 3', reason: 'untitled');
      async.elapse(const Duration(seconds: 3));
      expect(c.chapterNotice, isNull, reason: 'notice hides itself');

      // Just after a chapter start: previous goes to the one before.
      engine.moveTo(const Duration(minutes: 12, seconds: 1));
      c.seekChapter(forward: false);
      settle(async);
      expect(engine.position, const Duration(minutes: 2));
      expect(c.chapterLabel(c.chapterNotice!), 'Opening');

      // Well into a chapter: previous restarts it.
      engine.moveTo(const Duration(minutes: 8));
      c.seekChapter(forward: false);
      settle(async);
      expect(engine.position, const Duration(minutes: 2));

      // Past the last chapter start, next does nothing.
      engine.moveTo(const Duration(minutes: 23));
      engine.seeks.clear();
      c.seekChapter(forward: true);
      settle(async);
      expect(engine.seeks, isEmpty);
    });
  });

  test('next / previous: chapters first, then episodes at the ends', () {
    fakeAsync((async) {
      final c = build(_routes(withPrevious: true));
      final requested = <String>[];
      c.nextRequests.listen((e) => requested.add(e.id));
      loadIn(async, c);
      engine.fileChapters = const [Chapter(Duration.zero), Chapter(Duration(minutes: 2)), Chapter(Duration(minutes: 22))];
      engine.loaded();
      settle(async);

      // Mid-episode: chapters.
      engine.moveTo(const Duration(minutes: 5));
      expect((c.skipForwardLabel, c.skipBackLabel), ('Next chapter', 'Previous chapter'));
      c.skipForward();
      settle(async);
      expect(engine.position, const Duration(minutes: 22));

      // In the last chapter: the next episode.
      expect(c.skipForwardLabel, 'Next episode');
      c.skipForward();
      settle(async);
      expect(requested, ['ep2']);

      // At the start of the first chapter: the previous episode.
      unawaited(engine.seek(const Duration(seconds: 1)));
      expect(c.skipBackLabel, 'Previous episode');
      c.skipBack();
      settle(async);
      expect(requested, ['ep2', 'ep0']);
    });
  });

  test('next / previous without chapters: episodes', () {
    fakeAsync((async) {
      final c = build(_routes(withPrevious: true));
      final requested = <String>[];
      c.nextRequests.listen((e) => requested.add(e.id));
      loadIn(async, c);
      engine.loaded();
      settle(async);
      engine.moveTo(const Duration(minutes: 5));
      c.skipForward();
      c.skipBack();
      settle(async);
      expect(requested, ['ep2', 'ep0']);
    });
  });

  test("the player's own jumps go through seekVia (watch together)", () {
    fakeAsync((async) {
      final c = build(_routes());
      final via = <Duration>[];
      c.seekVia = (t) async => via.add(t);
      loadIn(async, c);
      engine.fileChapters = const [Chapter(Duration.zero), Chapter(Duration(minutes: 2))];
      engine.loaded();
      settle(async);
      engine.seeks.clear();
      c.skipForward();
      settle(async);
      expect(via, [const Duration(minutes: 2)]);
      expect(engine.seeks, isEmpty, reason: 'the group seeks, not this player alone');
    });
  });

  test("Jellyfin's chapters until the file reports its own", () {
    fakeAsync((async) {
      final c = build(_routes(jellyfinChapterMinutes: [0, 3, 13]));
      loadIn(async, c);
      expect(c.chapters.map((ch) => ch.start.inMinutes), [0, 3, 13]);

      engine.moveTo(const Duration(minutes: 4));
      c.seekChapter(forward: true);
      settle(async);
      expect(engine.position, const Duration(minutes: 13));

      engine.fileChapters = const [Chapter(Duration.zero), Chapter(Duration(minutes: 7))];
      engine.loaded();
      settle(async);
      expect(c.chapters.map((ch) => ch.start.inMinutes), [0, 7]);
    });
  });

  test('no chapters anywhere: chapter keys do nothing', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      engine.loaded();
      settle(async);
      engine.moveTo(const Duration(minutes: 4));
      engine.seeks.clear();
      c.seekChapter(forward: true);
      c.seekChapter(forward: false);
      settle(async);
      expect(engine.seeks, isEmpty);
      expect(c.currentChapter, isNull);
      expect(c.chapterNotice, isNull);
    });
  });

  test('a converted stream gets its text subtitles separately', () {
    fakeAsync((async) {
      final routes = _routes();
      routes['/Items/ep1/PlaybackInfo'] = (
        200,
        {
          'PlaySessionId': 'ps1',
          'MediaSources': [
            {
              'Id': 'src1',
              'SupportsDirectPlay': false,
              'SupportsDirectStream': false,
              'SupportsTranscoding': true,
              'TranscodingUrl': '/videos/ep1/master.m3u8?MediaSourceId=src1',
              'MediaStreams': [
                {'Index': 0, 'Type': 'Video', 'Codec': 'h264'},
                {'Index': 1, 'Type': 'Audio', 'Language': 'jpn'},
                {'Index': 2, 'Type': 'Subtitle', 'Codec': 'ass', 'Language': 'eng'},
                {'Index': 3, 'Type': 'Subtitle', 'Codec': 'subrip', 'Language': 'spa'},
                {'Index': 4, 'Type': 'Subtitle', 'Codec': 'PGSSUB', 'Language': 'fre'},
              ],
            },
          ],
        },
      );
      final c = build(routes, quality: StreamQuality.mbps4);
      loadIn(async, c);
      expect(c.plan?.method, PlayMethod.transcode);
      expect([for (final u in engine.addedSubtitles) u.path], [
        '/Videos/ep1/src1/Subtitles/2/0/Stream.ass',
        '/Videos/ep1/src1/Subtitles/3/0/Stream.srt',
      ], reason: 'pictures (PGS) cannot come separately');
    });
  });

  test('a picture subtitle can be burned into a converted stream', () {
    fakeAsync((async) {
      final routes = _routes();
      routes['/Items/ep1/PlaybackInfo'] = (
        200,
        {
          'PlaySessionId': 'ps1',
          'MediaSources': [
            {
              'Id': 'src1',
              'SupportsDirectPlay': false,
              'SupportsTranscoding': true,
              'TranscodingUrl': '/videos/ep1/master.m3u8?MediaSourceId=src1',
              'MediaStreams': [
                {'Index': 0, 'Type': 'Video', 'Codec': 'h264'},
                {'Index': 2, 'Type': 'Subtitle', 'Codec': 'ass', 'Language': 'eng'},
                {'Index': 4, 'Type': 'Subtitle', 'Codec': 'PGSSUB', 'Language': 'eng'},
              ],
            },
          ],
        },
      );
      final c = build(routes, quality: StreamQuality.mbps4);
      loadIn(async, c);
      expect([for (final s in c.burnable) s.index], [4]);
      expect(engine.subtitlesOff, isFalse);

      engine.moveTo(const Duration(minutes: 8));
      unawaited(c.setBurnIn(4));
      settle(async);
      final body = server.requestsTo('/Items/ep1/PlaybackInfo').last.data as Map;
      expect(body['SubtitleStreamIndex'], 4);
      final profiles = (body['DeviceProfile'] as Map)['SubtitleProfiles'] as List;
      expect(profiles, anyElement(equals({'Format': 'pgssub', 'Method': 'Encode'})));
      expect(profiles, isNot(anyElement(equals({'Format': 'pgssub', 'Method': 'Embed'}))));
      expect(c.burnedIn, 4);
      expect(engine.subtitlesOff, isTrue, reason: 'no second set over the burned-in one');
      expect(engine.openedStart, const Duration(minutes: 8));

      unawaited(c.setBurnIn(null));
      settle(async);
      final back = server.requestsTo('/Items/ep1/PlaybackInfo').last.data as Map;
      expect(back['SubtitleStreamIndex'], isNull);
      expect(engine.subtitlesOff, isFalse);
    });
  });

  test('played as it is, nothing is burned in', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      expect(c.plan?.method, PlayMethod.directPlay);
      expect(c.burnable, isEmpty, reason: 'the file shows its picture subtitles itself');
    });
  });

  test('played from a playlist, next and previous follow the playlist', () {
    fakeAsync((async) {
      final routes = _routes()
        ..['/Playlists/pl1/Items'] = (
          200,
          pageJson([
            itemJson('m7', 'A film', type: 'Movie'),
            itemJson('ep1', 'Episode 1', type: 'Episode'),
            itemJson('x9', 'Another show', type: 'Episode'),
          ]),
        );
      final c = build(routes, playlistId: 'pl1');
      loadIn(async, c);
      expect(c.previousEpisode?.id, 'm7');
      expect(c.nextEpisode?.id, 'x9');
    });
  });
  test('a dropped connection reopens the stream where it was', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      engine.moveTo(const Duration(minutes: 9, seconds: 30));

      // What mpv reports when the server closed the idle connection.
      engine.fail('tcp: ffurl_read returned 0xdfb9b0bb');
      async.elapse(const Duration(seconds: 4));

      expect(c.error, isNull);
      expect(engine.opens, 2);
      expect(engine.openedStart, const Duration(minutes: 9, seconds: 30));
      // External subtitles come back with the reopened stream.
      expect(engine.addedSubtitles, hasLength(2));
    });
  });

  test('repeated network failures give up and show the error', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      for (var i = 0; i < 3; i++) {
        engine.fail('http: Connection reset by peer');
        async.elapse(const Duration(seconds: 4));
      }
      expect(c.error, isNull);
      engine.fail('http: Connection reset by peer');
      async.elapse(const Duration(seconds: 4));
      expect(c.error, contains('Connection reset'));
      expect(engine.opens, 4);
    });
  });

  test('failures spread out over time keep recovering', () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      for (var i = 0; i < 5; i++) {
        engine.fail('tcp: ffurl_read returned 0xdfb9b0bb');
        async.elapse(const Duration(minutes: 2));
      }
      expect(c.error, isNull);
      expect(engine.opens, 6);
    });
  });

  test('a "finished" far from the end does not start the next episode', () {
    fakeAsync((async) {
      final c = build(_routes());
      final requested = <String>[];
      c.nextRequests.listen((e) => requested.add(e.id));
      loadIn(async, c);

      engine.moveTo(const Duration(minutes: 10));
      engine.complete();
      settle(async);
      expect(requested, isEmpty);

      engine.moveTo(const Duration(minutes: 23, seconds: 50));
      engine.complete();
      settle(async);
      expect(requested, ['ep2']);
    });
  });

  test("no reopen when FFmpeg's reconnect gets playback moving again", () {
    fakeAsync((async) {
      final c = build(_routes());
      loadIn(async, c);
      engine.moveTo(const Duration(minutes: 5));
      engine.fail('tcp: ffurl_read returned 0xdfb9b0bb');
      async.elapse(const Duration(seconds: 1));
      engine.moveTo(const Duration(minutes: 5, seconds: 1)); // playing again
      async.elapse(const Duration(seconds: 3));
      expect(engine.opens, 1);
      expect(c.error, isNull);
    });
  });

  test('AniSkip-style fallback fills in only when the server has no segments', () {
    fakeAsync((async) {
      const aniSkip = [
        MediaSegment(type: SegmentType.intro, start: Duration(seconds: 3), end: Duration(seconds: 93)),
      ];
      var asked = 0;
      final c = build(_routes(withSegments: false), fallbackSegments: (_) async {
        asked++;
        return aniSkip;
      });
      loadIn(async, c);
      expect(asked, 1);
      expect(c.segmentsFromFallback, isTrue);
      engine.moveTo(const Duration(seconds: 10));
      expect(c.activeSegment?.type, SegmentType.intro);

      final withServer = build(_routes(), fallbackSegments: (_) async {
        asked++;
        return aniSkip;
      });
      loadIn(async, withServer);
      expect(asked, 1, reason: "server segments win; AniSkip isn't asked");
      expect(withServer.segmentsFromFallback, isFalse);
    });
  });

  test('"AniSkip first" uses AniSkip over server segments, server when AniSkip has none', () {
    fakeAsync((async) {
      const aniSkip = [
        MediaSegment(type: SegmentType.intro, start: Duration(seconds: 3), end: Duration(seconds: 93)),
      ];
      final first = build(_routes(), fallbackSegments: (_) async => aniSkip, preferFallbackSegments: () async => true);
      loadIn(async, first);
      expect(first.segmentsFromFallback, isTrue);
      expect(first.segments, aniSkip);

      final none = build(_routes(), fallbackSegments: (_) async => const [], preferFallbackSegments: () async => true);
      loadIn(async, none);
      expect(none.segmentsFromFallback, isFalse);
      expect(none.segments, isNotEmpty, reason: "the server's segments fill in");
    });
  });

  test("a show's track choice goes before the defaults", () {
    fakeAsync((async) {
      final c = build(
        _routes(),
        trackChoiceFor: (item) => item.seriesId == 'ser1'
            ? const SeriesTrackChoice(audio: 'eng', subtitlesOff: true)
            : null,
      );
      loadIn(async, c);
      expect(engine.audioLanguages, 'eng,jpn,ja');
      expect(engine.subtitleLanguages, 'eng,en');
      expect(engine.subtitlesOff, isTrue);
    });
  });
}
