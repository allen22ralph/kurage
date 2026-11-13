import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/core/jellyfin/library_api.dart';
import 'package:jellyfin_client/core/seerr/seerr_discover.dart';
import 'package:jellyfin_client/features/home/home_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

BaseItem _view(String id, String name, {String? type = 'tvshows'}) => BaseItem.fromJson(
      itemJson(id, name, type: 'CollectionFolder', extra: {'CollectionType': ?type}),
    );

void main() {
  final anime = _view('lib1', 'Anime');
  final movies = _view('lib2', 'Movies', type: 'movies');
  final music = _view('lib3', 'Music', type: 'music');

  test('the default layout is the old fixed home page', () {
    final rows = defaultHomeLayout([anime, movies, music]);
    expect([for (final r in rows) r.id], [
      'continueWatching',
      'nextUp',
      'thisWeek',
      'genres',
      'libraries',
      'recentlyAdded:lib1',
      'recentlyAdded:lib2', // no row for music
      'seerrTrending',
      'seerrPopularAnime',
      'seerrSeasonalAnime',
      'seerrUpcomingAnime',
    ]);
  });

  test('a saved layout follows the server: new libraries added, removed ones dropped, renames shown', () {
    final saved = [
      BuiltInRow(BuiltInKind.nextUp),
      BuiltInRow(BuiltInKind.recentlyAdded, libraryId: 'gone', libraryName: 'Old'),
      BuiltInRow(BuiltInKind.recentlyAdded, libraryId: 'lib1', libraryName: 'Old name', visible: false),
      const JellyfinHomeRow(id: 'custom-1', title: 'Unwatched anime'),
      BuiltInRow(BuiltInKind.continueWatching),
      BuiltInRow(BuiltInKind.libraries),
      for (final k in BuiltInKind.values.where((k) => k.isSeerr)) BuiltInRow(k),
    ];
    final rows = reconcileHomeLayout(saved, [anime, movies]);
    expect([for (final r in rows) r.id], [
      'nextUp',
      'thisWeek', // added in an update: after the row before it by default
      'genres',
      'recentlyAdded:lib1',
      'recentlyAdded:lib2', // new, after the other "recently added"
      'custom-1',
      'continueWatching',
      'libraries',
      'seerrTrending',
      'seerrPopularAnime',
      'seerrSeasonalAnime',
      'seerrUpcomingAnime',
    ]);
    final lib1 = rows[3] as BuiltInRow;
    expect((lib1.title, lib1.visible), ('Recently added in Anime', false));
  });

  test('rows survive a save / load round trip', () {
    final rows = <HomeRow>[
      BuiltInRow(BuiltInKind.recentlyAdded, libraryId: 'lib1', libraryName: 'Anime', visible: false),
      const JellyfinHomeRow(
        id: 'custom-1',
        title: 'In progress',
        libraryId: 'lib1',
        types: [ItemType.series, ItemType.movie],
        genres: ['Fantasy'],
        filter: JellyfinRowFilter.inProgress,
        sort: SortField.datePlayed,
        limit: 12,
        landscape: true,
      ),
      SeerrHomeRow(
        id: 'custom-2',
        title: 'Japanese originals',
        spec: SeerrRowSpec(
          originalLanguages: const [SeerrOption('ja', 'Japanese')],
          excludeKeywords: const [SeerrOption('210024', 'anime')],
          dateRange: SeerrDateRange.custom,
          dateFrom: DateTime(2020),
          ratingMin: 7.5,
          hideAvailable: true,
        ),
        limit: 15,
      ),
    ];
    final back = [for (final r in rows) HomeRow.fromJson(r.toJson())!];
    expect([for (final r in back) r.toJson()], [for (final r in rows) r.toJson()]);
    expect(back[1], rows[1], reason: 'equal settings, equal row (provider key)');
  });

  test('a Jellyfin row asks for its filters', () {
    const row = JellyfinHomeRow(
      id: 'x',
      title: 'x',
      libraryId: 'lib1',
      genres: ['Comedy', 'Drama'],
      filter: JellyfinRowFilter.inProgress,
      sort: SortField.communityRating,
    );
    final q = row.query.toQuery();
    expect(q['parentId'], 'lib1');
    expect(q['includeItemTypes'], 'Series');
    expect(q['genres'], 'Comedy|Drama');
    expect(q['filters'], 'IsResumable');
    expect(q['sortOrder'], 'Descending');
  });

  group('Seerr discover query', () {
    final today = DateTime(2026, 10, 28);

    test('TV: all of the filters, in Seerr / TMDB form', () {
      final spec = SeerrRowSpec(
        genres: const [SeerrOption('16', 'Animation'), SeerrOption('10765', 'Sci-Fi & Fantasy')],
        keywords: const [SeerrOption('210024', 'anime')],
        excludeKeywords: const [SeerrOption('1', 'x')],
        originalLanguages: const [SeerrOption('ja', 'Japanese'), SeerrOption('ko', 'Korean')],
        company: const SeerrOption('1112', 'Crunchyroll'),
        dateRange: SeerrDateRange.thisAnimeSeason,
        tvStatuses: const [0, 2],
        ratingMin: 7,
        votesMin: 100,
        runtimeMax: 30,
        watchProviders: const [SeerrOption('283', 'Crunchyroll')],
        watchRegion: 'IN',
        certifications: const ['TV-14', 'TV-MA'],
        sort: SeerrSort.rating,
      );
      expect(spec.discoverQuery(today), {
        'genre': '16,10765',
        'keywords': '210024',
        'excludeKeywords': '1',
        'language': 'ja|ko',
        'network': '1112',
        'firstAirDateGte': '2026-10-01',
        'firstAirDateLte': '2026-12-31',
        'status': '0|2',
        'voteAverageGte': 7.0,
        'voteCountGte': 100,
        'withRuntimeLte': 30,
        'watchRegion': 'IN',
        'watchProviders': '283',
        'certificationCountry': 'US',
        'certification': 'TV-14|TV-MA',
        'sortBy': 'vote_average.desc',
      });
    });

    test('movies use the studio and release-date names', () {
      final q = SeerrRowSpec(
        source: SeerrSource.discoverMovies,
        company: const SeerrOption('3', 'Pixar'),
        dateRange: SeerrDateRange.thisYear,
        sort: SeerrSort.releaseDate,
        descending: false,
      ).discoverQuery(today);
      expect(q['studio'], '3');
      expect((q['primaryReleaseDateGte'], q['primaryReleaseDateLte']), ('2026-01-01', '2026-12-31'));
      expect(q['sortBy'], 'primary_release_date.asc');
      expect(q.containsKey('status'), isFalse);
    });

    test('the next anime season rolls over the year', () {
      final (from, to) = const SeerrRowSpec(dateRange: SeerrDateRange.nextAnimeSeason).dates(DateTime(2026, 11, 2));
      expect((seerrDate(from!), seerrDate(to!)), ('2027-01-01', '2027-03-31'));
    });
  });
  test('an Expanding row asks for descriptions; a Shelf one doesn\'t need them', () async {
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    SharedPreferences.setMockInitialValues({});
    final server = FakeServer({'/Items': (200, pageJson([]))});
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await c.read(sessionControllerProvider.future);
    String fields() => server.requestsTo('/Items').last.queryParameters['fields'] as String;
    final sub = c.listen(jellyfinRowProvider(const JellyfinHomeRow(id: 'a', title: 'A', look: RowLook.expanding)), (_, _) {});
    addTearDown(sub.close);
    await c.read(jellyfinRowProvider(const JellyfinHomeRow(id: 'a', title: 'A', look: RowLook.expanding)).future);
    expect(fields(), contains('Overview'));
    final other = c.listen(jellyfinRowProvider(const JellyfinHomeRow(id: 'b', title: 'B')), (_, _) {});
    addTearDown(other.close);
    await c.read(jellyfinRowProvider(const JellyfinHomeRow(id: 'b', title: 'B')).future);
    expect(fields(), isNot(contains('Overview')));
  });
}
