/// The video engine as seen by [PlaybackController]: just what the
/// playback logic needs, so the logic can be tested without libmpv.
abstract interface class MediaEngine {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get completedStream;

  /// True while playback waits for more of the stream to arrive.
  Stream<bool> get bufferingStream;
  Stream<String> get errorStream;

  Duration get position;
  Duration get duration;
  bool get isPlaying;

  /// Language preferences, applied before [open] picks default tracks.
  Future<void> setLanguagePreferences({
    required String audio,
    required String subtitles,
    bool subtitlesOff = false,
  });

  Future<void> open(
    Uri url, {
    required Map<String, String> headers,
    Duration start = Duration.zero,
  });

  /// Adds an external subtitle file without necessarily selecting it.
  Future<void> addSubtitle(Uri url, {String? title, String? language});

  /// Chapters in the playing file, empty if it has none (or it isn't
  /// loaded yet).
  Future<List<Chapter>> chapters();

  Future<void> seek(Duration position);

  /// How many times [open] or [seek] has been asked for. The position
  /// moving with no new jump is the player's own doing.
  int get jumps;

  Future<void> playOrPause();
  Future<void> play();
  Future<void> pause();

  /// Playback speed (1 = normal); watch together nudges it to catch up.
  Future<void> setRate(double rate);
  Future<void> dispose();
}

/// A chapter of the playing video.
class Chapter {
  const Chapter(this.start, {this.title});

  final Duration start;

  /// As named in the file or by Jellyfin; null or generic for many files.
  final String? title;
}
