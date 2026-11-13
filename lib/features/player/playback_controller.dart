import 'dart:async';

import 'package:flutter/foundation.dart';

import 'playback_log.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../../core/jellyfin/library_api.dart';
import '../../core/jellyfin/playback_api.dart';
import '../settings/series_tracks.dart';
import '../settings/playback_settings.dart';
import 'media_engine.dart';

/// Runs one playback session: negotiates the stream with the server, drives
/// the [MediaEngine], reports progress, and decides when to offer
/// "Skip intro" and "Up next".
class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.engine,
    required this.playback,
    required this.library,
    required this.settings,
    required this.authorizationHeader,
    this.progressInterval = const Duration(seconds: 10),
    this.upNextLeadTime = const Duration(seconds: 30),
    this.chapterRestartThreshold = const Duration(seconds: 3),
    this.maxRecoveries = 3,
    this.recoveryWindow = const Duration(minutes: 1),
    this.recoveryGrace = const Duration(seconds: 3),
    this.fallbackSegments,
    this.preferFallbackSegments,
    this.trackChoiceFor,
    this.localCopy,
    this.onUnreportedStop,
    this.onReportedAgain,
    this.onNotice,
    this.playlistId,
    this.onLongWait,
    this.shortStall = const Duration(milliseconds: 1500),
    this.longStall = const Duration(seconds: 6),
    this.stallWindow = const Duration(seconds: 90),
    this.stallsToStepDown = 3,
    this.now = DateTime.now,
  }) : quality = _picked ?? settings.defaultQuality;

  final MediaEngine engine;

  /// The server, at the address in use: replaced by [moveTo] when the app
  /// switches to another of its addresses.
  PlaybackApi playback;

  /// Called when the stream has kept the player waiting for [longStall]
  /// (whatever the quality): the server's address may have stopped
  /// answering (left home, say).
  final void Function()? onLongWait;

  /// The playlist this was played from: next and previous follow it.
  final String? playlistId;

  /// Something to tell the user (Auto lowering the quality).
  final void Function(String message)? onNotice;

  /// Auto: a wait for the stream shorter than [shortStall] is a hiccup; one
  /// longer than [longStall], or [stallsToStepDown] in [stallWindow], steps
  /// the quality down.
  final Duration shortStall;
  final Duration longStall;
  final Duration stallWindow;
  final int stallsToStepDown;

  /// The time (tests set their own).
  final DateTime Function() now;

  /// The quality picked (Auto unless the user chose one).
  StreamQuality quality;

  /// The quality picked in the player, for the next episode too, until the
  /// app closes; then the default from Settings applies again, so a low
  /// quality picked for a slow evening isn't left behind. Null: none picked.
  static StreamQuality? _picked;

  /// Under Auto, the level it has stepped down to. Kept for the next
  /// episode in this run of the app: the connection is likely the same.
  static StreamQuality? _autoLevel;

  /// A fresh start, as when the app opens: nothing picked (or [picked]),
  /// not stepped down.
  @visibleForTesting
  static void forgetAutoLevel({StreamQuality? picked}) {
    _autoLevel = null;
    _picked = picked;
  }

  /// What the stream is held to now.
  StreamQuality get effectiveQuality =>
      quality == StreamQuality.auto ? (_autoLevel ?? StreamQuality.original) : quality;

  /// "Auto · 10 Mbps" once Auto has stepped down; else the quality's name.
  String get qualityLabel => quality == StreamQuality.auto && _autoLevel != null
      ? 'Auto · ${_autoLevel!.label}'
      : quality.label;

  int get _maxBitrate => effectiveQuality.bitrate ?? 200000000;

  /// Segments from elsewhere (AniSkip) when the server has none.
  final Future<List<MediaSegment>> Function(BaseItem item)? fallbackSegments;

  /// True = ask [fallbackSegments] first and use the server's segments only
  /// when it has none (the "AniSkip first" setting).
  final Future<bool> Function()? preferFallbackSegments;

  /// A downloaded copy of an item (its file, and the item as saved), played
  /// instead of the stream, and without the server when it's unreachable.
  final ({String path, Map<String, dynamic> item})? Function(String itemId)? localCopy;

  /// A position couldn't be reported (offline): keep it to sync later. Called
  /// as playback goes, each call replacing the last, and on stopping.
  final void Function(String itemId, Duration position, bool finished)? onUnreportedStop;

  /// The server took a report again after positions were kept for later:
  /// the kept one is stale.
  final void Function(String itemId)? onReportedAgain;

  /// The user's audio/subtitle choice for the item's show, if any.
  final SeriesTrackChoice? Function(BaseItem item)? trackChoiceFor;

  /// True when [segments] came from [fallbackSegments].
  bool segmentsFromFallback = false;

  /// How the player's own jumps (skip intro, chapters) seek: the player
  /// sets this to go through a watch-together group when in one.
  Future<void> Function(Duration target)? seekVia;

  Future<void> _seek(Duration target) => (seekVia ?? engine.seek)(target);
  LibraryApi library;
  final PlaybackSettings settings;
  final String authorizationHeader;
  final Duration progressInterval;

  /// Show "Up next" this long before the end.
  final Duration upNextLeadTime;

  /// "Previous chapter" further than this into a chapter restarts it.
  final Duration chapterRestartThreshold;

  /// Network errors are recovered by reopening the stream where it was;
  /// after this many within [recoveryWindow], the error is shown instead.
  final int maxRecoveries;
  final Duration recoveryWindow;

  /// How long FFmpeg gets to reconnect by itself before the stream is
  /// reopened (which resets hand-picked tracks to the language defaults).
  final Duration recoveryGrace;
  int _recentRecoveries = 0;
  final _recoveryTimers = <Timer>[];
  bool _recovering = false;

  BaseItem? item;
  PlaybackPlan? plan;
  List<MediaSegment> segments = const [];
  BaseItem? nextEpisode;
  BaseItem? previousEpisode;
  String? error;

  /// With [error]: what was playing, where, and how, to copy into a report.
  String? errorDetails;

  /// What's playing and how: for error details and the playback log.
  String describePlayback() {
    final item = this.item;
    final plan = this.plan;
    final video = plan?.source.streamsOfType('Video').firstOrNull;
    final audio = plan?.source.streamsOfType('Audio').firstOrNull;
    return [
      if (item != null)
        'Item: ${[item.seriesName, item.episodeLabel, item.name].nonNulls.join(' · ')} (${item.id})',
      'Position: ${engine.position.toString().split('.').first} of ${engine.duration.toString().split('.').first}',
      if (plan != null) ...[
        'Playing: ${plan.method.name}${plan.transcodeReasons.isEmpty ? '' : ' (${plan.transcodeReasons.join(', ')})'}',
        'File: ${plan.source.container ?? '?'}'
            '${video == null ? '' : ', video ${video.codec ?? '?'} ${video.width ?? '?'}x${video.height ?? '?'}${video.videoRange == null ? '' : ' ${video.videoRange}'}'}'
            '${audio == null ? '' : ', audio ${audio.codec ?? '?'}${audio.channels == null ? '' : ' ${audio.channels} ch'}'}',
      ],
      'Device: ${defaultTargetPlatform.name}',
    ].join('\n');
  }

  void _fail(String message) {
    error = message;
    errorDetails = '$message\n${describePlayback()}';
    PlaybackLog.add('Error: $message');
    notifyListeners();
  }

  /// After an error: reopens the stream where it stopped.
  Future<void> retry() async {
    final plan = this.plan;
    if (plan == null || _stopped) return;
    final position = engine.position;
    error = errorDetails = null;
    notifyListeners();
    PlaybackLog.add('Retry at $position');
    try {
      await _openStream(plan, position);
    } on Object catch (e) {
      _fail('Playback error: $e');
    }
  }
  bool get loading => plan == null && error == null;

  /// The skippable segment under the playhead, if any.
  MediaSegment? activeSegment;

  /// Seconds left on the "Up next" countdown, or null when it's hidden.
  int? upNextCountdown;

  /// Fires with the episode to switch to when the user (or the countdown)
  /// asks for the next or previous one. The screen handles navigation.
  final _nextRequests = StreamController<BaseItem>.broadcast();
  Stream<BaseItem> get nextRequests => _nextRequests.stream;

  final _subscriptions = <StreamSubscription<Object?>>[];
  final _autoSkipped = <MediaSegment>{};

  /// The file's chapters (from mpv), else Jellyfin's; sorted by start.
  List<Chapter> chapters = const [];

  /// Index into [chapters] of the chapter under the playhead.
  int? currentChapter;

  /// Shown briefly after a chapter jump: the index jumped to.
  int? chapterNotice;
  Timer? _chapterNoticeTimer;
  bool _fileChaptersLoaded = false;
  Timer? _progressTimer;
  bool _upNextDismissed = false;
  bool _nextRequested = false;
  bool _started = false;
  bool _stopped = false;

  Future<void> load(String itemId, {bool fromStart = false}) async {
    try {
      final local = localCopy?.call(itemId);
      BaseItem item;
      try {
        item = this.item = await library.getItem(itemId);
      } on JellyfinException {
        // Offline: a downloaded item plays from what was saved with it.
        if (local == null) rethrow;
        item = this.item = BaseItem.fromJson(local.item);
      }
      final start = !fromStart && item.userData.hasProgress
          ? ticksToDuration(item.userData.playbackPositionTicks)
          : Duration.zero;

      final PlaybackPlan plan;
      if (local != null) {
        // The downloaded file: no stream, no transcoding.
        final sources = item.raw['MediaSources'];
        plan = PlaybackPlan(
          itemId: itemId,
          source: sources is List && sources.isNotEmpty
              ? MediaSource.fromJson((sources.first as Map).cast<String, dynamic>())
              : MediaSource(id: itemId),
          method: PlayMethod.directPlay,
          url: Uri.file(local.path),
          playSessionId: null,
        );
      } else {
        final info = await playback.getPlaybackInfo(itemId, start: start, maxBitrate: _maxBitrate);
        plan = playback.plan(itemId, info);
      }
      if (_stopped) return;

      final choice = trackChoiceFor?.call(item);
      await engine.setLanguagePreferences(
        audio: SeriesTrackChoice.prefer(choice?.audio, settings.audioLanguages),
        subtitles: SeriesTrackChoice.prefer(choice?.subtitle, settings.subtitleLanguages),
        subtitlesOff: choice?.subtitlesOff ?? false,
      );
      _listen();
      openedAt = start;
      await _openStream(plan, start);
      this.plan = plan;
      _setChapters(_jellyfinChapters(item));
      notifyListeners();

      await _report(() => playback.reportStart(plan, start));
      _started = true;
      _progressTimer = Timer.periodic(progressInterval, (_) => _reportProgress());

      // Nice-to-haves: failures here must not stop playback.
      final fallbackFirst = fallbackSegments != null && (await preferFallbackSegments?.call() ?? false);
      if (fallbackFirst) segments = await _fallbackSegments(item);
      if (segments.isEmpty) segments = await playback.getSegments(itemId);
      if (segments.isEmpty && !fallbackFirst) segments = await _fallbackSegments(item);
      final (previous, next) = await _findNeighbours(item);
      previousEpisode = previous;
      nextEpisode = next;
      notifyListeners();
    } on JellyfinException catch (e) {
      _fail(e.message);
    }
  }

  /// Segments from [fallbackSegments] (none on failure); notes the source.
  Future<List<MediaSegment>> _fallbackSegments(BaseItem item) async {
    final source = fallbackSegments;
    if (source == null) return const [];
    try {
      final found = await source(item);
      segmentsFromFallback = found.isNotEmpty;
      return found;
    } on Object catch (e) {
      debugPrint('Fallback segments: $e');
      return const [];
    }
  }

  /// Where playback was opened (the resume point, or 0:00): the player's
  /// position reads 0 for a moment before it gets there.
  Duration openedAt = Duration.zero;

  /// Where playback is, or for a stream just opened, where it opens.
  Duration get currentPosition {
    final p = engine.position;
    return p < const Duration(seconds: 1) && openedAt > const Duration(seconds: 1) ? openedAt : p;
  }

  /// The user left the player (it's closing): nothing may open the stream
  /// again (an automatic reconnect, Retry), and it goes quiet now.
  bool _leaving = false;

  void leave() {
    _leaving = true;
    unawaited(engine.pause().catchError((Object _) {}));
  }

  Future<void> _openStream(PlaybackPlan plan, Duration start) async {
    if (_leaving) return;
    PlaybackLog.add('Open ${plan.itemId} at $start (${plan.method.name})');
    await engine.open(
      plan.url,
      headers: {'Authorization': authorizationHeader},
      start: start,
    );
    // Direct play has the file's own subtitle tracks; sidecar files come
    // separately. A converted stream carries no subtitles at all, so every
    // text one comes separately then, from the server (picture subtitles
    // can't be handed over that way).
    final converted = plan.method == PlayMethod.transcode;
    for (final sub in plan.source.streamsOfType('Subtitle')) {
      final sidecar = sub.isExternal || sub.deliveryMethod == 'External';
      if (!(converted ? sub.isTextSubtitle : sidecar)) continue;
      await engine.addSubtitle(
        playback.subtitleUrl(plan, sub),
        title: sub.displayTitle ?? sub.title,
        language: sub.language,
      );
    }
  }

  /// Errors from the network rather than the file: connections the server
  /// or proxy closed (e.g. after a long pause), resets, timeouts.
  static final _networkError = RegExp(
    r'tcp|http|tls|ffurl|connection|reset|timed? ?out|end of file|eof|'
    r'network|socket|stream ends prematurely',
    caseSensitive: false,
  );

  void _onEngineError(String message) {
    if (_leaving) return;
    final plan = this.plan;
    if (plan != null && !_stopped && _networkError.hasMatch(message)) {
      // The server's address may have stopped answering.
      onLongWait?.call();
      if (_recentRecoveries < maxRecoveries) {
        // Each recovery counts against the limit for recoveryWindow.
        _recentRecoveries++;
        _recoveryTimers.add(Timer(recoveryWindow, () => _recentRecoveries--));
        _recover(plan, message);
        return;
      }
    }
    _fail('Playback error: $message');
  }

  /// Reopens the stream where it stopped, unless FFmpeg's own reconnect
  /// gets playback moving again within [recoveryGrace].
  Future<void> _recover(PlaybackPlan plan, String message) async {
    if (_recovering || _leaving) return;
    PlaybackLog.add('Recovering from: $message');
    _recovering = true;
    final position = engine.position;
    debugPrint('Stream error at $position: $message');
    try {
      await Future<void>.delayed(recoveryGrace);
      if (_stopped) return;
      if (engine.position != position) {
        debugPrint('Stream recovered by itself');
        return;
      }
      debugPrint('Stream dropped at $position; reopening');
      await _openStream(plan, position);
    } finally {
      _recovering = false;
    }
  }

  /// The episodes before and after [item] in the series, across seasons.
  Future<(BaseItem?, BaseItem?)> _findNeighbours(BaseItem item) async {
    // Played from a playlist: next and previous follow the playlist.
    if (playlistId case final playlist?) {
      try {
        final entries = await library.getPlaylistItems(playlist);
        final i = entries.indexWhere((e) => e.id == item.id);
        if (i >= 0) {
          return (i > 0 ? entries[i - 1] : null, i + 1 < entries.length ? entries[i + 1] : null);
        }
      } on JellyfinException {
        // The show's order below, then.
      }
    }
    final seriesId = item.seriesId;
    if (item.type != ItemType.episode || seriesId == null) return (null, null);
    try {
      // The whole series in order; fields kept minimal as it can be long.
      final episodes = await library.getEpisodes(seriesId, fields: 'ParentId');
      final i = episodes.indexWhere((e) => e.id == item.id);
      if (i < 0) return (null, null);
      return (
        i > 0 ? episodes[i - 1] : null,
        i + 1 < episodes.length ? episodes[i + 1] : null,
      );
    } on JellyfinException {
      return (null, null);
    }
  }

  void _listen() {
    _subscriptions
      ..add(engine.positionStream.listen(_onPosition))
      ..add(engine.durationStream.listen((d) {
        // mpv knows the file's chapters once it has loaded it.
        if (d > Duration.zero && !_fileChaptersLoaded) {
          _fileChaptersLoaded = true;
          _loadFileChapters();
        }
      }))
      ..add(engine.playingStream.listen((_) => _reportProgress()))
      ..add(engine.completedStream.listen((done) {
        if (done && _reachedEnd && nextEpisode != null && settings.autoPlayNext) {
          playNext();
        }
      }))
      ..add(engine.errorStream.listen(_onEngineError))
      ..add(engine.bufferingStream.listen(_onBuffering));
  }

  /// Picks the quality: the stream starts again at the same place.
  Future<void> setQuality(StreamQuality picked) async {
    PlaybackLog.add('Quality picked: ${picked.label}');
    quality = picked;
    _autoLevel = null;
    _stalls.clear();
    _picked = picked;
    notifyListeners();
    await _replan();
  }

  /// The picture subtitle (PGS, DVD) drawn into a converted stream, by its
  /// stream index; null when none is.
  int? burnedIn;

  /// Picture subtitles that can be burned in: only while the stream is
  /// converted (played as it is, the file shows them itself).
  List<MediaStream> get burnable {
    final plan = this.plan;
    if (plan == null || plan.method != PlayMethod.transcode) return const [];
    return [for (final s in plan.source.streamsOfType('Subtitle')) if (!s.isTextSubtitle) s];
  }

  /// Draws picture subtitle [index] into the stream (null: none): the
  /// stream starts again at the same place.
  Future<void> setBurnIn(int? index) async {
    if (index == burnedIn) return;
    PlaybackLog.add(index == null ? 'Burned-in subtitle off' : 'Burn in subtitle $index');
    burnedIn = index;
    notifyListeners();
    await _replan();
  }

  /// The app switched to another of the server's addresses (the one in use
  /// stopped answering): the stream reopens from there, where it was.
  Future<void> moveTo({required PlaybackApi playback, required LibraryApi library}) async {
    this.playback = playback;
    this.library = library;
    if (plan == null || _leaving || _stopped) return;
    PlaybackLog.add('Server address changed: reopening the stream from there');
    // The waits were the old address going away, not the connection being
    // slow: Auto starts again from the top.
    if (quality == StreamQuality.auto) _autoLevel = null;
    _stalls.clear();
    error = errorDetails = null;
    notifyListeners();
    await _replan();
  }

  /// Asks the server again for the item at [effectiveQuality] and reopens
  /// the stream where it is.
  Future<void> _replan() async {
    final old = plan;
    final item = this.item;
    if (old == null || item == null || _leaving || _stopped) return;
    // A downloaded file plays as it is.
    if (localCopy?.call(item.id) != null) return;
    final position = currentPosition;
    try {
      final burn = burnedIn;
      final info = await playback.getPlaybackInfo(
        old.itemId,
        start: position,
        maxBitrate: _maxBitrate,
        subtitleStreamIndex: burn,
        burnPictureSubtitles: burn != null,
      );
      final next = playback.plan(old.itemId, info);
      if (_leaving || _stopped) return;
      // Played as it is, the file shows its picture subtitles itself.
      if (next.method != PlayMethod.transcode) burnedIn = null;
      PlaybackLog.add('Quality ${effectiveQuality.label}: ${next.method.name}'
          '${burnedIn == null ? '' : ', subtitle $burnedIn burned in'}');
      // The old stream (and any conversion the server runs for it) ends.
      await _report(() => playback.reportStopped(old, position));
      final choice = trackChoiceFor?.call(item);
      await engine.setLanguagePreferences(
        audio: SeriesTrackChoice.prefer(choice?.audio, settings.audioLanguages),
        subtitles: SeriesTrackChoice.prefer(choice?.subtitle, settings.subtitleLanguages),
        // Burned in, they're in the picture: no second set on top.
        subtitlesOff: burnedIn != null || (choice?.subtitlesOff ?? false),
      );
      openedAt = position;
      _calmUntil = now().add(const Duration(seconds: 20));
      plan = next;
      await _openStream(next, position);
      await _report(() => playback.reportStart(next, position));
      notifyListeners();
    } on JellyfinException catch (e) {
      if (e.statusCode == null) {
        // No answer at all: the server's address, not the quality. Asked
        // about; the stream reopens from another address if one answers.
        PlaybackLog.add("Server didn't answer (${e.message}); checking its addresses");
        onLongWait?.call();
        return;
      }
      onNotice?.call("Couldn't change the quality: ${e.message}");
    }
  }

  /// When the current wait for the stream began, if it's waiting.
  DateTime? _stallStart;
  Timer? _stallTimer;
  final _stalls = <DateTime>[];

  /// No stepping down until then (the stream just reopened).
  DateTime _calmUntil = DateTime(0);

  /// The engine's jump count when a wait was last looked at: a wait right
  /// after a seek or an open is loading, not the connection falling behind.
  int _jumpsAtStall = 0;

  Timer? _longWaitTimer;

  void _onBuffering(bool buffering) {
    _longWaitTimer?.cancel();
    if (buffering && onLongWait != null && plan != null && !_leaving && !_stopped &&
        localCopy?.call(plan!.itemId) == null) {
      // Asked again for as long as it waits: after a network change, the
      // other address can take a while to come up (mobile data, a VPN).
      _longWaitTimer = Timer.periodic(longStall, (_) => onLongWait?.call());
    }
    if (quality != StreamQuality.auto || plan == null || _recovering || _leaving || _stopped) return;
    if (localCopy?.call(plan!.itemId) != null) return;
    final at = now();
    if (buffering) {
      if (engine.jumps != _jumpsAtStall) {
        _jumpsAtStall = engine.jumps;
        return;
      }
      if (at.isBefore(_calmUntil)) return;
      _stallStart = at;
      _stallTimer?.cancel();
      _stallTimer = Timer(longStall, _stepDown);
      return;
    }
    _stallTimer?.cancel();
    final began = _stallStart;
    _stallStart = null;
    if (began == null || at.difference(began) < shortStall) return;
    _stalls
      ..add(at)
      ..removeWhere((t) => at.difference(t) > stallWindow);
    if (_stalls.length >= stallsToStepDown) _stepDown();
  }

  /// Auto: one level down, below what the file itself needs.
  void _stepDown() {
    _stallTimer?.cancel();
    _stallStart = null;
    _stalls.clear();
    final cap = effectiveQuality.bitrate;
    final file = plan?.source.bitrate;
    final limit = [?cap, ?file].fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    final next = limit == null ? effectiveQuality.lower : StreamQuality.below(limit);
    if (next == null) return;
    _autoLevel = next;
    PlaybackLog.add('Auto quality: playback kept stalling, down to ${next.label}');
    onNotice?.call('Playback kept pausing to load, so the quality is now ${next.label}');
    notifyListeners();
    unawaited(_replan());
  }

  void _onPosition(Duration position) {
    if (_backFromRestart(position)) return;
    var changed = false;

    final chapter = _chapterAt(position);
    if (chapter != currentChapter) {
      currentChapter = chapter;
      changed = true;
    }

    final postCredits = _postCreditsStart;
    final segment = segments
        .where((s) =>
            s.type != SegmentType.unknown &&
            s.contains(position) &&
            // Credits timings that run over a post-credits scene stop there.
            !(s.type == SegmentType.outro && postCredits != null && position >= postCredits))
        .firstOrNull;
    if (segment != activeSegment) {
      activeSegment = segment;
      changed = true;
      if (segment != null &&
          settings.autoSkipIntro &&
          (segment.type == SegmentType.intro || segment.type == SegmentType.recap) &&
          _autoSkipped.add(segment)) {
        _seek(segment.end);
      }
    }

    // As Jellyfin does: the card counts down the time left in the file, so
    // it follows pauses and seeks, and the next episode starts as it ends.
    final left = _inUpNextZone(position) ? _secondsLeft(position) : null;
    if (left != upNextCountdown) {
      upNextCountdown = left;
      changed = true;
      if (left == 0 && settings.autoPlayNext) playNext();
    }

    if (changed) notifyListeners();
  }

  /// Where playback was at the last position update, and the engine's
  /// jump count then.
  Duration _lastPosition = Duration.zero;
  int _lastJumps = 0;

  /// A stream that drops (the server restarting, say) can come back from
  /// the very start when the player reconnects by itself. Nobody asked for
  /// that jump, so playback goes back to where it was. True when it did.
  bool _backFromRestart(Duration position) {
    final previous = _lastPosition;
    final jumps = engine.jumps;
    final asked = jumps != _lastJumps;
    _lastPosition = position;
    _lastJumps = jumps;
    if (asked || _leaving || _stopped) return false;
    if (previous < restartFrom || position > restartTo) return false;
    PlaybackLog.add('Stream came back at $position, not $previous: back to $previous');
    scheduleMicrotask(() => _seek(previous));
    return true;
  }

  /// Only a fall from this far in counts as the stream restarting…
  static const restartFrom = Duration(minutes: 1);

  /// …to about the start.
  static const restartTo = Duration(seconds: 5);

  /// A dropped connection can also end the file early; only a finish near
  /// the real end counts as the episode being over.
  bool get _reachedEnd {
    if (_recovering) return false;
    final duration = engine.duration;
    return duration <= Duration.zero ||
        duration - engine.position <= upNextLeadTime;
  }

  bool _inUpNextZone(Duration position) {
    if (nextEpisode == null || _upNextDismissed) return false;
    final duration = engine.duration;
    // Only near the end, not as soon as the credits start.
    return duration > Duration.zero &&
        position > Duration.zero &&
        duration - position <= upNextLeadTime;
  }

  /// Whole seconds left in the file, rounded up (0 only at the very end).
  int _secondsLeft(Duration position) {
    final ms = (engine.duration - position).inMilliseconds;
    return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  }

  MediaSegment? get _credits => segments.where((s) => s.type == SegmentType.outro).lastOrNull;

  /// Where a scene after the credits starts: a chapter that begins once the
  /// credits are under way and isn't the credits or a next-episode preview.
  Duration? get _postCreditsStart {
    final credits = _credits;
    if (credits == null) return null;
    final duration = engine.duration;
    // A credits-like name ("Outro") after a chapter already holding the
    // credits ("ED") is the scene after them, not the credits again.
    final atCredits = _chapterAt(credits.start + _creditsChapterSlack);
    var creditsSeen = atCredits != null && _creditsName.hasMatch(chapters[atCredits].title ?? '');
    for (final c in chapters) {
      if (c.start <= credits.start + _creditsChapterSlack) continue;
      if (duration > Duration.zero && duration - c.start < _creditsChapterSlack) continue;
      final title = c.title?.trim() ?? '';
      if (_previewName.hasMatch(title)) continue;
      if (_creditsName.hasMatch(title) && !creditsSeen) {
        creditsSeen = true;
        continue;
      }
      return c.start;
    }
    return null;
  }

  /// Chapter marks and segment timings rarely line up to the second.
  static const _creditsChapterSlack = Duration(seconds: 5);

  /// Chapter names for the credits.
  static final _creditsName = RegExp(r'\b(ending|ed|credits?|outro)\b|エンディング', caseSensitive: false);

  /// Chapter names for a next-episode preview.
  static final _previewName = RegExp(r'\b(preview|next\s*(episode|time|ep))\b|予告|次回', caseSensitive: false);

  /// Jumps past the current intro/recap/credits segment.
  Future<void> skipSegment() async {
    final segment = activeSegment;
    if (segment == null) return;
    final postCredits = _postCreditsStart;
    if (segment.type == SegmentType.outro && postCredits != null) {
      await _seek(postCredits);
      return;
    }
    // Skipping credits with a next episode means "play next".
    if (segment.type == SegmentType.outro && nextEpisode != null) {
      playNext();
      return;
    }
    await _seek(segment.end);
  }

  void playNext() {
    final next = nextEpisode;
    // Once: the countdown reaching 0 and the file ending both ask.
    if (next == null || _nextRequests.isClosed || _nextRequested) return;
    _nextRequested = true;
    upNextCountdown = null;
    _upNextDismissed = true;
    _nextRequests.add(next);
  }

  void playPrevious() {
    final previous = previousEpisode;
    if (previous == null || _nextRequests.isClosed) return;
    upNextCountdown = null;
    _nextRequests.add(previous);
  }

  static List<Chapter> _jellyfinChapters(BaseItem item) => [
        for (final c in (item.raw['Chapters'] as List?) ?? const [])
          if (c case {'StartPositionTicks': final int ticks})
            Chapter(ticksToDuration(ticks), title: c['Name'] as String?),
      ];

  Future<void> _loadFileChapters() async {
    final fromFile = await engine.chapters();
    if (fromFile.isEmpty || _stopped) return;
    _setChapters(fromFile);
    notifyListeners();
  }

  void _setChapters(List<Chapter> list) {
    chapters = [...list]..sort((a, b) => a.start.compareTo(b.start));
    currentChapter = _chapterAt(engine.position);
  }

  int? _chapterAt(Duration position) {
    for (var i = chapters.length - 1; i >= 0; i--) {
      if (chapters[i].start <= position) return i;
    }
    return null;
  }

  /// Jumps to the next chapter, or back like most players: to the start of
  /// the current chapter, or the one before when already near its start.
  Future<void> seekChapter({required bool forward}) async {
    if (chapters.isEmpty) return;
    final position = engine.position;
    final current = _chapterAt(position);
    final int target;
    if (forward) {
      // A little slack so a seek that landed just short doesn't repeat.
      final next = chapters.indexWhere(
        (c) => c.start > position + const Duration(milliseconds: 500),
      );
      if (next < 0) return;
      target = next;
    } else if (current == null) {
      // Before the first chapter: back to the very start.
      await _seek(Duration.zero);
      return;
    } else if (position - chapters[current].start > chapterRestartThreshold) {
      target = current;
    } else {
      target = current > 0 ? current - 1 : 0;
    }
    await _seek(chapters[target].start);
    _showChapterNotice(target);
  }

  /// The chapter after the playhead, if any (a little slack, so a seek
  /// that landed just short doesn't repeat).
  int? get _nextChapter {
    final position = engine.position;
    final i = chapters.indexWhere((c) => c.start > position + const Duration(milliseconds: 500));
    return i < 0 ? null : i;
  }

  /// Next, as media players do it: the next chapter, or from the last
  /// chapter (or without chapters) the next episode.
  Future<void> skipForward() async {
    if (_nextChapter != null) return seekChapter(forward: true);
    playNext();
  }

  /// Previous: back to the start of this chapter, or the one before; from
  /// the start of the first chapter (or without chapters) the previous
  /// episode.
  Future<void> skipBack() async {
    final current = _chapterAt(engine.position);
    final atFirstStart = current == null ||
        (current == 0 && engine.position - chapters[0].start <= chapterRestartThreshold);
    if (chapters.isNotEmpty && !atFirstStart) return seekChapter(forward: false);
    if (previousEpisode != null) return playPrevious();
    await _seek(Duration.zero);
  }

  bool get canSkipForward => _nextChapter != null || nextEpisode != null;
  bool get canSkipBack => chapters.isNotEmpty || previousEpisode != null;

  /// What [skipForward] / [skipBack] would do, for tooltips.
  String get skipForwardLabel => _nextChapter != null ? 'Next chapter' : 'Next episode';
  String get skipBackLabel {
    final current = _chapterAt(engine.position);
    if (chapters.isEmpty || current == null) return 'Previous episode';
    if (current == 0 && engine.position - chapters[0].start <= chapterRestartThreshold) {
      return previousEpisode != null ? 'Previous episode' : 'Restart';
    }
    return 'Previous chapter';
  }

  void _showChapterNotice(int index) {
    chapterNotice = index;
    _chapterNoticeTimer?.cancel();
    _chapterNoticeTimer = Timer(const Duration(seconds: 2), () {
      chapterNotice = null;
      notifyListeners();
    });
    notifyListeners();
  }

  /// "Part A", or "Chapter 3" for untitled chapters.
  String chapterLabel(int index) {
    final title = chapters[index].title?.trim();
    return title == null || title.isEmpty ? 'Chapter ${index + 1}' : title;
  }

  void dismissUpNext() {
    _upNextDismissed = true;
    upNextCountdown = null;
    notifyListeners();
  }

  /// Set while the position is being kept for later because the server
  /// didn't take it; cleared once it does again.
  bool _keptForLater = false;

  /// Finished (90%), or part-way through something already watched: either
  /// way it stays watched.
  bool _countsAsWatched(Duration position) {
    final duration = engine.duration;
    final finished = duration > Duration.zero && position.inMilliseconds >= duration.inMilliseconds * 0.9;
    return finished || (item?.userData.played ?? false);
  }

  Future<void> _reportProgress() async {
    final plan = this.plan;
    if (!_started || plan == null || _stopped) return;
    final position = engine.position;
    final reported = await _report(() => playback.reportProgress(
          plan,
          position,
          paused: !engine.isPlaying,
        ));
    if (_stopped) return;
    if (!reported) {
      // Offline: kept as it goes, so closing the app or a crash mid-way
      // loses seconds, not the whole watch.
      _keptForLater = true;
      onUnreportedStop?.call(plan.itemId, position, _countsAsWatched(position));
    } else if (_keptForLater) {
      // The server's back and has the newer position: drop the kept one.
      _keptForLater = false;
      onReportedAgain?.call(plan.itemId);
    }
  }

  /// Reports the final position and releases the engine. Safe to call twice.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _progressTimer?.cancel();
    _chapterNoticeTimer?.cancel();
    for (final t in _recoveryTimers) {
      t.cancel();
    }
    _stallTimer?.cancel();
    _longWaitTimer?.cancel();
    // Cancelling takes effect immediately; no need to wait for the futures.
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    final plan = this.plan;
    final position = engine.position;
    // Silent straight away: the report can take a while (a slow network),
    // and the sound mustn't carry on after the player has closed.
    unawaited(engine.pause().catchError((Object _) {}));
    if (_started && plan != null) {
      final duration = engine.duration;
      final finished = duration > Duration.zero && position.inMilliseconds >= duration.inMilliseconds * 0.9;
      // Stopping part-way makes the server call it unwatched, even an episode
      // that was watched before (dipping back in for a recap): it stays watched.
      final rewatching = !finished && (item?.userData.played ?? false);
      final reported = await _report(() => playback.reportStopped(plan, position));
      if (!reported) {
        onUnreportedStop?.call(plan.itemId, position, finished || rewatching);
      } else {
        if (_keptForLater) onReportedAgain?.call(plan.itemId);
        if (rewatching) await _report(() => library.setPlayed(plan.itemId, true));
      }
    }
    await engine.dispose();
    await _nextRequests.close();
  }

  /// Reporting is best-effort: a flaky network must not interrupt playback.
  Future<bool> _report(Future<void> Function() call) async {
    try {
      await call();
      return true;
    } on JellyfinException catch (e) {
      debugPrint('Playback report failed: ${e.message}');
      return false;
    }
  }
}
