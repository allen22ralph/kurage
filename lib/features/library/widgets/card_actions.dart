import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/toast.dart';
import '../../../app/providers.dart';
import '../../../core/jellyfin/items.dart';
import '../../../core/jellyfin/jellyfin_api.dart';
import '../../admin/admin_providers.dart';
import '../../admin/server_admin.dart';
import '../../anime/mal_account.dart';
import '../library_providers.dart';
import '../../downloads/downloads_screen.dart';
import '../../watchlist/watchlist_providers.dart';
import '../navigation.dart';
import 'action_menu.dart';
import 'add_to_playlist.dart';

/// Which home row a card is in, for its row-specific action.
enum CardRow { continueWatching, nextUp }

/// Next up episodes the user hid on this device ("Hide from Next up"; the
/// server can't). Hiding an episode hides it until another episode of the
/// show becomes next up.
final nextUpHiddenProvider = AsyncNotifierProvider<NextUpHiddenController, Set<String>>(NextUpHiddenController.new);

class NextUpHiddenController extends AsyncNotifier<Set<String>> {
  String get _key {
    final s = ref.read(currentSessionProvider);
    return 'home.nextUpHidden.${s.serverId}.${s.userId}';
  }

  @override
  Future<Set<String>> build() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    return raw == null ? {} : {for (final id in jsonDecode(raw) as List) id as String};
  }

  Future<void> hide(String episodeId) async {
    final hidden = {...await future, episodeId};
    state = AsyncData(hidden);
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(hidden.toList()));
  }
}

/// Next up without the episodes hidden on this device.
final visibleNextUpProvider = FutureProvider<List<BaseItem>>((ref) async {
  final hidden = await ref.watch(nextUpHiddenProvider.future);
  return [for (final e in await ref.watch(nextUpProvider.future)) if (!hidden.contains(e.id)) e];
});

/// Runs card actions: the server call, MyAnimeList, then refreshes rows.
///
/// Holds the app's providers and messenger rather than the widget that
/// started it: hover buttons vanish as soon as the mouse moves to a menu,
/// and the action must still finish (and refresh the row) after that.
class CardActions {
  CardActions(BuildContext context) : _container = ProviderScope.containerOf(context, listen: false);

  final ProviderContainer _container;

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      refreshWatchState(_container.invalidate);
      showToast(done, duration: const Duration(seconds: 2));
    } on JellyfinException catch (e) {
      showToast(e.message);
    } on Object catch (e) {
      showToast("Couldn't do that: $e");
    }
  }

  /// Marks [item] (an episode, a season or a whole show) watched or not,
  /// keeping MyAnimeList in step as the detail page does.
  Future<void> setWatched(BaseItem item, bool watched) => _run(() async {
        await _container.read(libraryApiProvider).setPlayed(item.id, watched);
        if (item.type == ItemType.episode || item.type == ItemType.season) {
          unawaited(_container.read(malSyncServiceProvider).markedWatched(item, watched: watched));
        }
      }, watched ? 'Marked ${item.name} watched' : 'Marked ${item.name} unwatched');

  /// The episode's whole show, by its series id.
  Future<void> setSeriesWatched(BaseItem episode, bool watched) async {
    final id = episode.seriesId;
    if (id == null) return;
    await _run(
      () => _container.read(libraryApiProvider).setPlayed(id, watched),
      '${watched ? 'Marked' : 'Unmarked'} all of ${episode.seriesName ?? 'the show'}',
    );
  }

  Future<void> setFavorite(BaseItem item, bool favorite) => _run(
        () => _container.read(libraryApiProvider).setFavorite(item.id, favorite),
        favorite ? 'Added ${item.name} to favourites' : 'Removed ${item.name} from favourites',
      );

  /// Puts [items] on the watchlist or takes them off. Taking off offers
  /// Undo, which puts them back.
  Future<void> setWatchlisted(List<BaseItem> items, bool on) async {
    final api = _container.read(libraryApiProvider);
    final what = items.length == 1 ? items.single.name : '${items.length} items';
    try {
      for (final item in items) {
        await api.setWatchlisted(item.id, on);
      }
    } on JellyfinException catch (e) {
      showToast(e.message);
    } finally {
      // Some may have changed before a failure.
      _container.invalidate(watchlistProvider);
      refreshWatchState(_container.invalidate);
    }
    if (!on) {
      showToast(
        'Removed $what from your watchlist',
        actionLabel: 'Undo',
        onAction: () => setWatchlisted(items, true),
        duration: const Duration(seconds: 5),
      );
    } else {
      showToast('Added $what to your watchlist', duration: const Duration(seconds: 2));
    }
  }

  Future<void> removeFromContinueWatching(BaseItem item) => _run(
        () => _container.read(libraryApiProvider).clearProgress(item.id),
        'Removed from Continue watching',
      );

  /// Takes [item] out of [scope]'s playlist (the entry it was listed as).
  Future<void> removeFromPlaylist(PlaylistScope scope, BaseItem item) async {
    final entry = playlistEntryId(item);
    if (entry == null) return;
    await _run(
      () => _container.read(libraryApiProvider).removeFromPlaylist(scope.playlist.id, [entry]),
      'Removed ${item.name} from the playlist "${scope.playlist.name}"',
    );
    scope.onRemoved();
  }

  Future<void> hideFromNextUp(BaseItem item) => _run(
        () => _container.read(nextUpHiddenProvider.notifier).hide(item.id),
        'Hidden from Next up',
      );
}

/// The card menu: ⋮, long press, a remote's menu key, or right-click (a
/// popup at [at], where the mouse is).
///
/// [context] must outlive the menu (the card, not its hover buttons).
Future<void> showCardMenu(BuildContext context, BaseItem item, {CardRow? row, Offset? at}) {
  final actions = CardActions(context);
  final admin = ProviderScope.containerOf(context, listen: false).read(isAdminProvider).value ?? false;
  final played = item.userData.played;
  final favorite = item.userData.isFavorite;
  final episode = item.type == ItemType.episode;
  final playlist = PlaylistScope.maybeOf(context);
  return showActionMenu(
    context,
    at: at,
    title: episode ? '${item.seriesName ?? ''} · ${item.episodeLabel ?? ''}' : item.name,
    subtitle: episode ? item.name : null,
    entries: [
      if (item.type.isPlayable)
        MenuEntry(
          icon: Icons.play_arrow,
          label: item.userData.hasProgress ? 'Resume' : 'Play',
          // On a playlist's page, the playlist goes on after it.
          onSelected: () => playlist == null
              ? openItem(context, item, play: true)
              : GoRouter.of(context).push('/play/${item.id}?playlist=${playlist.playlist.id}'),
        ),
      if (episode && item.seriesId != null)
        MenuEntry(icon: Icons.tv, label: 'Go to ${item.seriesName ?? 'show'}', onSelected: () => openSeries(context, item)),
      if (!item.type.isPlayable || !episode)
        MenuEntry(icon: Icons.info_outline, label: 'Details', onSelected: () => openItem(context, item)),
      MenuEntry(
        icon: played ? Icons.remove_done : Icons.check,
        label: played ? 'Mark unwatched' : 'Mark watched',
        onSelected: () => actions.setWatched(item, !played),
      ),
      if (episode && item.seriesId != null)
        MenuEntry(
          icon: Icons.done_all,
          label: 'Mark all of ${item.seriesName ?? 'the show'} watched',
          onSelected: () => actions.setSeriesWatched(item, true),
        ),
      MenuEntry(
        icon: favorite ? Icons.favorite : Icons.favorite_border,
        label: favorite ? 'Remove from favourites' : 'Add to favourites',
        onSelected: () => actions.setFavorite(item, !favorite),
      ),
      if (canWatchlist(item))
        MenuEntry(
          icon: item.userData.likes ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined,
          label: item.userData.likes ? 'Remove from watchlist' : 'Add to watchlist',
          onSelected: () => actions.setWatchlisted([item], !item.userData.likes),
        ),
      ?downloadMenuEntry(context, item),
      if (item.type == ItemType.playlist)
        MenuEntry(
          icon: Icons.delete_outline,
          label: 'Delete playlist',
          onSelected: () => confirmDeletePlaylist(context, item),
        ),
      if (canAddToPlaylist(item))
        MenuEntry(icon: Icons.playlist_add, label: 'Add to playlist', onSelected: () => showAddToPlaylist(context, [item])),
      if (playlist != null && playlistEntryId(item) != null)
        MenuEntry(
          icon: Icons.playlist_remove,
          label: 'Remove from ${playlist.playlist.name}',
          onSelected: () => actions.removeFromPlaylist(playlist, item),
        ),
      if (row == CardRow.continueWatching)
        MenuEntry(
          icon: Icons.playlist_remove,
          label: 'Remove from Continue watching',
          onSelected: () => actions.removeFromContinueWatching(item),
        ),
      if (row == CardRow.nextUp)
        MenuEntry(
          icon: Icons.visibility_off_outlined,
          label: 'Hide from Next up',
          subtitle: 'Until another episode of the show is next',
          onSelected: () => actions.hideFromNextUp(item),
        ),
      // Administrators: the server's view of the item.
      if (admin)
        MenuEntry(
          icon: isLibrary(item) ? Icons.manage_search : Icons.refresh,
          label: isLibrary(item) ? 'Scan this library' : 'Refresh metadata…',
          onSelected: () => showRefreshMetadata(context, item),
        ),
    ],
  );
}

/// Hover buttons along a card's bottom edge (desktop): watched, favourite
/// and the menu.
class CardHoverActions extends StatelessWidget {
  const CardHoverActions({super.key, required this.item, required this.onMenu});

  final BaseItem item;

  /// Opens the card's menu (from the card: these buttons go when the
  /// mouse leaves it).
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final actions = CardActions(context);
    Widget button(String tip, IconData icon, VoidCallback onPressed, {bool on = false}) => Tooltip(
          message: tip,
          child: InkResponse(
            // Mouse only: keyboard / D-pad focus stays on the card.
            canRequestFocus: false,
            onTap: onPressed,
            radius: 18,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                icon,
                size: 20,
                color: on ? Theme.of(context).colorScheme.primary : Colors.white,
                shadows: const [Shadow(blurRadius: 6, color: Colors.black87)],
              ),
            ),
          ),
        );
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87]),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          button(
            item.userData.played ? 'Mark unwatched' : 'Mark watched',
            item.userData.played ? Icons.check_circle : Icons.check_circle_outline,
            () => actions.setWatched(item, !item.userData.played),
            on: item.userData.played,
          ),
          button(
            item.userData.isFavorite ? 'Remove from favourites' : 'Add to favourites',
            item.userData.isFavorite ? Icons.favorite : Icons.favorite_border,
            () => actions.setFavorite(item, !item.userData.isFavorite),
            on: item.userData.isFavorite,
          ),
          button('More', Icons.more_vert, onMenu),
        ],
      ),
    );
  }
}
