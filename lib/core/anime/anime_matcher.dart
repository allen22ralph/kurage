import 'anime_ids.dart';

/// How an item was linked to its MyAnimeList entry.
enum MatchSource {
  manual('Set by you'),
  anidb('AniDB ID'),
  anilist('AniList ID'),
  tvdb('TVDB ID + season'),
  tmdb('TMDB ID + season');

  const MatchSource(this.label);

  final String label;
}

/// An item's MAL entry. [candidates] lists every MAL entry for the season in
/// airing order (a split-cour season has two); [malId] is the first.
class MalMatch {
  const MalMatch(this.malId, this.source, {this.candidates = const []});

  final int malId;
  final MatchSource source;
  final List<int> candidates;

  List<int> get entries => candidates.isEmpty ? [malId] : candidates;
}

/// What the matcher needs to know about an item.
class MatchInput {
  const MatchInput({
    this.ids = const {},
    this.seriesIds = const {},
    this.seasonNumber,
    this.isMovie = false,
  });

  /// Provider IDs of the item itself (a season, or a movie/series).
  final Map<String, String> ids;

  /// Provider IDs of the series, for seasons and episodes.
  final Map<String, String> seriesIds;

  /// Season number for seasons/episodes; null for series and movies.
  final int? seasonNumber;
  final bool isMovie;
}

/// Links a Jellyfin item to MyAnimeList, best evidence first:
///  1. a manual "fix match";
///  2. the item's own AniDB / AniList ID (with AniDB metadata each season
///     is its own AniDB entry);
///  3. the series' AniDB / AniList ID — but only for season 1 or a whole
///     series, since later seasons are separate MAL entries;
///  4. TVDB, then TMDB, ID + season number.
/// Returns null when nothing matches (the UI then offers "fix match").
MalMatch? matchMal(MatchInput input, AnimeIdMapping mapping, {int? manual}) {
  if (manual != null) return MalMatch(manual, MatchSource.manual);

  int? idOf(Map<String, String> ids, String key) {
    for (final e in ids.entries) {
      if (e.key.toLowerCase() == key) return int.tryParse(e.value.trim());
    }
    return null;
  }

  MalMatch? direct(Map<String, String> ids) {
    if (idOf(ids, 'anidb') case final id? when mapping.malForAnidb(id) != null) {
      return MalMatch(mapping.malForAnidb(id)!, MatchSource.anidb);
    }
    if (idOf(ids, 'anilist') case final id? when mapping.malForAnilist(id) != null) {
      return MalMatch(mapping.malForAnilist(id)!, MatchSource.anilist);
    }
    return null;
  }

  final season = input.seasonNumber;
  final isSeason = season != null;

  // 2. The item's own IDs. For a season these only count if they differ
  // from the series' (Jellyfin copies series IDs down in some setups).
  final own = direct(input.ids);
  if (own != null && (!isSeason || direct(input.seriesIds)?.malId != own.malId)) {
    return own;
  }

  // 3. Series IDs stand for the first season / the whole show.
  final series = isSeason ? direct(input.seriesIds) : own;
  if (series != null && (season == null || season == 1)) return series;

  if (input.isMovie) {
    if (idOf(input.ids, 'tmdb') case final id? when mapping.malForTmdbMovie(id) != null) {
      return MalMatch(mapping.malForTmdbMovie(id)!, MatchSource.tmdb);
    }
    return null;
  }

  // 4. TVDB / TMDB + season (season 1 for a whole series).
  final ids = isSeason ? input.seriesIds : input.ids;
  final s = season ?? 1;
  if (idOf(ids, 'tvdb') case final id?) {
    final list = mapping.malForTvdb(id, s);
    if (list.isNotEmpty) return MalMatch(list.first, MatchSource.tvdb, candidates: list);
  }
  if (idOf(ids, 'tmdb') case final id?) {
    final list = mapping.malForTmdbTv(id, s);
    if (list.isNotEmpty) return MalMatch(list.first, MatchSource.tmdb, candidates: list);
  }
  return null;
}
