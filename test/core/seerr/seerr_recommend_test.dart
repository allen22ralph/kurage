import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/seerr/seerr_api.dart';
import 'package:jellyfin_client/core/seerr/seerr_discover.dart';
import 'package:jellyfin_client/core/seerr/seerr_recommend.dart';

SeerrMedia _tv(int id, {SeerrMediaStatus status = SeerrMediaStatus.unknown}) =>
    SeerrMedia(tmdbId: id, type: SeerrMediaType.tv, title: 'Show $id', status: status);

TasteSeed _seed(int id, String name, double w) =>
    TasteSeed(type: SeerrMediaType.tv, tmdbId: id, name: name, weight: w);

SeerrDetails _details(int id, {List<int> genres = const [], List<int> keywords = const [], String lang = 'ja', List<int> networks = const []}) =>
    SeerrDetails(
      media: _tv(id),
      genres: [for (final g in genres) (id: g, name: 'G$g')],
      keywords: [for (final k in keywords) (id: k, name: 'k$k')],
      originalLanguage: lang,
      companies: [for (final n in networks) (id: n, name: 'N$n')],
    );

void main() {
  test('seeds merge by title, strongest first', () {
    final seeds = mergeSeeds([_seed(1, 'A', 2), _seed(2, 'B', 3), _seed(1, 'A', 2)]);
    expect([for (final s in seeds) (s.name, s.weight)], [('A', 4.0), ('B', 3.0)]);
  });

  test('recommended by more of your shows ranks first, and says so', () {
    final frieren = _seed(1, 'Frieren', 3);
    final mushoku = _seed(2, 'Mushoku Tensei', 2);
    final ranked = rankRecommendations({
      frieren: [_tv(10), _tv(11), _tv(2)], // 2 is a seed itself: left out
      mushoku: [_tv(11), _tv(12)],
    }, exclude: {'tv:12'});
    expect([for (final m in ranked) m.tmdbId], [11, 10]);
    expect(ranked.first.note, 'Recommended by 2 of your shows');
    expect(ranked.last.note, 'Because you watched Frieren');
  });

  test('the taste profile weighs what keeps coming up', () {
    final p = buildTasteProfile([
      (3, _details(1, genres: [16, 10765], keywords: [210024, 9], networks: [1])),
      (2, _details(2, genres: [16, 18], keywords: [210024, 8], networks: [1])),
      (1, _details(3, genres: [16], keywords: [7], lang: 'ko')),
    ]);
    expect(p.topGenres().map((g) => g.id), ['16', '10765', '18']);
    expect(p.topKeywords().map((k) => k.id), ['210024'], reason: 'one-off keywords dropped');
    expect(p.mainLanguage, 'ja');
    expect(p.topCompanies(1).single.id, '1');
    expect(p.summary(languageNames: const {'ja': 'Japanese'}), 'G16 · G10765 · K210024 · Japanese');
  });

  test('picked for you asks discover for any of the top genres / keywords, well rated', () {
    final p = buildTasteProfile([
      (3, _details(1, genres: [16, 10765], keywords: [210024])),
      (2, _details(2, genres: [16], keywords: [210024])),
      (1, _details(3, genres: [35], keywords: [5])),
    ]);
    final q = pickedForYouSpec(p).discoverQuery(DateTime(2026, 10, 28));
    expect(q['genre'], '16|10765|35');
    expect(q['keywords'], '210024');
    expect(q['language'], 'ja');
    expect((q['voteAverageGte'], q['voteCountGte']), (7.0, 50));
    expect(pickedForYouSpec(p).source, SeerrSource.discoverTv);
  });
}
