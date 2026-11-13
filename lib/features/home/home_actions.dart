import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/notifications.dart';
import '../../app/providers.dart';
import '../../app/user_avatar.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/library_api.dart';
import '../library/library_providers.dart';
import '../library/widgets/add_to_playlist.dart' show playlistsChanged;
import '../seerr/seerr_providers.dart';
import '../syncplay/syncplay_service.dart';
import '../syncplay/syncplay_sheet.dart';
import 'home_components.dart';
import 'home_tabs.dart';

/// What can go on the top bar, by name: these, and any library or playlist
/// (`library:<id>`, `playlist:<id>`). Home, Settings and the account are always there, or
/// there'd be no way back to this choice.
const _movies = 'movies';
const _shows = 'shows';
const _refresh = 'refresh';
const _search = 'search';
const _requests = 'requests';
const _together = 'watchTogether';
const _downloads = 'downloads';
const _favorites = 'favorites';
const _watchlist = 'watchlist';
const _notifications = 'notifications';
const _libraryPrefix = 'library:';
const _playlistPrefix = 'playlist:';

const _builtIn = {
  _movies: 'Movies',
  _shows: 'Shows',
  _refresh: 'Refresh',
  _search: 'Search',
  _requests: 'Requests',
  _together: 'Watch together',
  _downloads: 'Downloads',
  _favorites: 'Favorites',
  _watchlist: 'Watchlist',
  _notifications: 'Notifications',
};

/// The server's playlists, to choose from and to name those on the bar.
final homeBarPlaylistsProvider = FutureProvider.autoDispose<List<BaseItem>>((ref) async {
  // A playlist made or deleted in the app: the list loads again.
  void changed() => ref.invalidateSelf();
  playlistsChanged.addListener(changed);
  ref.onDispose(() => playlistsChanged.removeListener(changed));
  final page = await ref.watch(libraryApiProvider).getItems(
    const ItemQuery(includeItemTypes: [ItemType.playlist]),
    limit: 200,
  );
  return page.items;
});

/// What's on the top bar, in every theme, kept on this device.
class HomeBarSettings {
  const HomeBarSettings({
    this.centre = const [_movies, _shows],
    this.right = const [_refresh, _search, _requests, _together, _downloads, _watchlist, _favorites, _notifications],
  });

  final List<String> centre;
  final List<String> right;

  /// The tabs that swap the page under the bar. Home is always one of them.
  List<HomeTab> get tabs => [
        HomeTab.home,
        for (final id in centre)
          if (id == _movies)
            HomeTab.movies
          else if (id == _shows)
            HomeTab.shows,
      ];
}

final homeBarSettingsProvider = AsyncNotifierProvider<HomeBarSettingsController, HomeBarSettings>(HomeBarSettingsController.new);

class HomeBarSettingsController extends AsyncNotifier<HomeBarSettings> {
  static const _centreKey = 'homeBar.centre';
  static const _rightKey = 'homeBar.right';

  @override
  Future<HomeBarSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    const d = HomeBarSettings();
    return HomeBarSettings(
      centre: _known(prefs.getStringList(_centreKey)) ?? d.centre,
      right: _known(prefs.getStringList(_rightKey)) ?? d.right,
    );
  }

  Future<void> _save(HomeBarSettings settings) async {
    state = AsyncData(settings);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_centreKey, settings.centre);
    await prefs.setStringList(_rightKey, settings.right);
  }

  HomeBarSettings get _now => state.value ?? const HomeBarSettings();

  /// Without what can no longer go on the bar.
  static List<String>? _known(List<String>? ids) => ids == null
      ? null
      : [
          for (final id in ids)
            if (_builtIn.containsKey(id) || id.startsWith(_libraryPrefix) || id.startsWith(_playlistPrefix)) id,
        ];

  /// Adds [id] here, moving it if it's on the other side: it's only ever in one.
  Future<void> addToCentre(String id) => _save(HomeBarSettings(
        centre: [..._now.centre.where((e) => e != id), id],
        right: [..._now.right.where((e) => e != id)],
      ));

  Future<void> addToRight(String id) => _save(HomeBarSettings(
        centre: [..._now.centre.where((e) => e != id)],
        right: [..._now.right.where((e) => e != id), id],
      ));

  /// What a theme file brought: only what's known, the rest as it is.
  Future<void> replaceWith({List<String>? centre, List<String>? right}) async {
    final now = await future;
    await _save(HomeBarSettings(
      centre: _known(centre) ?? now.centre,
      right: _known(right) ?? now.right,
    ));
  }

  Future<void> remove(String id) => _save(HomeBarSettings(
        centre: [..._now.centre.where((e) => e != id)],
        right: [..._now.right.where((e) => e != id)],
      ));
}

String? _playlistName(WidgetRef ref, String id) {
  final playlistId = id.substring(_playlistPrefix.length);
  return ref.watch(homeBarPlaylistsProvider).value?.where((p) => p.id == playlistId).firstOrNull?.name;
}

String? _libraryName(WidgetRef ref, String id) {
  final libraryId = id.substring(_libraryPrefix.length);
  return ref.watch(viewsProvider).value?.where((v) => v.id == libraryId).firstOrNull?.name;
}

/// [id] as a tool; null for what isn't there now (Requests without Seerr, a
/// library that's gone).
HomeAction? _actionFor(BuildContext context, WidgetRef ref, String id, {required VoidCallback onRefresh, String? refreshShortcut}) {
  void openTab(HomeTab tab) {
    ref.read(homeTabProvider.notifier).select(tab);
    context.go('/');
  }

  if (id.startsWith(_libraryPrefix)) {
    final name = _libraryName(ref, id);
    if (name == null) return null;
    return HomeAction(
      label: name,
      icon: const Icon(Icons.video_library_outlined),
      onPressed: () => context.push('/library/${id.substring(_libraryPrefix.length)}'),
    );
  }
  if (id.startsWith(_playlistPrefix)) {
    final name = _playlistName(ref, id);
    if (name == null) return null;
    return HomeAction(
      label: name,
      icon: const Icon(Icons.queue_music),
      onPressed: () => context.push('/item/${id.substring(_playlistPrefix.length)}'),
    );
  }
  return switch (id) {
    _movies => HomeAction(label: 'Movies', icon: Icon(HomeTab.movies.icon), onPressed: () => openTab(HomeTab.movies)),
    _shows => HomeAction(label: 'Shows', icon: Icon(HomeTab.shows.icon), onPressed: () => openTab(HomeTab.shows)),
    _refresh => HomeAction(label: 'Refresh', shortcut: refreshShortcut, icon: const Icon(Icons.refresh), onPressed: onRefresh),
    _search => HomeAction(label: 'Search', icon: const Icon(Icons.search), pinned: true, onPressed: () => context.push('/search')),
    _requests when ref.watch(seerrAccountProvider).value != null => HomeAction(
        label: 'Requests',
        icon: const Icon(Icons.playlist_add_check),
        onPressed: () => context.push('/requests'),
      ),
    _together => HomeAction(
        label: 'Watch together',
        icon: Icon(ref.watch(syncPlayProvider).inGroup ? Icons.groups : Icons.groups_outlined),
        onPressed: () => showSyncPlaySheet(context),
      ),
    _downloads => HomeAction(
        label: 'Downloads',
        icon: const Icon(Icons.download_for_offline_outlined),
        onPressed: () => context.push('/downloads'),
      ),
    _watchlist => HomeAction(label: 'Watchlist', icon: const Icon(Icons.bookmark_border), onPressed: () => context.push('/watchlist')),
    _favorites => HomeAction(label: 'Favorites', icon: const Icon(Icons.favorite_border), onPressed: () => context.push('/favorites')),
    _notifications => HomeAction(
        label: 'Notifications',
        icon: const NotificationBellIcon(),
        pinned: true,
        onPressed: () => showNotifications(context),
      ),
    _ => null,
  };
}

/// The top bar's right side, in the order chosen, then Settings and the
/// account: on Home, and on the pages that share its bar. [onRefresh] reloads
/// the page they're on.
List<HomeAction> homeActions(
  BuildContext context,
  WidgetRef ref, {
  required VoidCallback onRefresh,
  String? refreshShortcut,
}) {
  final session = ref.watch(currentSessionProvider);
  final bar = ref.watch(homeBarSettingsProvider).value ?? const HomeBarSettings();
  return [
    for (final id in bar.right) ?_actionFor(context, ref, id, onRefresh: onRefresh, refreshShortcut: refreshShortcut),
    HomeAction(
      label: 'Settings',
      icon: const Icon(Icons.settings_outlined),
      onPressed: () => context.push('/settings'),
    ),
    HomeAction(
      label: '${session.userName} (signed in) · Accounts',
      icon: const CurrentUserAvatar(radius: 13),
      pinned: true,
      onPressed: () => context.push('/accounts'),
    ),
  ];
}

/// What's been added among the tabs, beyond those that swap the page: each
/// opens its own page.
List<HomeAction> homeTabExtras(BuildContext context, WidgetRef ref, {required VoidCallback onRefresh}) {
  final bar = ref.watch(homeBarSettingsProvider).value ?? const HomeBarSettings();
  return [
    for (final id in bar.centre)
      if (id != _movies && id != _shows) ?_actionFor(context, ref, id, onRefresh: onRefresh),
  ];
}

/// Settings > Home: what's on the top bar. Add and remove.
class HomeBarSection extends ConsumerWidget {
  const HomeBarSection({super.key});

  String _label(WidgetRef ref, String id) {
    if (id.startsWith(_libraryPrefix)) return _libraryName(ref, id) ?? 'Library';
    if (id.startsWith(_playlistPrefix)) return _playlistName(ref, id) ?? 'Playlist';
    return _builtIn[id] ?? id;
  }

  /// Everything not already in [here]; what's on the [other] side says it moves.
  Future<void> _add(
    BuildContext context,
    WidgetRef ref, {
    required List<String> here,
    required List<String> other,
    required String otherName,
    required ValueChanged<String> onPick,
  }) async {
    final seerr = ref.read(seerrAccountProvider).value != null;
    final libraries = ref.read(viewsProvider).value ?? const <BaseItem>[];
    final playlists = ref.read(homeBarPlaylistsProvider).value ?? const <BaseItem>[];
    // By kind, each only with what's not already here.
    Map<String, String> unused(Map<String, String> all) => {
          for (final e in all.entries)
            if (!here.contains(e.key)) e.key: e.value,
        };
    final groups = <String, Map<String, String>>{
      'Pages and tools': unused({
        for (final e in _builtIn.entries)
          if (e.key != _requests || seerr) e.key: e.value,
      }),
      // (The playlists library lists them all; one playlist is below.)
      'Libraries': unused({
        for (final l in libraries)
          '$_libraryPrefix${l.id}': l.collectionType == 'playlists' ? 'All playlists' : l.name,
      }),
      'Single playlists': unused({for (final p in playlists) '$_playlistPrefix${p.id}': p.name}),
    };
    final picked = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('Add to the bar'),
        children: [
          for (final group in groups.entries)
            if (group.value.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
                // Headings, not choices: small capitals in the accent colour.
                child: Text(
                  group.key.toUpperCase(),
                  style: Theme.of(dialog).textTheme.labelSmall?.copyWith(
                        color: Theme.of(dialog).colorScheme.primary,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              for (final option in group.value.entries)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialog, option.key),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(option.value),
                      if (other.contains(option.key))
                        Text('Moves from the $otherName', style: Theme.of(dialog).textTheme.bodySmall),
                    ],
                  ),
                ),
            ],
        ],
      ),
    );
    if (picked != null) onPick(picked);
  }

  Widget _group(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required List<String> fixed,
    required List<String> ids,
    required VoidCallback onAdd,
  }) {
    final controller = ref.read(homeBarSettingsProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final label in fixed) Chip(label: Text(label)),
              for (final id in ids)
                InputChip(
                  label: Text(_label(ref, id)),
                  deleteButtonTooltipMessage: 'Remove ${_label(ref, id)}',
                  onDeleted: () => controller.remove(id),
                ),
              ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('Add'), tooltip: 'Add to $title', onPressed: onAdd),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(homeBarSettingsProvider).value ?? const HomeBarSettings();
    final controller = ref.read(homeBarSettingsProvider.notifier);
    // Ready for Add, and to name what's on the bar.
    ref.watch(viewsProvider);
    ref.watch(homeBarPlaylistsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _group(
          context,
          ref,
          title: 'Centre tabs',
          fixed: const ['Home'],
          ids: value.centre,
          onAdd: () => _add(context, ref, here: value.centre, other: value.right, otherName: 'right toolbar', onPick: controller.addToCentre),
        ),
        _group(
          context,
          ref,
          title: 'Right toolbar',
          fixed: const ['Settings', 'Account'],
          ids: value.right,
          onAdd: () => _add(context, ref, here: value.right, other: value.centre, otherName: 'centre tabs', onPick: controller.addToRight),
        ),
      ],
    );
  }
}
