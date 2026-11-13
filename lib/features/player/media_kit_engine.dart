import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'media_engine.dart';

/// [MediaEngine] backed by media_kit (libmpv).
class MediaKitEngine implements MediaEngine {
  MediaKitEngine({required String title})
      : player = Player(
          configuration: PlayerConfiguration(
            title: title,
            // Render subtitles with libass inside mpv, so ASS styling,
            // positioning and embedded fonts (common in anime) are exact.
            libass: true,
            bufferSize: 64 * 1024 * 1024,
          ),
        );

  final Player player;

  NativePlayer? get _native =>
      player.platform is NativePlayer ? player.platform as NativePlayer : null;

  /// The video as the player sees it: decoded size, display size (what's
  /// laid out), and any crop from the file. Null before it's loaded.
  Future<({int w, int h, int dw, int dh, String crop})?> videoGeometry() async {
    final native = _native;
    if (native == null) return null;
    // A property this mpv lacks reads as 0 / empty rather than failing.
    Future<String> get(String p) => native.getProperty(p).catchError((Object _) => '');
    Future<int> i(String p) async => int.tryParse(await get(p)) ?? 0;
    final w = await i('video-params/w');
    if (w == 0) return null;
    return (
      w: w,
      h: await i('video-params/h'),
      dw: await i('video-params/dw'),
      dh: await i('video-params/dh'),
      crop: await _crop(get, w, await i('video-params/h')),
    );
  }

  /// The crop the player applies, "WxH+X+Y", or "" for the whole frame.
  static Future<String> _crop(Future<String> Function(String) get, int w, int h) async {
    final cw = int.tryParse(await get('video-params/crop-w')) ?? 0;
    final ch = int.tryParse(await get('video-params/crop-h')) ?? 0;
    if (cw == 0 || ch == 0 || (cw == w && ch == h)) return '';
    return '${cw}x$ch+${await get('video-params/crop-x')}+${await get('video-params/crop-y')}';
  }

  /// The decoder in use: "d3d11va-copy", "no" (software)…; null unknown.
  Future<String?> decoder() async {
    final native = _native;
    if (native == null) return null;
    final current = await native.getProperty('hwdec-current').catchError((Object _) => '');
    return current.isEmpty ? null : (current == 'no' ? 'software' : current);
  }

  /// The picture's shape: "auto" (the file's), a ratio ("16:9", "4:3"),
  /// "fill" (cropped to the screen) or "stretch".
  Future<void> setAspect(String mode) async {
    final native = _native;
    if (native == null) return;
    await native.setProperty('keepaspect', mode == 'stretch' ? 'no' : 'yes');
    await native.setProperty('panscan', mode == 'fill' ? '1.0' : '0.0');
    await native.setProperty('video-aspect-override', mode.contains(':') ? mode : '-1');
  }

  @override
  Stream<Duration> get positionStream => player.stream.position;
  @override
  Stream<Duration> get durationStream => player.stream.duration;
  @override
  Stream<bool> get playingStream => player.stream.playing;
  @override
  Stream<bool> get completedStream => player.stream.completed;
  @override
  Stream<bool> get bufferingStream => player.stream.buffering;
  @override
  Stream<String> get errorStream => player.stream.error;

  @override
  Duration get position => player.state.position;
  @override
  Duration get duration => player.state.duration;
  @override
  bool get isPlaying => player.state.playing;

  @override
  Future<void> setLanguagePreferences({
    required String audio,
    required String subtitles,
    bool subtitlesOff = false,
  }) async {
    final native = _native;
    if (native == null) return;
    await native.setProperty('alang', audio);
    await native.setProperty('slang', subtitles);
    // "no" stops mpv picking a subtitle track by itself (incl. sub-add auto).
    await native.setProperty('sid', subtitlesOff ? 'no' : 'auto');
    // Load fonts attached to MKV files (ASS subtitle fonts).
    await native.setProperty('embeddedfonts', 'yes');
    // Android's libass can't find system fonts, so subtitles without fonts
    // of their own (SubRip, most plain ASS) showed nothing. Point it at a
    // copy of the system's CJK font, which also covers Latin text.
    if (Platform.isAndroid) {
      if (await _androidSubtitleFont() case (final dir, final family)) {
        await native.setProperty('sub-fonts-dir', dir);
        await native.setProperty('sub-font', family);
      }
    }
    // Servers and proxies close idle connections, e.g. while paused with a
    // full buffer; without this the next read fails with "end of file".
    // FFmpeg reconnects and continues from the same byte offset.
    await native.setProperty(
      'stream-lavf-o',
      'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,'
          'reconnect_delay_max=10',
    );
  }

  @override
  Future<void> open(
    Uri url, {
    required Map<String, String> headers,
    Duration start = Duration.zero,
  }) {
    jumps++;
    return player.open(
      Media(
        url.toString(),
        httpHeaders: headers,
        start: start > Duration.zero ? start : null,
      ),
    );
  }

  @override
  Future<void> addSubtitle(Uri url, {String? title, String? language}) async {
    // `auto` adds the track and lets slang decide whether to select it.
    await _native?.command([
      'sub-add',
      url.toString(),
      'auto',
      title ?? language ?? 'External',
      language ?? '',
    ]);
  }

  /// The tracks mpv is actually playing (ids as in the track lists; 'no'
  /// for no subtitles). media_kit only knows what was last chosen, which is
  /// 'auto' when mpv picked by itself (e.g. the only audio track).
  Future<({String? audio, String subtitle})> playingTrackIds() async {
    final native = _native;
    if (native == null) return (audio: null, subtitle: 'no');
    Future<String?> id(String kind) async {
      try {
        final v = await native.getProperty('current-tracks/$kind/id');
        return v.isEmpty ? null : v;
      } on Object {
        return null; // none selected
      }
    }

    return (audio: await id('audio'), subtitle: await id('sub') ?? 'no');
  }

  @override
  Future<List<Chapter>> chapters() async {
    final native = _native;
    if (native == null) return const [];
    final count = int.tryParse(await native.getProperty('chapter-list/count')) ?? 0;
    final chapters = <Chapter>[];
    for (var i = 0; i < count; i++) {
      final seconds = double.tryParse(await native.getProperty('chapter-list/$i/time'));
      if (seconds == null) continue;
      final title = await native.getProperty('chapter-list/$i/title');
      chapters.add(Chapter(
        Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round()),
        title: title.isEmpty ? null : title,
      ));
    }
    return chapters;
  }

  @override
  Future<void> seek(Duration position) {
    jumps++;
    return player.seek(position);
  }

  @override
  int jumps = 0;

  @override
  Future<void> playOrPause() => player.playOrPause();
  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> setRate(double rate) => player.setRate(rate);

  @override
  Future<void> dispose() => player.dispose();

  /// Shifts subtitles relative to the audio (positive = later).
  Future<void> setSubtitleDelay(Duration delay) async =>
      _native?.setProperty('sub-delay', '${delay.inMilliseconds / 1000}');

  Future<void> setAudioDelay(Duration delay) async =>
      _native?.setProperty('audio-delay', '${delay.inMilliseconds / 1000}');
}

/// Candidate system fonts for subtitles, best first, with their family names:
/// Noto Sans CJK covers Japanese / Chinese / Korean and Latin; Roboto is the
/// Latin-only fallback.
const _subtitleFonts = [
  ('/system/fonts/NotoSansCJK-Regular.ttc', 'Noto Sans CJK JP'),
  ('/system/fonts/NotoSansCJKjp-Regular.otf', 'Noto Sans CJK JP'),
  ('/system/fonts/Roboto-Regular.ttf', 'Roboto'),
];

Future<(String, String)?>? _subtitleFont;

/// A directory holding one subtitle font, and its family name. libass reads
/// every file in the directory, so the font is copied into a folder of its
/// own (once) rather than pointing at all of /system/fonts.
Future<(String, String)?> _androidSubtitleFont() => _subtitleFont ??= () async {
      try {
        for (final (path, family) in _subtitleFonts) {
          final source = File(path);
          if (!await source.exists()) continue;
          final dir = Directory('${(await getApplicationSupportDirectory()).path}/subtitle-fonts');
          final copy = File('${dir.path}/${path.split('/').last}');
          if (!await copy.exists() || await copy.length() != await source.length()) {
            if (await dir.exists()) await dir.delete(recursive: true);
            await dir.create(recursive: true);
            await source.copy(copy.path);
          }
          return (dir.path, family);
        }
      } on Object {
        // No usable font: subtitles with their own fonts still work.
      }
      return null;
    }();
