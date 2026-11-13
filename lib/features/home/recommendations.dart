import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../seerr/seerr_health.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/library_api.dart';
import '../../core/seerr/seerr_api.dart';
import '../../core/seerr/seerr_discover.dart';
import '../../core/seerr/seerr_recommend.dart';
import '../library/library_providers.dart';
import '../../core/seerr/suggestion_filters.dart';
import '../seerr/seerr_providers.dart';
import 'suggestion_filters_store.dart';

/// How many of the strongest seeds recommendations / the profile use (each
/// is a Seerr call; Seerr caches TMDB).
const _seedsForRecommendations = 12;
const _seedsForProfile = 15;

/// What the user watches, as recommendation seeds (titles with a TMDB id):
/// favourites, finished titles, and shows in progress (Next up), newest
/// first within each. Kept for the app session.
final tasteSeedsProvider = FutureProvider<List<TasteSeed>>((ref) async {
  final api = ref.watch(libraryApiProvider);
  const types = [ItemType.series, ItemType.movie];
  final (favourites, finished, nextUp) = await (
    api.getItems(const ItemQuery(includeItemTypes: types, favoritesOnly: true, sortBy: SortField.datePlayed, descending: true), limit: 30),
    api.getItems(const ItemQuery(includeItemTypes: types, sortBy: SortField.datePlayed, descending: true, extraFilters: ['IsPlayed']), limit: 30),
    ref.watch(nextUpProvider.future),
  ).wait;
  // Shows being watched: their series (Next up lists episodes).
  final watching = await Future.wait([
    for (final id in {for (final e in nextUp.take(10)) ?e.seriesId}) api.getItemIds(id).then<BaseItem?>((s) => s, onError: (Object _) => null),
  ]);

  Iterable<TasteSeed> seeds(Iterable<BaseItem?> items, double weight) sync* {
    for (final (i, item) in items.nonNulls.indexed) {
      final tmdb = int.tryParse(item.providerIds['Tmdb'] ?? '');
      if (tmdb == null) continue;
      yield TasteSeed(
        type: item.type == ItemType.movie ? SeerrMediaType.movie : SeerrMediaType.tv,
        tmdbId: tmdb,
        name: item.name,
        // Recent titles count a little more.
        weight: weight * (1 - i / 60),
      );
    }
  }

  return mergeSeeds([...seeds(favourites.items, 3), ...seeds(finished.items, 2), ...seeds(watching, 1.5)]);
}, retry: (_, _) => null);

/// Seerr's recommendations for one seed, kept for the session.
final _seedRecommendationsProvider = FutureProvider.family<List<SeerrMedia>, (SeerrMediaType, int)>((ref, key) async {
  final api = ref.watch(seerrApiProvider);
  if (api == null) return const [];
  return api.recommendations(key.$1, key.$2);
}, retry: (_, _) => null);

/// Keys of titles to leave out: on the server (Seerr's status or the
/// library's TMDB ids).
Future<Set<String>> _onServer(Ref ref, Iterable<SeerrMedia> media) async {
  final index = await ref.watch(libraryTmdbIndexProvider.future).catchError((Object _) => const <String, String>{});
  return {
    for (final m in media)
      if (m.status == SeerrMediaStatus.available || serverItemFor(m, index) != null) m.key,
  };
}

/// Because you watched [seed] (or the strongest seed): its recommendations.
final becauseYouWatchedProvider = FutureProvider.autoDispose.family<({TasteSeed? seed, List<SeerrMedia> items}), SeerrRowSpec>((ref, spec) async {
  final filters = await ref.watch(suggestionFilterSetProvider(spec.filterSetId).future);
  final seeds = await ref.watch(tasteSeedsProvider.future);
  final chosen = spec.seed;
  final seed = chosen == null
      ? seeds.firstOrNull
      : seeds.where((s) => s.key == chosen.id).firstOrNull ?? _seedFromOption(chosen);
  if (seed == null) return (seed: null, items: const <SeerrMedia>[]);
  final recs = await ref.watch(_seedRecommendationsProvider((seed.type, seed.tmdbId)).future);
  final hidden = spec.hideAvailable ? await _onServer(ref, recs) : const <String>{};
  return (seed: seed, items: [for (final m in recs) if (!hidden.contains(m.key) && (filters?.allows(m) ?? true)) m]);
}, retry: (_, _) => null);

TasteSeed? _seedFromOption(SeerrOption o) {
  final [type, id] = o.id.split(':');
  final tmdb = int.tryParse(id);
  final t = SeerrMediaType.of(type);
  return tmdb == null || t == null ? null : TasteSeed(type: t, tmdbId: tmdb, name: o.name, weight: 1);
}

/// Recommendations of the strongest seeds, ranked by how many recommend
/// each title.
final recommendedForYouProvider =
    FutureProvider.autoDispose.family<List<SeerrMedia>, (bool hideAvailable, String filterSetId)>((ref, key) async {
  final (hideAvailable, filterSetId) = key;
  final filters = await ref.watch(suggestionFilterSetProvider(filterSetId).future);
  final seeds = (await ref.watch(tasteSeedsProvider.future)).take(_seedsForRecommendations).toList();
  final lists = await Future.wait([
    for (final s in seeds)
      ref.watch(_seedRecommendationsProvider((s.type, s.tmdbId)).future).catchError((Object _) => const <SeerrMedia>[]),
  ]);
  final bySeed = {
    for (final (i, s) in seeds.indexed) s: [for (final m in lists[i]) if (filters?.allows(m) ?? true) m],
  };
  final all = [for (final l in lists) ...l];
  return rankRecommendations(bySeed, exclude: hideAvailable ? await _onServer(ref, all) : const {});
}, retry: (_, _) => null);

/// The taste profile from the strongest seeds' Seerr details. Kept for
/// the session.
final tasteProfileProvider = FutureProvider<TasteProfile>((ref) async {
  final api = ref.watch(seerrApiProvider);
  if (api == null) return const TasteProfile();
  final seeds = (await ref.watch(tasteSeedsProvider.future)).take(_seedsForProfile).toList();
  Object? failure;
  final details = await Future.wait([
    for (final s in seeds)
      api.details(s.type, s.tmdbId).then<SeerrDetails?>((d) => d, onError: (Object e) {
        failure ??= e;
        return null;
      }),
  ]);
  // Seerr down: not an empty taste (kept for the session, so More for you
  // would stay a few rows short), but a failure that retries.
  if (seeds.isNotEmpty && details.every((d) => d == null) && failure != null) {
    return trackSeerr(() => ref.read(seerrReachableProvider.notifier), Future<TasteProfile>.error(failure!));
  }
  return buildTasteProfile([
    for (final (i, d) in details.indexed)
      if (d != null) (seeds[i].weight, d),
  ]);
}, retry: seerrRetry);

/// Picked for you: a discover query from the taste profile. [type] null =
/// whichever the user watches more (or the filter set's type).
final pickedForYouProvider = FutureProvider.autoDispose
    .family<({TasteProfile profile, List<SeerrMedia> items}), (SeerrMediaType?, bool, String)>((ref, key) async {
  final api = ref.watch(seerrApiProvider);
  final filters = await ref.watch(suggestionFilterSetProvider(key.$3).future);
  final profile = await ref.watch(tasteProfileProvider.future);
  if (api == null || profile.isEmpty) return (profile: profile, items: const <SeerrMedia>[]);
  final type = key.$1 ??
      switch (filters?.type) {
        SuggestionType.tv => SeerrMediaType.tv,
        SuggestionType.movie => SeerrMediaType.movie,
        _ => null,
      };
  var spec = pickedForYouSpec(profile, type: type, hideAvailable: key.$2);
  if (filters != null) spec = filters.applyTo(spec);
  var items = await api.row(spec);
  if (items.length < 6) {
    // Too narrow: drop the keywords and try again on genres alone.
    items = await api.row(SeerrRowSpec.fromJson({...spec.toJson(), 'keywords': <Object>[]}));
  }
  final hidden = key.$2 ? await _onServer(ref, items) : const <String>{};
  return (profile: profile, items: [for (final m in items) if (!hidden.contains(m.key) && (filters?.allows(m) ?? true)) m]);
}, retry: (_, _) => null);
