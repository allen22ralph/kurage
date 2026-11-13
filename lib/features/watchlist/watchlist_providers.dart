import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/log/app_log.dart';
import '../../core/jellyfin/items.dart';
import '../library/library_providers.dart';

/// Everything on the user's watchlist (Jellyfin's "liked" flag).
final watchlistProvider = FutureProvider.autoDispose<List<BaseItem>>((ref) async {
  final items = await ref.watch(libraryApiProvider).getWatchlist();
  // What the server said, so a list that changes by itself can be traced.
  AppLog.info(LogArea.app, 'Watchlist: ${items.length} from the server (${[for (final i in items) i.name].join(', ')})');
  return items;
});

/// What can go on the watchlist: as KefinTweaks' web watchlist, movies,
/// shows, seasons and episodes.
bool canWatchlist(BaseItem item) => const {
  ItemType.movie,
  ItemType.series,
  ItemType.season,
  ItemType.episode,
}.contains(item.type);

final watchlistOrderProvider =
    AsyncNotifierProvider<WatchlistOrderController, List<String>>(
      WatchlistOrderController.new,
    );

/// The user's own order for the watchlist, as item ids, top first. The
/// "liked" flag has no order, so it's kept in the account's display
/// preferences for this app: the same on every device signed in as the user.
class WatchlistOrderController extends AsyncNotifier<List<String>> {
  static const preferencesId = 'jellyfin-client-watchlist';
  static const client = 'jellyfin-client';
  static const _pref = 'order';

  @override
  Future<List<String>> build() async {
    try {
      final prefs = await ref
          .read(signedInApiProvider)
          .getJson('/DisplayPreferences/$preferencesId', query: _query);
      final raw = (prefs['CustomPrefs'] as Map?)?[_pref];
      if (raw is! String || raw.isEmpty) return const [];
      return [for (final id in jsonDecode(raw) as List) '$id'];
    } on Object catch (e) {
      debugPrint('Watchlist order from the account: $e');
      return const [];
    }
  }

  Map<String, String> get _query => {
    'userId': ref.read(currentSessionProvider).userId,
    'client': client,
  };

  /// Moves [id] to just before [before] (null: to the end of [after]'s
  /// run, or the very top when that's null too), for everything in [items].
  Future<void> move(
    List<BaseItem> items,
    String id, {
    String? before,
    String? after,
  }) async {
    final order = [
      for (final i in arrange(items, state.value ?? const [])) i.id,
    ]..remove(id);
    final at = before != null
        ? order.indexOf(before)
        : after != null
        ? order.indexOf(after) + 1
        : 0;
    order.insert(at < 0 ? order.length : at, id);
    state = AsyncData(order);
    await _save(order);
  }

  Future<void> _save(List<String> order) async {
    try {
      await ref
          .read(signedInApiProvider)
          .postJson(
            '/DisplayPreferences/$preferencesId',
            query: _query,
            body: {
              'Id': preferencesId,
              'Client': client,
              'SortOrder': 'Ascending',
              'RememberIndexing': false,
              'RememberSorting': false,
              'ScrollDirection': 'Horizontal',
              'ShowBackdrop': true,
              'ShowSidebar': false,
              'PrimaryImageHeight': 250,
              'PrimaryImageWidth': 250,
              'CustomPrefs': {_pref: jsonEncode(order)},
            },
          );
    } on Object catch (e) {
      debugPrint('Watchlist order to the account: $e');
    }
  }
}

/// [items] in the user's [order]. What isn't in it yet (added since, or
/// from the web) comes first, newest release first, as the web list shows.
List<BaseItem> arrange(List<BaseItem> items, List<String> order) {
  final rank = {for (final (i, id) in order.indexed) id: i};
  final fresh =
      [
        for (final i in items)
          if (!rank.containsKey(i.id)) i,
      ]..sort(
        (a, b) => (b.premiereDate ?? DateTime(0)).compareTo(
          a.premiereDate ?? DateTime(0),
        ),
      );
  final placed = [
    for (final i in items)
      if (rank.containsKey(i.id)) i,
  ]..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
  return [...fresh, ...placed];
}
