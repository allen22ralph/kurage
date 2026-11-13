import 'seerr_api.dart';
import 'seerr_discover.dart';

enum SuggestionType {
  both('TV & movies'),
  tv('TV only'),
  movie('Movies only');

  const SuggestionType(this.label);

  final String label;
}

/// Conditions every suggestion must meet (recommendation rows, "More for
/// you"): a named set, e.g. Anime = Animation + Japanese.
class SuggestionFilterSet {
  const SuggestionFilterSet({
    required this.id,
    required this.name,
    this.requireGenres = const [],
    this.languages = const [],
    this.requireKeywords = const [],
    this.excludeGenres = const [],
    this.excludeKeywords = const [],
    this.type = SuggestionType.both,
  });

  factory SuggestionFilterSet.fromJson(Map<String, dynamic> j) {
    List<SeerrOption> o(String k) => [for (final e in (j[k] as List?) ?? const []) SeerrOption.fromJson((e as Map).cast<String, dynamic>())];
    return SuggestionFilterSet(
      id: j['id'] as String,
      name: j['name'] as String,
      requireGenres: o('requireGenres'),
      languages: o('languages'),
      requireKeywords: o('requireKeywords'),
      excludeGenres: o('excludeGenres'),
      excludeKeywords: o('excludeKeywords'),
      type: SuggestionType.values.where((t) => t.name == j['type']).firstOrNull ?? SuggestionType.both,
    );
  }

  final String id;
  final String name;

  /// All of these genres (TMDB genre ids are shared by TV and movies for
  /// the common ones, e.g. 16 Animation).
  final List<SeerrOption> requireGenres;

  /// Any of these original languages.
  final List<SeerrOption> languages;

  /// Any of these keywords (discover rows only: results don't list them).
  final List<SeerrOption> requireKeywords;
  final List<SeerrOption> excludeGenres;

  /// Discover rows only.
  final List<SeerrOption> excludeKeywords;
  final SuggestionType type;

  bool get isEmpty =>
      requireGenres.isEmpty &&
      languages.isEmpty &&
      requireKeywords.isEmpty &&
      excludeGenres.isEmpty &&
      excludeKeywords.isEmpty &&
      type == SuggestionType.both;

  SuggestionFilterSet copyWith({
    String? name,
    List<SeerrOption>? requireGenres,
    List<SeerrOption>? languages,
    List<SeerrOption>? requireKeywords,
    List<SeerrOption>? excludeGenres,
    List<SeerrOption>? excludeKeywords,
    SuggestionType? type,
  }) =>
      SuggestionFilterSet(
        id: id,
        name: name ?? this.name,
        requireGenres: requireGenres ?? this.requireGenres,
        languages: languages ?? this.languages,
        requireKeywords: requireKeywords ?? this.requireKeywords,
        excludeGenres: excludeGenres ?? this.excludeGenres,
        excludeKeywords: excludeKeywords ?? this.excludeKeywords,
        type: type ?? this.type,
      );

  Map<String, dynamic> toJson() {
    List<Map<String, dynamic>> o(List<SeerrOption> l) => [for (final e in l) e.toJson()];
    return {
      'id': id,
      'name': name,
      'requireGenres': o(requireGenres),
      'languages': o(languages),
      'requireKeywords': o(requireKeywords),
      'excludeGenres': o(excludeGenres),
      'excludeKeywords': o(excludeKeywords),
      'type': type.name,
    };
  }

  /// Whether [m] passes (what the result says; unknown fields pass).
  bool allows(SeerrMedia m) {
    if (type == SuggestionType.tv && m.type != SeerrMediaType.tv) return false;
    if (type == SuggestionType.movie && m.type != SeerrMediaType.movie) return false;
    final genres = m.genreIds;
    if (genres != null) {
      if (requireGenres.any((g) => !genres.contains(int.tryParse(g.id)))) return false;
      if (excludeGenres.any((g) => genres.contains(int.tryParse(g.id)))) return false;
    }
    final lang = m.originalLanguage;
    if (lang != null && languages.isNotEmpty && !languages.any((l) => l.id == lang)) return false;
    return true;
  }

  /// [spec] (a discover query) with this set's conditions added, so pages
  /// come back already filtered.
  SeerrRowSpec applyTo(SeerrRowSpec spec) {
    if (!spec.source.isDiscover) return spec;
    final j = spec.toJson();
    List<Map<String, dynamic>> o(Iterable<SeerrOption> l) => [for (final e in l) e.toJson()];
    // TMDB can't say "(A or B) and C": a row matching any of its genres
    // ("Picked for you") gets only the required ones (all of); its other
    // signals (keywords, language) still steer it. A row of all-of genres
    // gets the required ones added.
    final List<SeerrOption> genres;
    final bool anyGenre;
    if (requireGenres.isEmpty) {
      (genres, anyGenre) = (spec.genres, spec.anyGenre);
    } else if (spec.anyGenre) {
      (genres, anyGenre) = (requireGenres, false);
    } else {
      (genres, anyGenre) = ({...spec.genres, ...requireGenres}.toList(), false);
    }
    return SeerrRowSpec.fromJson({
      ...j,
      'genres': o(genres),
      'anyGenre': anyGenre,
      if (spec.originalLanguages.isEmpty && languages.isNotEmpty) 'originalLanguages': o(languages),
      if (spec.keywords.isEmpty && requireKeywords.isNotEmpty) ...{'keywords': o(requireKeywords), 'anyKeyword': true},
      'excludeKeywords': o({...spec.excludeKeywords, ...excludeKeywords}),
    });
  }

  /// The discover source for generated rows of [preferTv] taste.
  SeerrSource discoverSource({required bool preferTv}) => switch (type) {
        SuggestionType.tv => SeerrSource.discoverTv,
        SuggestionType.movie => SeerrSource.discoverMovies,
        SuggestionType.both => preferTv ? SeerrSource.discoverTv : SeerrSource.discoverMovies,
      };
}

/// The sets a user starts with: Anime (the default) and no filters.
const defaultSuggestionFilterSets = [
  SuggestionFilterSet(
    id: 'anime',
    name: 'Anime',
    requireGenres: [SeerrOption('16', 'Animation')],
    languages: [SeerrOption('ja', 'Japanese')],
  ),
  SuggestionFilterSet(id: 'anything', name: 'Anything'),
];

/// Which filter set a row uses: the default one, a named one, or none.
const filterSetDefault = 'default';
const filterSetNone = 'none';
