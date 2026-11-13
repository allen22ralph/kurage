import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../../app/smooth_wheel.dart';
import '../../../app/toast.dart';
import '../../../core/jellyfin/items.dart';
import '../../../core/jellyfin/jellyfin_api.dart';
import '../../home/depth/deck_hero.dart' show GlassRound, RiseIn;
import '../../settings/appearance.dart';
import '../item_detail_screen.dart' show formatRuntime;
import '../library_providers.dart';
import '../widgets/action_menu.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/card_actions.dart';
import '../widgets/item_image.dart';
import '../widgets/selection.dart';
import 'detail_parts.dart';

const _light = Color(0xFFF2F0FF);
const _ink = Color(0xFF0B0C12);
const _cyan = Color(0xFF8EE6F5);
const _text = Color(0xFFE8E9F0);
const _muted = Color(0xFF9AA0B2);
const _faint = Color(0xFF7D8396);
const _surface = Color(0xFF0E1018);
const _ease = Cubic(0.2, 0.8, 0.2, 1);

/// Depth's page for a playlist: a title, Play and Delete, and the entries as
/// a numbered list in the playlist's order, which can be dragged to change
/// it (kept on the server). No previews.
class DepthPlaylistPage extends ConsumerStatefulWidget {
  const DepthPlaylistPage({super.key, required this.playlist});

  final BaseItem playlist;

  @override
  ConsumerState<DepthPlaylistPage> createState() => _DepthPlaylistPageState();
}

class _DepthPlaylistPageState extends ConsumerState<DepthPlaylistPage> {
  /// The entries as shown: moved at once when dragged, before the server
  /// has them in that order.
  List<BaseItem>? _entries;

  BaseItem get _playlist => widget.playlist;

  /// Entries picked for a batch action, by their entry key.
  final _selection = Selection();

  /// Picking, after Select (the selection itself may still be empty).
  bool _selecting = false;

  bool get _picking => _selecting || _selection.active;

  /// An entry's key: its PlaylistItemId (the same episode can be in twice).
  static String _key(BaseItem item, int index) => playlistEntryId(item) ?? '${item.id}-$index';

  @override
  void initState() {
    super.initState();
    _selection.addListener(_changed);
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  void _changed() => setState(() {
        if (!_selection.active) _selecting = false;
      });

  /// A tap plays, unless it's picking (Select, Ctrl/Shift-click).
  void _tap(BaseItem item, int index, List<String> order) {
    final key = _key(item, index);
    if (_selecting && !_selection.active) return _selection.toggle(key);
    if (_selection.tap(order, key)) return;
    _play(item);
  }

  /// The picked entries, in the playlist's order, with where each is.
  List<(int, BaseItem)> _picked() => [
        for (final (i, e) in (_entries ?? const <BaseItem>[]).indexed)
          if (_selection.contains(_key(e, i))) (i, e),
      ];

  /// Takes [entries] (with where each was) out, offering to put them back
  /// where they were.
  Future<void> _removeMany(List<(int, BaseItem)> entries) async {
    final ids = [for (final (_, e) in entries) ?playlistEntryId(e)];
    if (ids.isEmpty) return;
    final gone = {for (final (_, e) in entries) e};
    setState(() => _entries = [...?_entries]..removeWhere(gone.contains));
    final what = entries.length == 1 ? entries.single.$2.name : '${entries.length} items';
    try {
      await ref.read(libraryApiProvider).removeFromPlaylist(_playlist.id, ids);
      showToast(
        'Removed $what from the playlist "${_playlist.name}"',
        actionLabel: 'Undo',
        onAction: () => _putBack(entries),
        duration: const Duration(seconds: 5),
      );
    } on JellyfinException catch (e) {
      showToast(e.message);
    }
    _reload();
  }

  /// Undo: adds [entries] again (at the end, as the server does), then moves
  /// each back to where it was.
  Future<void> _putBack(List<(int, BaseItem)> entries) async {
    final api = ref.read(libraryApiProvider);
    try {
      await api.addToPlaylist(_playlist.id, [for (final (_, e) in entries) e.id]);
      final now = await api.getPlaylistItems(_playlist.id);
      final added = now.skip(now.length - entries.length).toList();
      final back = [...entries]..sort((a, b) => a.$1.compareTo(b.$1));
      for (final (k, (index, _)) in back.indexed) {
        if (playlistEntryId(added[k]) case final entry?) await api.movePlaylistEntry(_playlist.id, entry, index);
      }
    } on JellyfinException catch (e) {
      showToast("Couldn't put it back: ${e.message}");
    }
    _reload();
  }

  Future<void> _setWatched(List<BaseItem> items, bool watched) async {
    final api = ref.read(libraryApiProvider);
    try {
      for (final item in items) {
        await api.setPlayed(item.id, watched);
      }
      showToast('Marked ${items.length == 1 ? items.single.name : '${items.length} items'} ${watched ? 'watched' : 'unwatched'}');
    } on JellyfinException catch (e) {
      showToast(e.message);
    }
    refreshWatchState(ref.invalidate);
    _reload();
  }

  /// The picked entries to the top, keeping their order among themselves.
  Future<void> _toTop(List<(int, BaseItem)> picked) async {
    final chosen = {for (final (_, e) in picked) e};
    setState(() => _entries = [for (final (_, e) in picked) e, ...?_entries?.where((e) => !chosen.contains(e))]);
    final api = ref.read(libraryApiProvider);
    try {
      for (final (k, (_, e)) in picked.indexed) {
        if (playlistEntryId(e) case final entry?) await api.movePlaylistEntry(_playlist.id, entry, k);
      }
    } on JellyfinException catch (e) {
      showToast("Couldn't move them: ${e.message}");
    }
    _reload();
  }

  /// Right-click while picking: what the bar does, for everything picked
  /// (the row clicked joins them if it wasn't picked).
  Future<void> _pickedMenu(String key, Offset at) async {
    if (!_selection.contains(key)) _selection.toggle(key);
    final picked = _picked();
    if (picked.isEmpty) return;
    final items = [for (final (_, e) in picked) e];
    final watched = items.where((i) => i.userData.played).length;
    void act(void Function() run) {
      _selection.clear();
      run();
    }

    await showActionMenu(
      context,
      at: at,
      title: '${picked.length} picked',
      entries: [
        MenuEntry(icon: Icons.vertical_align_top, label: 'Move to top', onSelected: () => act(() => _toTop(picked))),
        // What applies: unwatched ones can be marked, watched ones unmarked.
        if (watched < items.length)
          MenuEntry(icon: Icons.check, label: 'Mark watched', onSelected: () => act(() => _setWatched(items, true))),
        if (watched > 0)
          MenuEntry(icon: Icons.remove_done, label: 'Mark unwatched', onSelected: () => act(() => _setWatched(items, false))),
        MenuEntry(
          icon: Icons.playlist_add,
          label: 'Add to another playlist',
          onSelected: () => act(() => showAddToPlaylist(context, items)),
        ),
        MenuEntry(
          icon: Icons.playlist_remove,
          label: 'Remove from the playlist',
          onSelected: () => act(() => _removeMany(picked)),
        ),
      ],
    );
  }

  List<Widget> _bulkActions() {
    final picked = _picked();
    final items = [for (final (_, e) in picked) e];
    VoidCallback? act(void Function() run) => picked.isEmpty
        ? null
        : () {
            _selection.clear();
            run();
          };
    return [
      IconButton(tooltip: 'Move to top', icon: const Icon(Icons.vertical_align_top), onPressed: act(() => _toTop(picked))),
      IconButton(tooltip: 'Mark watched', icon: const Icon(Icons.check), onPressed: act(() => _setWatched(items, true))),
      IconButton(tooltip: 'Mark unwatched', icon: const Icon(Icons.remove_done), onPressed: act(() => _setWatched(items, false))),
      IconButton(
        tooltip: 'Add to another playlist',
        icon: const Icon(Icons.playlist_add),
        onPressed: act(() => showAddToPlaylist(context, items)),
      ),
      IconButton(
        tooltip: 'Remove from the playlist',
        icon: const Icon(Icons.playlist_remove),
        onPressed: act(() => _removeMany(picked)),
      ),
    ];
  }

  void _reload() => ref.invalidate(playlistItemsProvider(_playlist.id));

  /// Plays [item] with the playlist going on after it.
  void _play(BaseItem item) => context.push('/play/${item.id}?playlist=${_playlist.id}');

  Future<void> _move(int from, int to) async {
    final entries = [...?_entries];
    if (from == to || from < 0 || to < 0 || from >= entries.length || to >= entries.length) return;
    final moved = entries.removeAt(from);
    entries.insert(to, moved);
    setState(() => _entries = entries);
    final entry = playlistEntryId(moved);
    if (entry == null) return;
    try {
      await ref.read(libraryApiProvider).movePlaylistEntry(_playlist.id, entry, to);
    } on JellyfinException catch (e) {
      showToast("Couldn't move it: ${e.message}");
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(playlistItemsProvider(_playlist.id));
    // The server's order replaces the one shown, once it's in.
    ref.listen(playlistItemsProvider(_playlist.id), (_, next) {
      if (next.value case final value?) setState(() => _entries = value);
    });
    _entries ??= loaded.value;
    final entries = _entries;
    final phone = context.layout.formFactor == FormFactor.phone;
    final width = MediaQuery.sizeOf(context).width;
    final side = phone ? 16.0 : math.max(context.layout.gutter, (width - 1400) / 2);

    return PlaylistScope(
      playlist: _playlist,
      onRemoved: _reload,
      child: SelectionShortcuts(
        selection: _selection,
        selectAll: () => _selection.setAll([for (final (i, e) in (entries ?? const <BaseItem>[]).indexed) _key(e, i)]),
        child: SmoothWheel(
        builder: (_, wheel) => FloatingSelectionBar(
          selection: _selection,
          controller: wheel,
          label: '${_selection.ids.length} selected',
          actions: _bulkActions(),
          child: CustomScrollView(
          controller: wheel,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, phone ? statusBarHeight(context) + 78 : 132, side, 0),
              sliver: SliverToBoxAdapter(child: _heading(context, entries)),
            ),
            if (entries == null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: loaded.hasError
                      ? Center(child: Text("Couldn't load this playlist", style: const TextStyle(color: _muted)))
                      : const Center(child: CircularProgressIndicator()),
                ),
              )
            else if (entries.isEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(side, 40, side, 0),
                sliver: const SliverToBoxAdapter(
                  child: Text(
                    'Nothing in it yet. Use "Add to playlist" on any show, season, episode or film.',
                    style: TextStyle(color: _muted, fontSize: 15),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(side, phone ? 22 : 44, side, 0),
                sliver: SliverReorderableList(
                  itemCount: entries.length,
                  onReorderItem: _move,
                  itemBuilder: (context, i) {
                    final item = entries[i];
                    final order = [for (final (j, e) in entries.indexed) _key(e, j)];
                    return _EntryRow(
                      // An entry, not the item: one can be in twice.
                      key: ValueKey(_key(item, i)),
                      item: item,
                      index: i,
                      phone: phone,
                      picking: _picking,
                      selected: _selection.contains(_key(item, i)),
                      onPlay: () => _tap(item, i, order),
                      // A hold picks (right-click, or ⋮ on a phone, is the menu).
                      onLongPress: () => _selection.toggle(_key(item, i)),
                      // Picking: the menu is for everything picked.
                      onContextMenu: _picking ? (at) => _pickedMenu(_key(item, i), at) : null,
                      onUp: i > 0 ? () => _move(i, i - 1) : null,
                      onDown: i < entries.length - 1 ? () => _move(i, i + 1) : null,
                      onRemove: () => _removeMany([(i, item)]),
                    );
                  },
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
        ),
      ),
      ),
    );
  }

  Widget _heading(BuildContext context, List<BaseItem>? entries) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final width = MediaQuery.sizeOf(context).width;
    final heading = CardLook.headingStyle(context) ?? const TextStyle();
    final count = entries?.length ?? 0;
    final ticks = [for (final e in entries ?? const <BaseItem>[]) e.runTimeTicks ?? 0].fold<int>(0, (a, b) => a + b);
    final kick = [
      'Playlist',
      if (entries != null) '$count ${count == 1 ? 'item' : 'items'}',
      if (ticks > 0) formatRuntime(ticksToDuration(ticks)),
    ].join(' · ');
    // Play: the first not yet watched, else from the top.
    final first = entries == null || entries.isEmpty
        ? null
        : entries.firstWhere((e) => !e.userData.played, orElse: () => entries.first);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RiseIn(delay: 0, child: Kick(kick)),
        SizedBox(height: phone ? 6 : 10),
        RiseIn(
          delay: 80,
          child: Text(
            _playlist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: heading.copyWith(
              color: _text,
              fontSize: phone ? 40 : (width * 0.06).clamp(56.0, 96.0),
              fontWeight: FontWeight.w800,
              height: 1.02,
              letterSpacing: phone ? -1 : -2,
            ),
          ),
        ),
        SizedBox(height: phone ? 18 : 28),
        RiseIn(
          delay: 160,
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (first != null)
                ResumePill(
                  autofocus: true,
                  label: first.userData.hasProgress ? 'Resume' : (first == entries!.first ? 'Play' : 'Play next'),
                  detail: '· ${_entryTitle(first)}',
                  progress: first.userData.hasProgress ? watchedFraction(first) : 0,
                  onPressed: () => _play(first),
                ),
              GhostButton(
                icon: Icons.delete_outline,
                label: 'Delete playlist',
                onPressed: () async {
                  if (await confirmDeletePlaylist(context, _playlist) && context.mounted) Navigator.of(context).maybePop();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Frieren · S1:E5" for an episode, else its name.
String _entryTitle(BaseItem item) => item.type == ItemType.episode
    ? [item.seriesName ?? item.name, ?item.episodeLabel].join(' · ')
    : item.name;

/// One entry: number, still, title and line, and its moves.
class _EntryRow extends StatefulWidget {
  const _EntryRow({
    super.key,
    required this.item,
    required this.index,
    required this.phone,
    required this.onPlay,
    required this.onRemove,
    this.onUp,
    this.onDown,
    this.picking = false,
    this.selected = false,
    this.onLongPress,
    this.onContextMenu,
  });

  final BaseItem item;
  final int index;
  final bool phone;
  final VoidCallback onPlay;
  final VoidCallback onRemove;
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  /// Picking for a batch action: no moves or remove, a tap picks.
  final bool picking;
  final bool selected;

  /// Instead of the menu (phone: starts picking).
  final VoidCallback? onLongPress;

  /// A right-click, where it was (the row's menu, or the picked ones').
  final ValueChanged<Offset>? onContextMenu;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _hot = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final phone = widget.phone;
    final heading = CardLook.headingStyle(context) ?? const TextStyle();
    final thumbWidth = phone ? 120.0 : 200.0;
    final fraction = watchedFraction(item);
    final left = timeLeft(item);
    final line = [
      if (item.type == ItemType.episode) item.name else if (item.productionYear case final y?) '$y',
      left ?? (item.userData.played ? 'Watched' : (item.runtime == null ? null : formatRuntime(item.runtime!))),
    ].whereType<String>().join(' · ');

    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(phone ? 10 : 14),
      child: SizedBox(
        width: thumbWidth,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: _surface),
              ItemImage(image: item.landscapeImage ?? item.backdropImage ?? item.posterImage, maxWidth: thumbWidth),
              if (item.userData.played)
                const Positioned(
                  right: 6,
                  top: 6,
                  child: CircleAvatar(radius: 11, backgroundColor: _light, child: Icon(Icons.check, size: 14, color: _ink)),
                ),
              if (fraction > 0)
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Transform(
                    alignment: Alignment.centerLeft,
                    transform: Matrix4.diagonal3Values(fraction, 1, 1),
                    child: const SizedBox(height: 4, width: double.infinity, child: ColoredBox(color: _cyan)),
                  ),
                ),
              if (!phone)
                AnimatedOpacity(
                  opacity: _hot ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(color: _light, shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow_rounded, color: _ink),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _entryTitle(item),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: heading.copyWith(color: _text, fontSize: phone ? 16 : 21, fontWeight: FontWeight.w700, height: 1.15),
        ),
        const SizedBox(height: 3),
        Text(
          line,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: left != null ? _cyan : _muted, fontSize: phone ? 12 : 13, fontWeight: FontWeight.w600),
        ),
        if (item.overview case final overview? when !phone) ...[
          const SizedBox(height: 6),
          Text(overview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _faint, fontSize: 13, height: 1.4)),
        ],
      ],
    );

    final handle = ReorderableDragStartListener(
      index: widget.index,
      child: const Tooltip(
        message: 'Drag to move',
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Padding(padding: EdgeInsets.all(10), child: Icon(Icons.drag_indicator_rounded, color: _muted)),
        ),
      ),
    );

    final row = MouseRegion(
      onEnter: (_) => setState(() => _hot = true),
      onExit: (_) => setState(() => _hot = false),
      child: GestureDetector(
        onSecondaryTapUp: (e) => widget.onContextMenu != null
            ? widget.onContextMenu!(e.globalPosition)
            : showCardMenu(context, item, at: e.globalPosition),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: _hot && !phone ? 1 : 0),
          duration: Duration(milliseconds: animationsOn(context) ? 300 : 0),
          curve: _ease,
          builder: (context, t, child) => Transform.translate(offset: Offset(8 * t, 0), child: child),
          child: Material(
            type: widget.selected ? MaterialType.canvas : MaterialType.transparency,
            shape: widget.selected
                ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: _cyan, width: 2))
                : null,
            color: widget.selected ? _cyan.withValues(alpha: 0.08) : null,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: widget.onPlay,
              onLongPress: widget.onLongPress ?? () => showCardMenu(context, item),
              onFocusChange: (f) => setState(() => _hot = f),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: phone ? 6 : 8, horizontal: phone ? 2 : 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: phone ? 26 : 48,
                      child: Text(
                        '${widget.index + 1}',
                        textAlign: TextAlign.center,
                        style: heading.copyWith(
                          fontSize: phone ? 20 : 30,
                          fontWeight: FontWeight.w800,
                          height: 1,
                          foreground: Paint()
                            ..style = PaintingStyle.stroke
                            ..strokeWidth = 1.3
                            ..color = _hot ? _cyan : const Color(0x80E8E9F0),
                        ),
                      ),
                    ),
                    SizedBox(width: phone ? 8 : 14),
                    thumb,
                    SizedBox(width: phone ? 12 : 20),
                    Expanded(child: text),
                    if (widget.picking)
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Icon(
                          widget.selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                          color: widget.selected ? _cyan : _muted,
                        ),
                      )
                    else ...[
                      if (!phone) ...[
                        const SizedBox(width: 12),
                        GlassRound(tooltip: 'Move up', size: 40, icon: const Icon(Icons.keyboard_arrow_up_rounded), onPressed: widget.onUp),
                        const SizedBox(width: 6),
                        GlassRound(tooltip: 'Move down', size: 40, icon: const Icon(Icons.keyboard_arrow_down_rounded), onPressed: widget.onDown),
                        const SizedBox(width: 6),
                        GlassRound(tooltip: 'Remove from the playlist', size: 40, icon: const Icon(Icons.close_rounded), onPressed: widget.onRemove),
                      ],
                      // Phone: the menu, as long press picks.
                      if (phone)
                        IconButton(
                          tooltip: 'More',
                          icon: const Icon(Icons.more_vert, color: _muted),
                          onPressed: () => showCardMenu(context, item),
                        ),
                      handle,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final risen = RiseIn(delay: math.min(widget.index * 30, 240), child: row);
    if (!phone || widget.picking) return risen;
    // Phone: a swipe to the left takes it out.
    return Dismissible(
      key: ValueKey('swipe-${playlistEntryId(item) ?? item.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.playlist_remove, color: _cyan),
      ),
      onDismissed: (_) => widget.onRemove(),
      child: risen,
    );
  }
}
