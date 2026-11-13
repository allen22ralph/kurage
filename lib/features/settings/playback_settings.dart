import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Player preferences, stored on this device.
class PlaybackSettings {
  const PlaybackSettings({
    this.audioLanguages = 'jpn,ja',
    this.subtitleLanguages = 'eng,en',
    this.autoSkipIntro = false,
    this.autoPlayNext = true,
    this.clickToPlayPause = true,
    this.doubleTapSeek = true,
    this.doubleTapSeconds = 10,
    this.swipeVolume = true,
    this.swipeBrightness = true,
    this.swipeSystemVolume = true,
    this.levelsAtSide = false,
    this.hardwareDecoding = HardwareDecoding.copy,
    this.defaultQuality = StreamQuality.auto,
  });

  /// Preferred audio languages, comma-separated ISO 639 codes, best first.
  /// Passed to mpv's `alang`, so it picks e.g. Japanese audio when present.
  final String audioLanguages;

  /// Preferred subtitle languages, passed to mpv's `slang`.
  final String subtitleLanguages;

  /// Skip intros and recaps without asking.
  final bool autoSkipIntro;

  /// Start the next episode when the episode ends (up next's countdown).
  final bool autoPlayNext;

  /// Clicking the video toggles play/pause (desktop).
  final bool clickToPlayPause;

  /// Touch (phones): double-tap the left / right side to skip back / ahead.
  final bool doubleTapSeek;
  final int doubleTapSeconds;

  /// Touch (phones): swipe up / down on the right side for volume, on the
  /// left side for brightness.
  final bool swipeVolume;
  final bool swipeBrightness;

  /// The volume swipe sets the phone's media volume (kept in step with the
  /// volume keys); off: only the player's own volume.
  final bool swipeSystemVolume;

  /// How the swipe level shows: a centered icon + percentage pill, or just
  /// the percentage on the side being swiped.
  final bool levelsAtSide;

  /// Windows: how mpv's hardware decoding reaches the screen.
  final HardwareDecoding hardwareDecoding;

  /// The streaming quality every start of the app begins with; a pick in
  /// the player overrides it until the app closes.
  final StreamQuality defaultQuality;

  PlaybackSettings copyWith({
    String? audioLanguages,
    String? subtitleLanguages,
    bool? autoSkipIntro,
    bool? autoPlayNext,
    bool? clickToPlayPause,
    bool? doubleTapSeek,
    int? doubleTapSeconds,
    bool? swipeVolume,
    bool? swipeBrightness,
    bool? swipeSystemVolume,
    bool? levelsAtSide,
    HardwareDecoding? hardwareDecoding,
    StreamQuality? defaultQuality,
  }) =>
      PlaybackSettings(
        audioLanguages: audioLanguages ?? this.audioLanguages,
        subtitleLanguages: subtitleLanguages ?? this.subtitleLanguages,
        autoSkipIntro: autoSkipIntro ?? this.autoSkipIntro,
        autoPlayNext: autoPlayNext ?? this.autoPlayNext,
        clickToPlayPause: clickToPlayPause ?? this.clickToPlayPause,
        doubleTapSeek: doubleTapSeek ?? this.doubleTapSeek,
        doubleTapSeconds: doubleTapSeconds ?? this.doubleTapSeconds,
        swipeVolume: swipeVolume ?? this.swipeVolume,
        swipeBrightness: swipeBrightness ?? this.swipeBrightness,
        swipeSystemVolume: swipeSystemVolume ?? this.swipeSystemVolume,
        levelsAtSide: levelsAtSide ?? this.levelsAtSide,
        hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
        defaultQuality: defaultQuality ?? this.defaultQuality,
      );
}

/// The most a stream may use. Above that the server converts the video,
/// which is lighter on the connection and heavier on the server.
enum StreamQuality {
  /// As much as the file has, stepping down when playback keeps stalling.
  auto('Auto'),
  original('Original'),
  mbps20('20 Mbps', 20000000),
  mbps10('10 Mbps', 10000000),
  mbps8('8 Mbps', 8000000),
  mbps6('6 Mbps', 6000000),
  mbps4('4 Mbps', 4000000),
  mbps3('3 Mbps', 3000000),
  mbps2('2 Mbps', 2000000),
  mbps1('1 Mbps', 1000000);

  const StreamQuality(this.label, [this.bitrate]);

  final String label;

  /// Bits per second; null: no limit of ours.
  final int? bitrate;

  /// The next level down, for Auto to step to; null at the bottom.
  StreamQuality? get lower {
    const steps = [mbps20, mbps10, mbps6, mbps4, mbps2, mbps1];
    final now = bitrate;
    if (now == null) return steps.first;
    return steps.where((s) => s.bitrate! < now).firstOrNull;
  }

  /// The highest step under [bitsPerSecond]; null when there's none.
  static StreamQuality? below(int bitsPerSecond) =>
      const [mbps20, mbps10, mbps6, mbps4, mbps2, mbps1].where((s) => s.bitrate! < bitsPerSecond).firstOrNull;

  static StreamQuality named(String? name) => values.where((q) => q.name == name).firstOrNull ?? auto;
}

/// How decoded video gets to the screen (Windows).
enum HardwareDecoding {
  /// On the graphics card, each frame copied back before it's drawn (what
  /// Jellyfin Media Player does): 10-bit HEVC handed over directly came out
  /// stretched with a black strip.
  copy('Auto (copy back)', 'auto-copy'),

  /// On the graphics card, frames handed straight to the screen.
  direct('Direct', 'auto'),

  /// On the processor.
  off('Off', 'no');

  const HardwareDecoding(this.label, this.mpv);

  final String label;

  /// mpv's `hwdec`.
  final String mpv;
}

final playbackSettingsProvider =
    AsyncNotifierProvider<PlaybackSettingsController, PlaybackSettings>(
  PlaybackSettingsController.new,
);

class PlaybackSettingsController extends AsyncNotifier<PlaybackSettings> {
  static const _prefix = 'playback.';

  @override
  Future<PlaybackSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    const d = PlaybackSettings();
    return PlaybackSettings(
      audioLanguages: prefs.getString('${_prefix}audioLanguages') ?? d.audioLanguages,
      subtitleLanguages:
          prefs.getString('${_prefix}subtitleLanguages') ?? d.subtitleLanguages,
      autoSkipIntro: prefs.getBool('${_prefix}autoSkipIntro') ?? d.autoSkipIntro,
      autoPlayNext: prefs.getBool('${_prefix}autoPlayNext') ?? d.autoPlayNext,
      clickToPlayPause:
          prefs.getBool('${_prefix}clickToPlayPause') ?? d.clickToPlayPause,
      doubleTapSeek: prefs.getBool('${_prefix}doubleTapSeek') ?? d.doubleTapSeek,
      doubleTapSeconds: prefs.getInt('${_prefix}doubleTapSeconds') ?? d.doubleTapSeconds,
      swipeVolume: prefs.getBool('${_prefix}swipeVolume') ?? d.swipeVolume,
      swipeBrightness: prefs.getBool('${_prefix}swipeBrightness') ?? d.swipeBrightness,
      swipeSystemVolume: prefs.getBool('${_prefix}swipeSystemVolume') ?? d.swipeSystemVolume,
      levelsAtSide: prefs.getBool('${_prefix}levelsAtSide') ?? d.levelsAtSide,
      hardwareDecoding: HardwareDecoding.values
              .where((h) => h.name == prefs.getString('${_prefix}hardwareDecoding'))
              .firstOrNull ??
          d.hardwareDecoding,
      defaultQuality: StreamQuality.named(prefs.getString('${_prefix}defaultQuality')),
    );
  }

  Future<void> save(PlaybackSettings settings) async {
    state = AsyncData(settings);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}audioLanguages', settings.audioLanguages);
    await prefs.setString('${_prefix}subtitleLanguages', settings.subtitleLanguages);
    await prefs.setBool('${_prefix}autoSkipIntro', settings.autoSkipIntro);
    await prefs.setBool('${_prefix}autoPlayNext', settings.autoPlayNext);
    await prefs.setBool('${_prefix}clickToPlayPause', settings.clickToPlayPause);
    await prefs.setBool('${_prefix}doubleTapSeek', settings.doubleTapSeek);
    await prefs.setInt('${_prefix}doubleTapSeconds', settings.doubleTapSeconds);
    await prefs.setBool('${_prefix}swipeVolume', settings.swipeVolume);
    await prefs.setBool('${_prefix}swipeBrightness', settings.swipeBrightness);
    await prefs.setBool('${_prefix}swipeSystemVolume', settings.swipeSystemVolume);
    await prefs.setBool('${_prefix}levelsAtSide', settings.levelsAtSide);
    await prefs.setString('${_prefix}hardwareDecoding', settings.hardwareDecoding.name);
    await prefs.setString('${_prefix}defaultQuality', settings.defaultQuality.name);
    // Left by an earlier build, which kept the player's last pick.
    await prefs.remove('${_prefix}quality');
  }
}
