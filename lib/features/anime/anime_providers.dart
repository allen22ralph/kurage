import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/anime/aniskip.dart';
import '../../core/anime/anime_ids.dart';
import '../../core/anime/anime_info.dart';
import '../../core/anime/episode_scores.dart';
import '../../core/anime/anime_matcher.dart';
import '../../app/providers.dart';
import '../../core/anime/mal_sync.dart';
import '../../core/jellyfin/playback_api.dart';
import '../../core/jellyfin/items.dart';
import 'anime_settings.dart';
import 'mal_account.dart';
import '../library/library_providers.dart';
import '../../core/log/app_log.dart';

/// Where anime data is cached. Overridden in tests.
final animeCacheDirProvider = FutureProvider<Directory>((ref) async {
  final base = await getApplicationSupportDirectory();
  return Directory('${base.path}${Platform.pathSeparator}anime');
});

final animeIdMappingProvider = FutureProvider<AnimeIdMapping>((ref) async {
  final dir = await ref.watch(animeCacheDirProvider.future);
  return AnimeIdMappingSource(cacheDir: dir, dio: ref.watch(dioFactoryProvider)()).load();
}, retry: (count, _) => count < 3 ? Duration(seconds: 30 << count) : null);

final aniSkipApiProvider = Provider<AniSkipApi>((ref) {
  final dio = ref.watch(dioFactoryProvider)()..options.baseUrl = 'https://api.aniskip.com/v2';
  return AniSkipApi(dio: dio);
});

/// AniSkip segments for an episode, when the user allows it and the
/// episode matches a MAL entry.
Future<List<MediaSegment>> aniSkipSegments(ProviderContainer ref, BaseItem episode) async {
  final number = episode.indexNumber;
  if (episode.type != ItemType.episode || number == null) return const [];
  if (!(await ref.read(animeSettingsProvider.future)).useAniSkip) return const [];
  final match = await ref.read(malMatchProvider(animeKeyOf(episode)).future);
  if (match == null) return const [];
  final (malId, malEpisode) = await resolveMalEpisode(
    match.entries,
    number,
    (id) async => (await ref.read(animeInfoProvider(id).future))?.episodes,
  );
  return ref.read(aniSkipApiProvider).skipTimes(malId, malEpisode, episodeLength: episode.runtime);
}

final jikanApiProvider = Provider<JikanApi>((ref) {
  final dio = ref.watch(dioFactoryProvider)()
    ..options.baseUrl = 'https://api.jikan.moe/v4'
    // Fail fast when Jikan is down, so the next source gets a turn.
    ..options.connectTimeout = const Duration(seconds: 6);
  return JikanApi(dio: dio);
});

/// The official MAL API, once there's a client ID; null before that.
final malInfoApiProvider = FutureProvider<MalInfoApi?>((ref) async {
  final clientId = await ref.watch(malClientIdProvider.future);
  if (clientId.isEmpty) return null;
  return MalInfoApi(
    clientId: clientId,
    dio: ref.watch(dioFactoryProvider)()..options.baseUrl = 'https://api.myanimelist.net/v2',
  );
});

/// MAL details sources in order: the official API (when set up), then Jikan.
final animeInfoSourcesProvider = FutureProvider<List<AnimeInfoSource>>((ref) async => [
      ?await ref.watch(malInfoApiProvider.future),
      ref.watch(jikanApiProvider),
    ]);

/// Searches MyAnimeList, trying each source until one answers.
Future<List<AnimeInfo>> searchAnime(WidgetRef ref, String query) async {
  Object? error;
  for (final source in await ref.read(animeInfoSourcesProvider.future)) {
    try {
      return await source.search(query);
    } on Object catch (e) {
      error = e;
    }
  }
  throw error ?? StateError('No MyAnimeList source');
}

final animeInfoCacheProvider = FutureProvider<AnimeInfoCache>((ref) async {
  return AnimeInfoCache(cacheDir: await ref.watch(animeCacheDirProvider.future));
});

/// MAL details for [malId]: cache if fresh, else the official API, else
/// Jikan, else a stale cache.
final animeInfoProvider = FutureProvider.family<AnimeInfo?, int>((ref, malId) async {
  final cache = await ref.watch(animeInfoCacheProvider.future);
  final cached = await cache.get(malId);
  if (cached != null && cached.fresh) return cached.info;
  for (final source in await ref.watch(animeInfoSourcesProvider.future)) {
    try {
      final info = await source.anime(malId);
      await cache.put(info);
      return info;
    } on Object {
      continue; // try the next source
    }
  }
  return cached?.info;
}, retry: _noRetry);

final episodeScoresApiProvider = Provider<EpisodeScoresApi>((ref) => EpisodeScoresApi(
      site: ref.watch(dioFactoryProvider)()
        ..options.baseUrl = 'https://myanimelist.net'
        ..options.headers['User-Agent'] = 'Mozilla/5.0 (Kurage)',
      jikan: ref.watch(jikanApiProvider),
    ));

/// One page of a MAL entry's episodes (titles, ratings), kept for the
/// session (they change slowly).
final _episodesPageProvider =
    FutureProvider.family<Map<int, MalEpisode>, (int malId, int page)>((ref, key) async {
  final (malId, page) = key;
  return ref.watch(episodeScoresApiProvider).page(malId, page * EpisodeScoresApi.pageSize + 1);
}, retry: _noRetry);

/// What MAL lists for episode [number] of the season or show [key]
/// belongs to; null if unmatched, not listed or unreachable.
final malEpisodeProvider =
    FutureProvider.autoDispose.family<MalEpisode?, (AnimeKey key, int number)>((ref, args) async {
  final (key, number) = args;
  final match = await ref.watch(malMatchProvider(key).future);
  if (match == null) return null;
  // Split-cour seasons: find the MAL entry and its own episode number,
  // on into the sequel when the match stops short (a show matched to its
  // first cour only).
  final (malId, episode) = await resolveMalEpisode(
    match.entries,
    number,
    (id) async => (await ref.watch(animeInfoProvider(id).future))?.episodes,
    sequelOf: (id) => ref.watch(malSequelProvider(id).future),
  );
  if (malId != match.entries.last || episode != number) {
    AppLog.debug(LogArea.anime, 'Episode $number of ${key.itemId}: MAL entry $malId, episode $episode');
  }
  try {
    final page = (episode - 1) ~/ EpisodeScoresApi.pageSize;
    return (await ref.watch(_episodesPageProvider((malId, page)).future))[episode];
  } on Object {
    return null;
  }
}, retry: _noRetry);

/// MAL's sequel of an entry (its next cour); null if none or unknown.
/// Kept for the session.
final malSequelProvider = FutureProvider.family<int?, int>((ref, malId) async {
  try {
    return await ref.watch(jikanApiProvider).sequel(malId);
  } on Object {
    return null;
  }
}, retry: _noRetry);

/// MAL's community rating (1–5) for an episode; null if unknown.
final episodeScoreProvider = FutureProvider.autoDispose.family<double?, (AnimeKey key, int number)>(
  (ref, args) async => (await ref.watch(malEpisodeProvider(args).future))?.score,
  retry: _noRetry,
);

/// MAL details for a whole show (by its Jellyfin series ID), as its own
/// page shows them. An episode's name for its show comes from here, not
/// from its season's entry ("… Season 2"), which the S·E label covers.
final seriesAnimeInfoProvider = FutureProvider.family<AnimeInfo?, String>((ref, seriesId) async {
  final series = await ref.watch(libraryApiProvider).getItemIds(seriesId);
  return (await ref.watch(animeForItemProvider(animeKeyOf(series)).future))?.info;
}, retry: _noRetry);

/// Manual "fix match" choices: Jellyfin item ID → MAL ID.
final malOverridesProvider =
    AsyncNotifierProvider<MalOverridesController, Map<String, int>>(MalOverridesController.new);

class MalOverridesController extends AsyncNotifier<Map<String, int>> {
  static const _key = 'anime.malOverrides';

  @override
  Future<Map<String, int>> build() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return {};
    return {
      for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries) e.key: e.value as int,
    };
  }

  Future<void> set(String itemId, int? malId) async {
    // Wait for the stored map, or the initial load would overwrite this.
    final next = {...await future};
    if (malId == null) {
      next.remove(itemId);
    } else {
      next[itemId] = malId;
    }
    state = AsyncData(next);
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(next));
  }
}

/// What identifies an item for matching. A record, so it works as a
/// provider key (equal fields = same lookup).
typedef AnimeKey = ({
  String itemId,
  ItemType type,
  String? seriesId,
  String? seasonId,
  int? seasonNumber,
  String providerIds,
});

AnimeKey animeKeyOf(BaseItem item) {
  final ids = [for (final e in item.providerIds.entries) '${e.key}=${e.value}']..sort();
  return (
    itemId: item.id,
    type: item.type,
    seriesId: item.seriesId,
    seasonId: item.seasonId,
    seasonNumber: switch (item.type) {
      ItemType.season => item.indexNumber,
      ItemType.episode => item.parentIndexNumber,
      _ => null,
    },
    providerIds: ids.join('&'),
  );
}

Map<String, String> _idsOf(String encoded) => {
      for (final pair in encoded.split('&'))
        if (pair.contains('=')) pair.substring(0, pair.indexOf('=')): pair.substring(pair.indexOf('=') + 1),
    };

/// Provider IDs of a series or season, fetched once per session. A failed
/// lookup means "no IDs" (unmatched), not an error to retry.
final _parentIdsProvider = FutureProvider.family<Map<String, String>, String>((ref, id) async {
  ref.keepAlive();
  try {
    return (await ref.watch(libraryApiProvider).getItemIds(id)).providerIds;
  } on Object {
    return const {};
  }
}, retry: _noRetry);

/// Matching is best-effort: Riverpod's automatic retries would only hammer
/// Jikan or the server for things that aren't there.
Duration? _noRetry(int retryCount, Object error) => null;

/// The item's MAL entry, or null when it can't be matched (or isn't anime).
/// Episodes and seasons match through their season; the override for the
/// season (or the series, for a whole show) applies.
final malMatchProvider = FutureProvider.family<MalMatch?, AnimeKey>((ref, key) async {
  if (!const {ItemType.series, ItemType.season, ItemType.episode, ItemType.movie}
      .contains(key.type)) {
    return null;
  }
  final mapping = await ref.watch(animeIdMappingProvider.future);
  final overrides = await ref.watch(malOverridesProvider.future);

  if (key.type == ItemType.series || key.type == ItemType.movie) {
    return matchMal(
      MatchInput(ids: _idsOf(key.providerIds), isMovie: key.type == ItemType.movie),
      mapping,
      manual: overrides[key.itemId],
    );
  }

  final seasonId = key.type == ItemType.season ? key.itemId : key.seasonId;
  final seriesIds = key.seriesId == null
      ? const <String, String>{}
      : await ref.watch(_parentIdsProvider(key.seriesId!).future);
  // An episode's own IDs are episode IDs; use its season's.
  final seasonIds = key.type == ItemType.season
      ? _idsOf(key.providerIds)
      : seasonId == null
          ? const <String, String>{}
          : await ref.watch(_parentIdsProvider(seasonId).future);
  return matchMal(
    MatchInput(ids: seasonIds, seriesIds: seriesIds, seasonNumber: key.seasonNumber ?? 1),
    mapping,
    manual: seasonId == null ? null : overrides[seasonId],
  );
}, retry: _noRetry);

/// The item's MAL match and details, for display.
final animeForItemProvider =
    FutureProvider.family<({MalMatch match, AnimeInfo? info})?, AnimeKey>((ref, key) async {
  final match = await ref.watch(malMatchProvider(key).future);
  if (match == null) return null;
  return (match: match, info: await ref.watch(animeInfoProvider(match.malId).future));
}, retry: _noRetry);
