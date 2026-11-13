import 'items.dart';
import 'jellyfin_api.dart';

/// One audio, video or subtitle stream inside a media source.
class MediaStream {
  const MediaStream({
    required this.index,
    required this.type,
    this.codec,
    this.language,
    this.title,
    this.displayTitle,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
    this.deliveryMethod,
    this.deliveryUrl,
    this.channels,
    this.width,
    this.height,
    this.videoRange,
    this.aspectRatio,
  });

  factory MediaStream.fromJson(Map<String, dynamic> json) => MediaStream(
        index: (json['Index'] as num).toInt(),
        type: json['Type'] as String? ?? '',
        codec: json['Codec'] as String?,
        language: json['Language'] as String?,
        title: json['Title'] as String?,
        displayTitle: json['DisplayTitle'] as String?,
        isDefault: json['IsDefault'] as bool? ?? false,
        isForced: json['IsForced'] as bool? ?? false,
        isExternal: json['IsExternal'] as bool? ?? false,
        deliveryMethod: json['DeliveryMethod'] as String?,
        deliveryUrl: json['DeliveryUrl'] as String?,
        channels: (json['Channels'] as num?)?.toInt(),
        width: (json['Width'] as num?)?.toInt(),
        height: (json['Height'] as num?)?.toInt(),
        videoRange: json['VideoRange'] as String?,
        aspectRatio: json['AspectRatio'] as String?,
      );

  final int index;

  /// Video, Audio, Subtitle, EmbeddedImage, ...
  final String type;
  final String? codec;
  final String? language;
  final String? title;
  final String? displayTitle;
  final bool isDefault;
  final bool isForced;

  /// A sidecar file next to the video, not inside the container.
  final bool isExternal;

  /// For subtitles: Embed, External, Encode (burned in), Hls.
  final String? deliveryMethod;
  final String? deliveryUrl;
  final int? channels;
  final int? width;
  final int? height;

  /// The picture's shape as Jellyfin reads it ("16:9"), for video.
  final String? aspectRatio;

  /// SDR, HDR, ...
  final String? videoRange;

  /// A subtitle in text (ASS, SubRip, WebVTT…), which the server can hand
  /// over as a file of its own; pictures (PGS, DVD) it can't.
  bool get isTextSubtitle => type == 'Subtitle' && _subtitleFormats.containsKey(codec?.toLowerCase());

  /// The file type the server serves this subtitle as.
  String get subtitleFormat => _subtitleFormats[codec?.toLowerCase()] ?? 'srt';

  static const _subtitleFormats = {
    'ass': 'ass',
    'ssa': 'ssa',
    'srt': 'srt',
    'subrip': 'srt',
    'vtt': 'vtt',
    'webvtt': 'vtt',
    'mov_text': 'srt',
    'ttml': 'ttml',
    'smi': 'smi',
  };
}

/// A playable version of an item (most items have exactly one).
class MediaSource {
  const MediaSource({
    required this.id,
    this.container,
    this.supportsDirectPlay = false,
    this.supportsDirectStream = false,
    this.supportsTranscoding = false,
    this.transcodingUrl,
    this.mediaStreams = const [],
    this.defaultAudioStreamIndex,
    this.defaultSubtitleStreamIndex,
    this.bitrate,
  });

  factory MediaSource.fromJson(Map<String, dynamic> json) => MediaSource(
        id: json['Id'] as String,
        container: json['Container'] as String?,
        supportsDirectPlay: json['SupportsDirectPlay'] as bool? ?? false,
        supportsDirectStream: json['SupportsDirectStream'] as bool? ?? false,
        supportsTranscoding: json['SupportsTranscoding'] as bool? ?? false,
        transcodingUrl: json['TranscodingUrl'] as String?,
        mediaStreams: (json['MediaStreams'] as List<dynamic>? ?? const [])
            .map((e) => MediaStream.fromJson(e as Map<String, dynamic>))
            .toList(),
        defaultAudioStreamIndex:
            (json['DefaultAudioStreamIndex'] as num?)?.toInt(),
        defaultSubtitleStreamIndex:
            (json['DefaultSubtitleStreamIndex'] as num?)?.toInt(),
        bitrate: (json['Bitrate'] as num?)?.toInt(),
      );

  final String id;
  final String? container;
  final bool supportsDirectPlay;
  final bool supportsDirectStream;
  final bool supportsTranscoding;

  /// Server-relative URL of the transcoded stream, when transcoding.
  final String? transcodingUrl;
  final List<MediaStream> mediaStreams;
  final int? defaultAudioStreamIndex;
  final int? defaultSubtitleStreamIndex;
  final int? bitrate;

  Iterable<MediaStream> streamsOfType(String type) =>
      mediaStreams.where((s) => s.type == type);

  /// Why the server decided to transcode, e.g. `ContainerNotSupported`.
  /// Empty when playing directly.
  List<String> get transcodeReasons {
    final url = transcodingUrl;
    if (url == null) return const [];
    final reasons = Uri.parse(url).queryParameters['TranscodeReasons'];
    if (reasons == null || reasons.isEmpty) return const [];
    return reasons.split(',');
  }
}

class PlaybackInfo {
  const PlaybackInfo({
    required this.mediaSources,
    required this.playSessionId,
    this.errorCode,
  });

  factory PlaybackInfo.fromJson(Map<String, dynamic> json) => PlaybackInfo(
        mediaSources: (json['MediaSources'] as List<dynamic>? ?? const [])
            .map((e) => MediaSource.fromJson(e as Map<String, dynamic>))
            .toList(),
        playSessionId: json['PlaySessionId'] as String?,
        errorCode: json['ErrorCode'] as String?,
      );

  final List<MediaSource> mediaSources;
  final String? playSessionId;

  /// Set when the server refuses playback: NotAllowed, NoCompatibleStream,
  /// RateLimitExceeded.
  final String? errorCode;
}

enum PlayMethod {
  directPlay('DirectPlay', 'Direct play'),
  directStream('DirectStream', 'Direct stream (remux)'),
  transcode('Transcode', 'Transcoding');

  const PlayMethod(this.apiName, this.label);

  final String apiName;
  final String label;
}

/// What to play and how: the URL handed to the player plus reporting info.
class PlaybackPlan {
  const PlaybackPlan({
    required this.itemId,
    required this.source,
    required this.method,
    required this.url,
    required this.playSessionId,
  });

  final String itemId;
  final MediaSource source;
  final PlayMethod method;
  final Uri url;
  final String? playSessionId;

  List<String> get transcodeReasons => source.transcodeReasons;
}

enum SegmentType { intro, outro, recap, preview, commercial, unknown }

/// A skippable section of an item (intro, credits, recap, ...).
class MediaSegment {
  const MediaSegment({
    required this.type,
    required this.start,
    required this.end,
  });

  factory MediaSegment.fromJson(Map<String, dynamic> json) => MediaSegment(
        type: switch (json['Type']) {
          'Intro' => SegmentType.intro,
          'Outro' => SegmentType.outro,
          'Recap' => SegmentType.recap,
          'Preview' => SegmentType.preview,
          'Commercial' => SegmentType.commercial,
          _ => SegmentType.unknown,
        },
        start: ticksToDuration((json['StartTicks'] as num).toInt()),
        end: ticksToDuration((json['EndTicks'] as num).toInt()),
      );

  final SegmentType type;
  final Duration start;
  final Duration end;

  bool contains(Duration position) => position >= start && position < end;
}

/// A device profile for an mpv-based player.
///
/// mpv decodes nearly every container and codec, so everything is allowed
/// to direct play; the server only transcodes for bitrate limits or files
/// it can't serve directly. Subtitles are left embedded so mpv/libass
/// renders ASS styling and fonts exactly. With [burnPictures], picture
/// subtitles (PGS, DVD) can't stay embedded, so a converted stream has the
/// one asked for drawn into the video.
Map<String, Object?> mpvDeviceProfile({int maxBitrate = 200000000, bool burnPictures = false}) {
  const pictures = ['pgssub', 'pgs', 'dvdsub', 'dvbsub'];
  const embedded = [
    'ass', 'ssa', 'srt', 'subrip', 'vtt', 'webvtt', 'pgssub', 'pgs', //
    'dvdsub', 'dvbsub', 'sub', 'idx', 'smi', 'ttml', 'mov_text',
  ];
  const external = ['ass', 'ssa', 'srt', 'subrip', 'vtt', 'webvtt', 'sub', 'smi'];
  return {
    'Name': 'Kurage (mpv)',
    'MaxStreamingBitrate': maxBitrate,
    'MaxStaticBitrate': maxBitrate,
    'MusicStreamingTranscodingBitrate': 384000,
    'DirectPlayProfiles': [
      {'Type': 'Video'},
      {'Type': 'Audio'},
    ],
    'TranscodingProfiles': [
      {
        'Container': 'ts',
        'Type': 'Video',
        'VideoCodec': 'hevc,h264',
        'AudioCodec': 'aac,ac3,eac3,mp3,opus,flac',
        'Protocol': 'hls',
        'Context': 'Streaming',
        'MaxAudioChannels': '8',
        'MinSegments': 1,
        'BreakOnNonKeyFrames': true,
      },
      {
        'Container': 'mp3',
        'Type': 'Audio',
        'AudioCodec': 'mp3',
        'Protocol': 'http',
        'Context': 'Streaming',
      },
    ],
    'ContainerProfiles': <Object>[],
    'CodecProfiles': <Object>[],
    'SubtitleProfiles': [
      for (final f in embedded)
        if (!burnPictures || !pictures.contains(f)) {'Format': f, 'Method': 'Embed'},
      for (final f in external) {'Format': f, 'Method': 'External'},
      if (burnPictures)
        for (final f in pictures) {'Format': f, 'Method': 'Encode'},
    ],
  };
}

/// Playback endpoints: negotiation, stream URLs, reporting, segments.
class PlaybackApi {
  PlaybackApi(this._api, {required this.userId});

  final JellyfinApi _api;
  final String userId;

  Future<PlaybackInfo> getPlaybackInfo(
    String itemId, {
    Duration? start,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int maxBitrate = 200000000,
    bool burnPictureSubtitles = false,
  }) async {
    final data = await _api.postJson(
      '/Items/$itemId/PlaybackInfo',
      query: {'userId': userId},
      body: {
        'UserId': userId,
        'DeviceProfile': mpvDeviceProfile(maxBitrate: maxBitrate, burnPictures: burnPictureSubtitles),
        'MaxStreamingBitrate': maxBitrate,
        'StartTimeTicks': start == null ? null : durationToTicks(start),
        'MediaSourceId': mediaSourceId,
        'AudioStreamIndex': audioStreamIndex,
        'SubtitleStreamIndex': subtitleStreamIndex,
        'EnableDirectPlay': true,
        'EnableDirectStream': true,
        'EnableTranscoding': true,
        'AllowVideoStreamCopy': true,
        'AllowAudioStreamCopy': true,
        'AutoOpenLiveStream': true,
      },
    );
    return PlaybackInfo.fromJson(data);
  }

  /// Picks how to play the first media source and builds its URL.
  ///
  /// Throws [JellyfinException] if the server can't serve it at all.
  PlaybackPlan plan(String itemId, PlaybackInfo info) {
    if (info.errorCode != null) {
      throw JellyfinException(switch (info.errorCode) {
        'NotAllowed' => 'Your account isn\'t allowed to play this.',
        'NoCompatibleStream' => 'The server has no playable stream for this.',
        'RateLimitExceeded' => 'Too many streams are playing right now.',
        final code => 'The server refused playback ($code).',
      });
    }
    if (info.mediaSources.isEmpty) {
      throw const JellyfinException('This item has no playable media.');
    }
    final source = info.mediaSources.first;
    final token = _api.accessToken;

    if (source.supportsDirectPlay || source.supportsDirectStream) {
      // static=true serves the original file, which mpv can always play.
      return PlaybackPlan(
        itemId: itemId,
        source: source,
        method: source.supportsDirectPlay
            ? PlayMethod.directPlay
            : PlayMethod.directStream,
        playSessionId: info.playSessionId,
        // No api_key: the player sends the Authorization header with the
        // file's requests, and a token in the address ends up in proxy logs
        // (Caddy's, for one).
        url: _api.resolve('/Videos/$itemId/stream', {
          'static': true,
          'mediaSourceId': source.id,
          'playSessionId': info.playSessionId,
          'deviceId': _api.clientInfo.deviceId,
        }),
      );
    }
    final transcodingUrl = source.transcodingUrl;
    if (transcodingUrl != null) {
      final relative = Uri.parse(transcodingUrl);
      return PlaybackPlan(
        itemId: itemId,
        source: source,
        method: PlayMethod.transcode,
        playSessionId: info.playSessionId,
        // Kept: the playlist's segment requests are built from this
        // address, and they don't all carry the player's header.
        url: _api.resolve(relative.path, {
          ...relative.queryParameters,
          if (!relative.queryParameters.containsKey('api_key')) 'api_key': token,
        }),
      );
    }
    throw const JellyfinException('The server can\'t stream this file.');
  }

  /// URL of a subtitle stream for the player to load as a separate file.
  Uri subtitleUrl(PlaybackPlan plan, MediaStream stream) {
    final delivery = stream.deliveryUrl;
    final base = delivery != null
        ? Uri.parse(delivery)
        : Uri(
            path: '/Videos/${plan.itemId}/${plan.source.id}/Subtitles/'
                '${stream.index}/0/Stream.${stream.subtitleFormat}',
          );
    // Kept: mpv loads a subtitle file on its own, without the video's
    // headers.
    return _api.resolve(base.path, {
      ...base.queryParameters,
      'api_key': _api.accessToken,
    });
  }

  Future<List<MediaSegment>> getSegments(String itemId) async {
    try {
      final data = await _api.getJson('/MediaSegments/$itemId');
      return (data['Items'] as List<dynamic>? ?? const [])
          .map((e) => MediaSegment.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
    } on JellyfinException {
      // Older servers or no segment provider: just no skip buttons.
      return const [];
    }
  }

  Map<String, Object?> _report(
    PlaybackPlan plan,
    Duration position, {
    bool? paused,
  }) =>
      {
        'ItemId': plan.itemId,
        'MediaSourceId': plan.source.id,
        'PlaySessionId': plan.playSessionId,
        'PlayMethod': plan.method.apiName,
        'PositionTicks': durationToTicks(position),
        'CanSeek': true,
        'IsPaused': ?paused,
      };

  Future<void> reportStart(PlaybackPlan plan, Duration position) =>
      _api.postJson('/Sessions/Playing', body: _report(plan, position, paused: false));

  Future<void> reportProgress(
    PlaybackPlan plan,
    Duration position, {
    required bool paused,
  }) =>
      _api.postJson(
        '/Sessions/Playing/Progress',
        body: {
          ..._report(plan, position, paused: paused),
          'EventName': 'TimeUpdate',
        },
      );

  /// Tells the server playback ended. It marks the item watched when
  /// [position] is past its "played" threshold (90% by default).
  Future<void> reportStopped(PlaybackPlan plan, Duration position) =>
      _api.postJson('/Sessions/Playing/Stopped', body: _report(plan, position));
}
