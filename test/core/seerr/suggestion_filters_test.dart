import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/seerr/seerr_api.dart';
import 'package:jellyfin_client/core/seerr/seerr_discover.dart';
import 'package:jellyfin_client/core/seerr/suggestion_filters.dart';

SeerrMedia _m(SeerrMediaType type, {List<int>? genres, String? lang}) =>
    SeerrMedia(tmdbId: 1, type: type, title: 'x', genreIds: genres, originalLanguage: lang);

void main() {
  final anime = defaultSuggestionFilterSets.first;

  test('Anime (the default set): Animation and Japanese, unknown fields pass', () {
    expect(anime.allows(_m(SeerrMediaType.tv, genres: [16, 10765], lang: 'ja')), isTrue);
    expect(anime.allows(_m(SeerrMediaType.tv, genres: [18], lang: 'ja')), isFalse, reason: 'live action');
    expect(anime.allows(_m(SeerrMediaType.tv, genres: [16], lang: 'en')), isFalse, reason: 'western animation');
    expect(anime.allows(_m(SeerrMediaType.movie)), isTrue, reason: 'result said nothing');
  });

  test('type and never-show genres', () {
    const s = SuggestionFilterSet(id: 'k', name: 'K', excludeGenres: [SeerrOption('16', 'Animation')], type: SuggestionType.tv);
    expect(s.allows(_m(SeerrMediaType.tv, genres: [18])), isTrue);
    expect(s.allows(_m(SeerrMediaType.tv, genres: [16, 18])), isFalse);
    expect(s.allows(_m(SeerrMediaType.movie, genres: [18])), isFalse);
  });

  test('applied to a discover query', () {
    final today = DateTime(2026, 10, 28);
    // "Picked for you" style (any of its genres): the required genre wins.
    final picked = anime.applyTo(const SeerrRowSpec(
      genres: [SeerrOption('18', 'Drama'), SeerrOption('10765', 'Fantasy')],
      anyGenre: true,
      excludeKeywords: [SeerrOption('1', 'a')],
    ));
    var q = picked.discoverQuery(today);
    expect((q['genre'], q['language']), ('16', 'ja'));
    // An all-of row gets the required genre added; its own language stays.
    const withKeywords = SuggestionFilterSet(id: 'x', name: 'x', requireGenres: [SeerrOption('16', 'Animation')], excludeKeywords: [SeerrOption('2', 'b')]);
    q = withKeywords.applyTo(const SeerrRowSpec(genres: [SeerrOption('10765', 'Fantasy')], originalLanguages: [SeerrOption('ko', 'Korean')], excludeKeywords: [SeerrOption('1', 'a')])).discoverQuery(today);
    expect((q['genre'], q['language'], q['excludeKeywords']), ('10765,16', 'ko', '1,2'));
  });
}
