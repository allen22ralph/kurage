import 'package:dio/dio.dart';

import 'anime_info.dart';

/// What MAL lists for one episode: its titles and the community rating
/// (the "Poll" column, 1–5).
class MalEpisode {
  const MalEpisode({this.score, this.title, this.romaji, this.japanese});

  final double? score;

  /// English title.
  final String? title;
  final String? romaji;
  final String? japanese;
}

/// An anime's Episodes tab on MAL. The official API has no episodes, so
/// they're read from that page, with Jikan (which scrapes the same page)
/// as a fallback.
class EpisodeScoresApi {
  EpisodeScoresApi({required this.site, this.jikan});

  /// myanimelist.net itself.
  final Dio site;
  final JikanApi? jikan;

  /// MAL and Jikan both list 100 episodes per page.
  static const pageSize = 100;

  /// Episodes by number for the page holding [episode].
  Future<Map<int, MalEpisode>> page(int malId, int episode) async {
    final index = (episode - 1) ~/ pageSize;
    try {
      final r = await site.get<String>(
        '/anime/$malId/_/episode',
        queryParameters: {'offset': index * pageSize},
        options: Options(responseType: ResponseType.plain),
      );
      return parseMalEpisodePage(r.data ?? '');
    } on Object {
      final jikan = this.jikan;
      if (jikan == null) rethrow;
      return jikan.episodes(malId, page: index + 1);
    }
  }
}

final _row = RegExp(r'<tr class="episode-list-data">(.*?)</tr>', dotAll: true);
final _number = RegExp(r'episode-number[^>]*>\s*(\d+)');
final _poll = RegExp(r'class="episode-poll[^"]*"[^>]*data-raw="([\d.]+)"');
final _title = RegExp(r'class="episode-title[^"]*">\s*<a [^>]*>(.*?)</a>', dotAll: true);
// "Guuzen ka Hitsuzen ka&nbsp;(偶然か必然か)"
final _alt = RegExp(r'class="episode-title.*?<span class="di-ib">(.*?)</span>', dotAll: true);

/// Episode number → what an Episodes page shows for it.
Map<int, MalEpisode> parseMalEpisodePage(String html) {
  final episodes = <int, MalEpisode>{};
  for (final row in _row.allMatches(html)) {
    final cells = row[1]!;
    final number = int.tryParse(_number.firstMatch(cells)?[1] ?? '');
    if (number == null) continue;
    final score = double.tryParse(_poll.firstMatch(cells)?[1] ?? '');
    String? romaji;
    String? japanese;
    if (_alt.firstMatch(cells) case final alt?) {
      final text = _text(alt[1]!) ?? '';
      final paren = RegExp(r'^(.*?)\s*\(([^()]*)\)$').firstMatch(text);
      romaji = _nonEmpty(paren?[1] ?? text);
      japanese = _nonEmpty(paren?[2]);
    }
    episodes[number] = MalEpisode(
      score: score != null && score > 0 ? score : null,
      title: _text(_title.firstMatch(cells)?[1]),
      romaji: romaji,
      japanese: japanese,
    );
  }
  return episodes;
}

String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

/// Inner text of an HTML fragment: tags dropped, entities decoded.
String? _text(String? html) {
  if (html == null) return null;
  final text = html.replaceAll(RegExp('<[^>]*>'), '').replaceAllMapped(
        RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-z]+);'),
        (m) {
          final e = m[1]!;
          if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
          if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
          return const {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' '}[e] ?? m[0]!;
        },
      );
  return _nonEmpty(text);
}
