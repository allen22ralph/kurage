import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/toast.dart';
import '../../../core/jellyfin/items.dart';
import '../../../core/jellyfin/jellyfin_api.dart';
import '../library_providers.dart';

/// Around a playlist's items: their card menus offer "Remove from playlist".
class PlaylistScope extends InheritedWidget {
  const PlaylistScope({super.key, required this.playlist, required this.onRemoved, required super.child});

  final BaseItem playlist;

  /// After an entry is taken out, to reload the list.
  final VoidCallback onRemoved;

  static PlaylistScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<PlaylistScope>();

  @override
  bool updateShouldNotify(PlaylistScope old) => playlist.id != old.playlist.id;
}

/// The entry id of [item] in the playlist it was listed from, if any.
String? playlistEntryId(BaseItem item) => item.raw['PlaylistItemId'] as String?;

/// What can go in a playlist: what plays, and a season or show (its episodes).
bool canAddToPlaylist(BaseItem item) =>
    item.type.isPlayable || item.type == ItemType.series || item.type == ItemType.season;

/// Bumped whenever a playlist is made or deleted here, so lists of them
/// load again.
final playlistsChanged = ValueNotifier<int>(0);

/// Asks for a name and makes an empty playlist. True when one was made.
Future<bool> showNewPlaylist(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final name = TextEditingController();
  final made = await showDialog<String>(
    context: context,
    builder: (dialog) {
      void done() {
        final text = name.text.trim();
        if (text.isNotEmpty) Navigator.pop(dialog, text);
      }

      return AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (_) => done(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
          FilledButton(onPressed: done, child: const Text('Create')),
        ],
      );
    },
  );
  name.dispose();
  if (made == null) return false;
  try {
    await container.read(libraryApiProvider).createPlaylist(made, const []);
    playlistsChanged.value++;
    showToast('Made the playlist "$made"');
    return true;
  } on JellyfinException catch (e) {
    showToast(e.message);
    return false;
  }
}

/// Asks first, then deletes [playlist] (what's in it stays in the library).
/// True when it's gone.
Future<bool> confirmDeletePlaylist(BuildContext context, BaseItem playlist) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final sure = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text('Delete "${playlist.name}"?'),
      content: const Text("The playlist goes for good. What's in it stays in your library."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(dialog).colorScheme.error),
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (sure != true) return false;
  try {
    await container.read(libraryApiProvider).deletePlaylist(playlist.id);
    playlistsChanged.value++;
    showToast('Deleted the playlist "${playlist.name}"');
    return true;
  } on JellyfinException catch (e) {
    showToast(e.statusCode == 403 ? "Your account isn't allowed to delete this playlist" : e.message);
    return false;
  }
}

/// Asks which playlist, or a new one's name, and adds [items] to it.
Future<void> showAddToPlaylist(BuildContext context, List<BaseItem> items) => showDialog<void>(
      context: context,
      builder: (_) => _AddToPlaylist(items: items),
    );

class _AddToPlaylist extends ConsumerStatefulWidget {
  const _AddToPlaylist({required this.items});

  final List<BaseItem> items;

  @override
  ConsumerState<_AddToPlaylist> createState() => _AddToPlaylistState();
}

class _AddToPlaylistState extends ConsumerState<_AddToPlaylist> {
  final _name = TextEditingController();
  List<BaseItem>? _playlists;
  String? _error;
  bool _busy = false;
  bool _creating = false;

  List<String> get _ids => [for (final i in widget.items) i.id];

  String get _what => widget.items.length == 1 ? widget.items.single.name : '${widget.items.length} items';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final playlists = await ref.read(libraryApiProvider).getPlaylists();
      if (mounted) setState(() => _playlists = playlists);
    } on JellyfinException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _do(Future<void> Function() add, String done) async {
    setState(() => _busy = true);
    try {
      await add();
      // What shows playlists, or their entries, loads again.
      ref.invalidate(playlistItemsProvider);
      playlistsChanged.value++;
      showToast(done);
      if (mounted) Navigator.pop(context);
    } on JellyfinException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  void _addTo(BaseItem playlist) => _do(
        () => ref.read(libraryApiProvider).addToPlaylist(playlist.id, _ids),
        'Added $_what to the playlist "${playlist.name}"',
      );

  void _create() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    _do(() => ref.read(libraryApiProvider).createPlaylist(name, _ids), 'Added $_what to the new playlist "$name"');
  }

  @override
  Widget build(BuildContext context) {
    final playlists = _playlists;
    return AlertDialog(
      title: const Text('Add to playlist'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_creating)
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name of the new playlist'),
                onSubmitted: (_) => _create(),
              )
            else if (playlists == null && _error == null)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.add),
                      title: const Text('New playlist'),
                      onTap: _busy ? null : () => setState(() => _creating = true),
                    ),
                    for (final playlist in playlists ?? const <BaseItem>[])
                      ListTile(
                        leading: const Icon(Icons.queue_music),
                        title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: _busy ? null : () => _addTo(playlist),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (_creating) FilledButton(onPressed: _busy ? null : _create, child: const Text('Create')),
      ],
    );
  }
}
