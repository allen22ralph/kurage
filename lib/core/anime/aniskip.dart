import 'package:dio/dio.dart';

import '../jellyfin/playback_api.dart';

/// AniSkip (api.aniskip.com): crowd-sourced opening/ending times by MAL ID
/// and episode, used when the Jellyfin server has no media segments.
class AniSkipApi {
  AniSkipApi({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(baseUrl: 'https://api.aniskip.com/v2'));

  final Dio _dio;

  static const _types = {
    'op': SegmentType.intro,
    'mixed-op': SegmentType.intro,
    'ed': SegmentType.outro,
    'mixed-ed': SegmentType.outro,
    'recap': SegmentType.recap,
  };

  /// Segments for [episode] of [malId]; empty when AniSkip has none. With
  /// [episodeLength], AniSkip only returns times submitted for files of
  /// about that length (other releases can be offset).
  Future<List<MediaSegment>> skipTimes(int malId, int episode, {Duration? episodeLength}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/skip-times/$malId/$episode',
      queryParameters: {
        'types': _types.keys.toList(), // sent as types[]=op&types[]=ed…
        'episodeLength': episodeLength == null ? 0 : episodeLength.inMilliseconds / 1000,
      },
      options: Options(listFormat: ListFormat.multiCompatible, validateStatus: (s) => s == 200 || s == 404),
    );
    final data = response.data;
    if (data == null || data['found'] != true) return const [];
    // Several submissions can exist per kind (e.g. "op" and "mixed-op",
    // or for other releases): keep the one closest to this file's length,
    // preferring the plain kind.
    final length = episodeLength == null ? null : episodeLength.inMilliseconds / 1000;
    final best = <SegmentType, (double, MediaSegment)>{};
    for (final r in (data['results'] as List).cast<Map<String, dynamic>>()) {
      final skipType = r['skipType'] as String?;
      final type = _types[skipType];
      if (type == null) continue;
      if (r['interval'] case {'startTime': final num start, 'endTime': final num end}) {
        final submitted = (r['episodeLength'] as num?)?.toDouble();
        final double distance = (length == null || submitted == null ? 0.0 : (submitted - length).abs()) +
            (skipType!.startsWith('mixed-') ? 0.5 : 0);
        final segment = MediaSegment(
          type: type,
          start: Duration(milliseconds: (start * 1000).round()),
          end: Duration(milliseconds: (end * 1000).round()),
        );
        if (best[type] case final current? when current.$1 <= distance) continue;
        best[type] = (distance, segment);
      }
    }
    final segments = [for (final b in best.values) b.$2]..sort((a, b) => a.start.compareTo(b.start));
    return segments;
  }
}
