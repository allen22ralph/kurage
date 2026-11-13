import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderOrFamily;

import '../../app/providers.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/library_api.dart';
import '../watchlist/watchlist_providers.dart';

final libraryApiProvider = Provider<LibraryApi>((ref) {
  final api = ref.watch(signedInApiProvider);
  final session = ref.watch(currentSessionProvider);
  return LibraryApi(api, userId: session.userId);
});

final viewsProvider = FutureProvider<List<BaseItem>>(
  (ref) => ref.watch(libraryApiProvider).getViews(),
);

/// Backdrops from a library's own titles, for its door on Home. Empty when
/// they can't be had: the door falls back to the library's own picture.
final libraryBackdropsProvider = FutureProvider.family<List<ImageRef>, ({String id, String? collectionType})>(
  (ref, library) async {
    final items = await ref
        .watch(libraryApiProvider)
        .getRandomWithBackdrop(library.id, itemTypesForCollection(library.collectionType));
    return [for (final item in items) ?item.backdropImage];
  },
  retry: (_, _) => null,
);

final resumeProvider = FutureProvider<List<BaseItem>>(
  (ref) => ref.watch(libraryApiProvider).getResume(),
);

final nextUpProvider = FutureProvider<List<BaseItem>>(
  (ref) => ref.watch(libraryApiProvider).getNextUp(),
);

final latestProvider = FutureProvider.family<List<BaseItem>, String>(
  (ref, parentId) => ref.watch(libraryApiProvider).getLatest(parentId),
);

final itemProvider = FutureProvider.autoDispose.family<BaseItem, String>(
  (ref, id) => ref.watch(libraryApiProvider).getItem(id),
);

final seasonsProvider = FutureProvider.autoDispose.family<List<BaseItem>, String>(
  (ref, seriesId) => ref.watch(libraryApiProvider).getSeasons(seriesId),
);

final episodesProvider = FutureProvider.autoDispose
    .family<List<BaseItem>, ({String seriesId, String? seasonId})>(
  (ref, key) => ref
      .watch(libraryApiProvider)
      .getEpisodes(key.seriesId, seasonId: key.seasonId),
);

/// An item's trailer files of its own.
final localTrailersProvider = FutureProvider.autoDispose.family<List<BaseItem>, String>(
  (ref, id) => ref.watch(libraryApiProvider).getLocalTrailers(id),
);

final similarProvider = FutureProvider.autoDispose.family<List<BaseItem>, String>(
  (ref, id) => ref.watch(libraryApiProvider).getSimilar(id),
);

final genresProvider = FutureProvider.autoDispose.family<List<String>, String?>(
  (ref, parentId) => ref.watch(libraryApiProvider).getGenres(parentId),
);

/// Every genre across the libraries, for Browse by genre on Home. Not retried by
/// itself (it's no more than a row): Home's Refresh, or the next start, asks again.
final homeGenresProvider = FutureProvider<List<String>>(
  (ref) => ref.watch(libraryApiProvider).getGenres(null),
  retry: (_, _) => null,
);

/// The genres of [ItemType] across all libraries (the Movies and Shows tabs).
final genresOfTypeProvider = FutureProvider.autoDispose.family<List<String>, ItemType>(
  (ref, type) => ref.watch(libraryApiProvider).getGenres(null, type: type),
);

final nextUpForSeriesProvider =
    FutureProvider.autoDispose.family<BaseItem?, String>((ref, seriesId) async {
  final items =
      await ref.watch(libraryApiProvider).getNextUp(seriesId: seriesId, limit: 1);
  return items.firstOrNull;
});

/// Where a show starts: the first episode there is of its first season, past
/// the specials (unless it only has specials).
final firstEpisodeProvider = FutureProvider.autoDispose.family<BaseItem?, String>(
  (ref, seriesId) => firstEpisodeOf(ref.watch(libraryApiProvider), seriesId),
);

Future<BaseItem?> firstEpisodeOf(LibraryApi api, String seriesId) async {
  final seasons = await api.getSeasons(seriesId);
  final season = seasons.where((s) => s.indexNumber != 0).firstOrNull ?? seasons.firstOrNull;
  if (season == null) return null;
  final episodes = await api.getEpisodes(seriesId, seasonId: season.id, limit: 5);
  return episodes.where((e) => !e.isVirtual).firstOrNull;
}

/// A show's main button, in any theme: the episode it plays, and what it says.
/// Resume one part-way through, Continue with the next, Start one not begun,
/// Watch again once it's all watched. Null until that's known, or with no
/// episodes.
({BaseItem episode, String verb})? seriesMainAction(WidgetRef ref, String seriesId) {
  final nextUp = ref.watch(nextUpForSeriesProvider(seriesId));
  final firstUp = ref.watch(firstEpisodeProvider(seriesId));
  // (Nothing until both are known: the label would change as they arrive.)
  if (!nextUp.hasValue || !firstUp.hasValue) return null;
  final first = firstUp.value;
  final next = nextUp.value;
  final episode = next ?? first;
  if (episode == null) return null;
  final verb = episode.userData.hasProgress
      ? 'Resume'
      : next == null
          ? (episode.userData.played ? 'Watch again' : 'Start')
          : (episode.id == first?.id ? 'Start' : 'Continue');
  return (episode: episode, verb: verb);
}

/// Reloads everything that shows watch progress, e.g. after playback or
/// marking items watched. Pass `ref.invalidate` from a `Ref` or `WidgetRef`.
void refreshWatchState(void Function(ProviderOrFamily) invalidate) {
  invalidate(resumeProvider);
  invalidate(nextUpProvider);
  invalidate(latestProvider);
  invalidate(itemProvider);
  invalidate(episodesProvider);
  invalidate(seasonsProvider);
  invalidate(nextUpForSeriesProvider);
  invalidate(firstEpisodeProvider);
  invalidate(watchlistProvider);
  // A playlist's entries carry their watched state too.
  invalidate(playlistItemsProvider);
}

/// A playlist's entries, in its order (each with its PlaylistItemId).
final playlistItemsProvider = FutureProvider.autoDispose.family<List<BaseItem>, String>(
  (ref, id) => ref.watch(libraryApiProvider).getPlaylistItems(id),
);
