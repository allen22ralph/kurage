import 'seerr_api.dart';
import 'seerr_discover.dart';

/// A title from the user's library that recommendations start from, with
/// how much it says about their taste (favourite > finished > watching).
class TasteSeed {
  const TasteSeed({required this.type, required this.tmdbId, required this.name, required this.weight});

  final SeerrMediaType type;
  final int tmdbId;
  final String name;
  final double weight;

  String get key => '${type.name}:$tmdbId';

  TasteSeed withWeight(double weight) => TasteSeed(type: type, tmdbId: tmdbId, name: name, weight: weight);
}

/// Seeds merged by title (weights add up), strongest first.
List<TasteSeed> mergeSeeds(Iterable<TasteSeed> seeds) {
  final merged = <String, TasteSeed>{};
  for (final s in seeds) {
    final old = merged[s.key];
    merged[s.key] = old == null ? s : old.withWeight(old.weight + s.weight);
  }
  return merged.values.toList()..sort((a, b) => b.weight.compareTo(a.weight));
}

/// Recommendations for several seeds as one ranking: titles recommended by
/// more (and stronger) seeds first. Leaves out the seeds themselves and
/// anything in [exclude] (keys, e.g. titles on the server). Each title
/// notes why: "Because you watched X" or "Recommended by N of your shows".
List<SeerrMedia> rankRecommendations(
  Map<TasteSeed, List<SeerrMedia>> bySeed, {
  Set<String> exclude = const {},
}) {
  final seedKeys = {for (final s in bySeed.keys) s.key};
  final score = <String, double>{};
  final from = <String, List<TasteSeed>>{};
  final media = <String, SeerrMedia>{};
  for (final MapEntry(key: seed, value: recs) in bySeed.entries) {
    for (final (i, m) in recs.indexed) {
      if (seedKeys.contains(m.key) || exclude.contains(m.key)) continue;
      media.putIfAbsent(m.key, () => m);
      // Earlier in a seed's list = closer match.
      score[m.key] = (score[m.key] ?? 0) + seed.weight * (1 - i / (recs.length + 1));
      (from[m.key] ??= []).add(seed);
    }
  }
  final keys = score.keys.toList()
    ..sort((a, b) {
      final byCount = from[b]!.length.compareTo(from[a]!.length);
      return byCount != 0 ? byCount : score[b]!.compareTo(score[a]!);
    });
  return [
    for (final k in keys)
      media[k]!.withNote(from[k]!.length == 1
          ? 'Because you watched ${from[k]!.single.name}'
          : 'Recommended by ${from[k]!.length} of your shows'),
  ];
}

/// What keeps coming up in the user's favourite / watched titles.
class TasteProfile {
  const TasteProfile({
    this.genres = const {},
    this.keywords = const {},
    this.languages = const {},
    this.companies = const {},
    this.tvShare = 0.5,
  });

  /// id -> (name, weight).
  final Map<int, (String, double)> genres;
  final Map<int, (String, double)> keywords;
  final Map<String, double> languages;
  final Map<int, (String, double)> companies;

  /// How much of the taste is TV (vs. movies), 0–1.
  final double tvShare;

  bool get isEmpty => genres.isEmpty && keywords.isEmpty;

  static List<SeerrOption> _top(Map<int, (String, double)> m, int n) =>
      ((m.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2))).take(n))
          .map((e) => SeerrOption('${e.key}', e.value.$1))
          .toList();

  List<SeerrOption> topGenres([int n = 3]) => _top(genres, n);
  List<SeerrOption> topKeywords([int n = 5]) => _top(keywords, n);
  List<SeerrOption> topCompanies([int n = 3]) => _top(companies, n);

  /// The main original language, if it's most of what's watched.
  String? get mainLanguage {
    if (languages.isEmpty) return null;
    final total = languages.values.fold(0.0, (a, b) => a + b);
    final top = languages.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return top.value / total >= 0.5 ? top.key : null;
  }

  /// "Fantasy · Isekai · Japanese", for "why these?".
  String summary({Map<String, String> languageNames = const {}}) => [
        ...topGenres(2).map((g) => g.name),
        ...topKeywords(2).map((k) => _title(k.name)),
        ?(mainLanguage == null ? null : (languageNames[mainLanguage] ?? mainLanguage!.toUpperCase())),
      ].join(' · ');

  static String _title(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// Genres, keywords, languages and networks / studios of [titles], each
/// weighted by how much its seed says about the user's taste. Very common
/// keywords ("based on manga") are kept; one-offs are dropped.
TasteProfile buildTasteProfile(List<(double weight, SeerrDetails details)> titles) {
  final genres = <int, (String, double)>{};
  final keywords = <int, (String, double)>{};
  final keywordSeen = <int, int>{};
  final companies = <int, (String, double)>{};
  final languages = <String, double>{};
  var tv = 0.0, all = 0.0;
  void add(Map<int, (String, double)> m, ({int id, String name}) e, double w) =>
      m[e.id] = (e.name, (m[e.id]?.$2 ?? 0) + w);
  for (final (w, d) in titles) {
    all += w;
    if (d.media.type == SeerrMediaType.tv) tv += w;
    for (final g in d.genres) {
      add(genres, g, w);
    }
    for (final k in d.keywords) {
      add(keywords, k, w);
      keywordSeen[k.id] = (keywordSeen[k.id] ?? 0) + 1;
    }
    // Networks only (TV): "From <network>" rows ask discover by network.
    if (d.media.type == SeerrMediaType.tv) {
      for (final c in d.companies) {
        add(companies, c, w);
      }
    }
    if (d.originalLanguage case final l?) languages[l] = (languages[l] ?? 0) + w;
  }
  // A keyword from a single title says little about taste.
  if (titles.length > 2) keywords.removeWhere((id, _) => (keywordSeen[id] ?? 0) < 2);
  return TasteProfile(
    genres: genres,
    keywords: keywords,
    languages: languages,
    companies: companies,
    tvShare: all == 0 ? 0.5 : tv / all,
  );
}

/// A discover query for titles matching the profile: any of the top genres
/// and keywords, the main language, well rated with enough votes.
SeerrRowSpec pickedForYouSpec(TasteProfile p, {SeerrMediaType? type, bool hideAvailable = true}) => SeerrRowSpec(
      source: (type ?? (p.tvShare >= 0.5 ? SeerrMediaType.tv : SeerrMediaType.movie)) == SeerrMediaType.tv
          ? SeerrSource.discoverTv
          : SeerrSource.discoverMovies,
      genres: p.topGenres(3),
      anyGenre: true,
      keywords: p.topKeywords(5),
      anyKeyword: true,
      originalLanguages: [if (p.mainLanguage case final l?) SeerrOption(l, l)],
      ratingMin: 7,
      votesMin: 50,
      sort: SeerrSort.popularity,
      hideAvailable: hideAvailable,
    );
