import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/layout.dart';
import '../../app/toast.dart';
import '../../core/jellyfin/items.dart';
import '../library/widgets/action_menu.dart';
import '../library/widgets/selection.dart';
import 'downloads.dart';

String formatBytes(int bytes) => switch (bytes) {
  < 1024 * 1024 => '${(bytes / 1024).toStringAsFixed(0)} KB',
  < 1024 * 1024 * 1024 => '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB',
  _ => '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB',
};

/// Downloads, grouped by show and season: progress, pause / resume, play,
/// delete; several at once by selecting. Works offline.
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

/// One show's season (or the movies) on the Downloads page.
class _Group {
  _Group(this.key, this.title);

  final String key;
  final String title;
  final records = <DownloadRecord>[];

  int get bytes => records.fold(0, (a, r) => a + r.received);
}

List<_Group> _groupsOf(Iterable<DownloadRecord> records) {
  final groups = <String, _Group>{};
  for (final r in records) {
    final i = r.baseItem;
    final (key, title) = i.type == ItemType.episode
        ? (
            '${i.seriesId ?? i.seriesName}/${i.seasonId ?? i.parentIndexNumber}',
            [
              i.seriesName ?? 'Show',
              i.seasonName ?? (i.parentIndexNumber == null ? null : 'Season ${i.parentIndexNumber}'),
            ].nonNulls.join(' · '),
          )
        : ('movies', 'Movies');
    groups.putIfAbsent(key, () => _Group(key, title)).records.add(r);
  }
  for (final g in groups.values) {
    g.records.sort((a, b) => (a.baseItem.indexNumber ?? 0).compareTo(b.baseItem.indexNumber ?? 0));
  }
  return groups.values.toList()..sort((a, b) => a.title.compareTo(b.title));
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  final _selection = Selection();
  final _scroll = ScrollController();
  final _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    _selection.addListener(() => setState(() {}));
    // Back online? Send what was watched offline.
    // (The notifier now: the screen may be gone by the time it's loaded.)
    final downloads = ref.read(downloadsProvider.notifier);
    ref.read(downloadsProvider.future).then((_) => downloads.syncPending(), onError: (Object _) {});
  }

  @override
  void dispose() {
    _selection.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _deleteSelected(List<DownloadRecord> all) async {
    final chosen = [
      for (final r in all)
        if (_selection.contains(r.itemId)) r,
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${chosen.length} download${chosen.length == 1 ? '' : 's'}?'),
        content: Text(
          '${formatBytes(chosen.fold(0, (a, r) => a + r.received))} on this device. They stay on the server.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final controller = ref.read(downloadsProvider.notifier);
    for (final r in chosen) {
      await controller.remove(r.itemId);
    }
    _selection.clear();
    showToast('Deleted ${chosen.length} download${chosen.length == 1 ? '' : 's'}');
  }

  void _pauseOrResumeSelected(List<DownloadRecord> all, {required bool pause}) {
    final controller = ref.read(downloadsProvider.notifier);
    for (final r in all) {
      if (!_selection.contains(r.itemId) || r.status == DownloadStatus.done) continue;
      pause ? controller.pause(r.itemId) : controller.resume(r.itemId);
    }
    _selection.clear();
  }

  @override
  Widget build(BuildContext context) {
    final downloads = ref.watch(downloadsProvider);
    final controller = ref.read(downloadsProvider.notifier);
    final records = downloads.value?.records.values.toList() ?? const <DownloadRecord>[];
    final groups = _groupsOf(records);
    // The order on screen, for Shift+click ranges.
    final order = [
      for (final g in groups)
        for (final r in g.records) r.itemId,
    ];
    void selectAll() => _selection.setAll(order);
    final chosen = [
      for (final r in records)
        if (_selection.contains(r.itemId)) r,
    ];
    final unfinished = chosen.where((r) => r.status != DownloadStatus.done).toList();

    return SelectionShortcuts(
      autofocus: true,
      selection: _selection,
      selectAll: selectAll,
      child: Scaffold(
        appBar: AppBar(title: const Text('Downloads')),
        body: FloatingSelectionBar(
          selection: _selection,
          controller: _scroll,
          alwaysShown: ref.watch(isTvProvider),
          label: '${chosen.length} selected · ${formatBytes(chosen.fold(0, (a, r) => a + r.received))}',
          actions: [
            TextButton.icon(onPressed: selectAll, icon: const Icon(Icons.select_all), label: const Text('Select all')),
            if (unfinished.any((r) => r.status == DownloadStatus.downloading || r.status == DownloadStatus.queued))
              IconButton(
                tooltip: 'Pause',
                icon: const Icon(Icons.pause),
                onPressed: () => _pauseOrResumeSelected(records, pause: true),
              )
            else if (unfinished.isNotEmpty)
              IconButton(
                tooltip: 'Resume',
                icon: const Icon(Icons.play_arrow),
                onPressed: () => _pauseOrResumeSelected(records, pause: false),
              ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteSelected(records),
            ),
          ],
          child: switch (downloads) {
            AsyncData(:final value) when value.records.isEmpty => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nothing downloaded yet. Use Download on a movie, episode or season.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            AsyncData(:final value) => ListView(
              controller: _scroll,
              // Room for the floating bar under the last row.
              padding: EdgeInsets.only(bottom: _selection.active ? 88 : 0),
              children: [
                ListTile(
                  dense: true,
                  title: Text('${value.records.length} downloads · ${formatBytes(controller.bytesUsed)}'),
                  subtitle: value.pending.isEmpty
                      ? null
                      : Text('${value.pending.length} watched offline, sent when online'),
                ),
                for (final g in groups) ...[
                  _GroupHeader(
                    group: g,
                    collapsed: _collapsed.contains(g.key),
                    selected: switch (g.records.where((r) => _selection.contains(r.itemId)).length) {
                      0 => false,
                      final n when n == g.records.length => true,
                      _ => null,
                    },
                    onToggleCollapsed: () =>
                        setState(() => _collapsed.contains(g.key) ? _collapsed.remove(g.key) : _collapsed.add(g.key)),
                    onSelected: (on) => _selection.setAll([for (final r in g.records) r.itemId], on: on),
                  ),
                  if (!_collapsed.contains(g.key))
                    for (final r in g.records) _DownloadTile(record: r, selection: _selection, order: order),
                ],
              ],
            ),
            AsyncError(:final error) => Center(child: Text("Couldn't load downloads: $error")),
            _ => const Center(child: CircularProgressIndicator()),
          },
        ),
      ),
    );
  }
}

/// "The Apothecary Diaries · Season 2 · 24 episodes · 25 GB", with a
/// checkbox for the whole group and a collapse arrow.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.collapsed,
    required this.selected,
    required this.onToggleCollapsed,
    required this.onSelected,
  });

  final _Group group;
  final bool collapsed;

  /// All, none, or some (null) of the group selected.
  final bool? selected;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final n = group.records.length;
    return ListTile(
      leading: Checkbox(tristate: true, value: selected, onChanged: (_) => onSelected(selected != true)),
      title: Text(group.title, style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text(
        '$n ${group.key == 'movies' ? (n == 1 ? 'movie' : 'movies') : (n == 1 ? 'episode' : 'episodes')} · ${formatBytes(group.bytes)}',
      ),
      trailing: IconButton(
        tooltip: collapsed ? 'Show' : 'Hide',
        icon: Icon(collapsed ? Icons.expand_more : Icons.expand_less),
        onPressed: onToggleCollapsed,
      ),
      onTap: onToggleCollapsed,
    );
  }
}

class _DownloadTile extends ConsumerStatefulWidget {
  const _DownloadTile({required this.record, required this.selection, required this.order});

  final DownloadRecord record;
  final Selection selection;
  final List<String> order;

  @override
  ConsumerState<_DownloadTile> createState() => _DownloadTileState();
}

class _DownloadTileState extends ConsumerState<_DownloadTile> {
  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final item = r.baseItem;
    final selection = widget.selection;
    final selected = selection.contains(r.itemId);
    final controller = ref.read(downloadsProvider.notifier);
    final episode = item.type == ItemType.episode;
    final title = episode ? '${item.seriesName ?? ''} · ${item.episodeLabel ?? ''}' : item.name;
    final status = switch (r.status) {
      DownloadStatus.done => formatBytes(r.received),
      DownloadStatus.downloading =>
        r.total == null ? formatBytes(r.received) : '${formatBytes(r.received)} of ${formatBytes(r.total!)}',
      DownloadStatus.queued => 'Waiting',
      DownloadStatus.paused => 'Paused${r.progress == null ? '' : ' at ${(r.progress! * 100).round()}%'}',
      DownloadStatus.failed => r.error ?? 'Failed',
    };
    void play() => context.push('/play/${r.itemId}');
    // Right-click: a popup there; a remote's menu key: a sheet.
    void menu([Offset? at]) => showActionMenu(
      context,
      at: at,
      title: title,
      entries: [
        MenuEntry(
          icon: Icons.check_box_outlined,
          label: selected ? 'Deselect' : 'Select',
          onSelected: () => selection.toggle(r.itemId),
        ),
        if (r.status == DownloadStatus.done) MenuEntry(icon: Icons.play_arrow, label: 'Play', onSelected: play),
        MenuEntry(icon: Icons.delete_outline, label: 'Delete', onSelected: () => controller.remove(r.itemId)),
      ],
    );
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.contextMenu): menu},
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: EdgeInsets.symmetric(horizontal: selected ? 8 : 0),
        decoration: selectedRowDecoration(context, selected: selected),
        child: GestureDetector(
          onSecondaryTapUp: (d) => menu(d.globalPosition),
          child: Material(
            // The highlight is around the row; its ripple still shows.
            type: MaterialType.transparency,
            child: ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              leading: Icon(switch (r.status) {
                DownloadStatus.done => Icons.download_done,
                DownloadStatus.failed => Icons.error_outline,
                DownloadStatus.paused => Icons.pause_circle_outline,
                _ => Icons.downloading,
              }),
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (episode) Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(status),
                  if (r.status == DownloadStatus.downloading || r.status == DownloadStatus.paused)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: LinearProgressIndicator(value: r.progress),
                    ),
                ],
              ),
              onTap: () {
                if (selection.tap(widget.order, r.itemId)) return;
                if (r.status == DownloadStatus.done) play();
              },
              // Long press selects (and starts selecting); while selecting,
              // the menu, for Play / Delete without right-click.
              onLongPress: () => selection.active ? menu() : selection.toggle(r.itemId),
              trailing: selection.active
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (r.status == DownloadStatus.done)
                          IconButton(tooltip: 'Play', icon: const Icon(Icons.play_arrow), onPressed: play)
                        else if (r.status == DownloadStatus.downloading || r.status == DownloadStatus.queued)
                          IconButton(
                            tooltip: 'Pause',
                            icon: const Icon(Icons.pause),
                            onPressed: () => controller.pause(r.itemId),
                          )
                        else
                          IconButton(
                            tooltip: 'Resume',
                            icon: const Icon(Icons.refresh),
                            onPressed: () => controller.resume(r.itemId),
                          ),
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => controller.remove(r.itemId),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Starts downloading [item] (an episode or movie; a season or show: its
/// episodes), with a message that leads to Downloads.
Future<void> startDownload(BuildContext context, BaseItem item) async {
  final controller = ProviderScope.containerOf(context, listen: false).read(downloadsProvider.notifier);
  try {
    // No toast now (the button shows the progress); one when it's done.
    await controller.add(item);
  } on Object catch (e) {
    showToast("Couldn't start the download: $e");
  }
}

bool canDownload(BaseItem item) =>
    const {ItemType.movie, ItemType.episode, ItemType.season, ItemType.series}.contains(item.type);

bool _many(BaseItem item) => item.type == ItemType.season || item.type == ItemType.series;

String _downloadLabel(BaseItem item) => switch (item.type) {
  ItemType.season => 'Download season',
  ItemType.series => 'Download all',
  _ => 'Download',
};

/// "Download" (or its state) for a card's menu; null if it can't be.
MenuEntry? downloadMenuEntry(BuildContext context, BaseItem item) {
  if (!canDownload(item)) return null;
  final container = ProviderScope.containerOf(context, listen: false);
  final r = _many(item) ? null : container.read(downloadsProvider).value?[item.id];
  return switch (r?.status) {
    null => MenuEntry(
      icon: Icons.download_outlined,
      label: _downloadLabel(item),
      onSelected: () => startDownload(context, item),
    ),
    DownloadStatus.done => MenuEntry(
      icon: Icons.delete_outline,
      label: 'Delete download',
      onSelected: () => container.read(downloadsProvider.notifier).remove(item.id),
    ),
    _ => MenuEntry(
      icon: Icons.downloading,
      label: 'Downloading…',
      onSelected: () => GoRouter.of(context).push('/downloads'),
    ),
  };
}

/// Download / downloading / downloaded, for a detail page: a labelled
/// button.
class DownloadButton extends ConsumerWidget {
  const DownloadButton({super.key, required this.item});

  final BaseItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = _many(item) ? null : ref.watch(downloadsProvider).value?[item.id];
    final controller = ref.read(downloadsProvider.notifier);
    return switch (r?.status) {
      null => OutlinedButton.icon(
        onPressed: () => startDownload(context, item),
        icon: const Icon(Icons.download_outlined),
        label: Text(_downloadLabel(item)),
      ),
      DownloadStatus.done => OutlinedButton.icon(
        onPressed: () => confirmDeleteDownload(context, ref, item),
        icon: const Icon(Icons.download_done),
        label: const Text('Downloaded'),
      ),
      DownloadStatus.failed => OutlinedButton.icon(
        onPressed: () => controller.resume(item.id),
        icon: const Icon(Icons.error_outline),
        label: const Text('Download failed: retry'),
      ),
      DownloadStatus.paused => OutlinedButton.icon(
        onPressed: () => controller.resume(item.id),
        icon: const Icon(Icons.play_arrow),
        label: Text('Paused${_percent(r!)}: resume'),
      ),
      _ => OutlinedButton.icon(
        onPressed: () => confirmDeleteDownload(context, ref, item),
        icon: SizedBox.square(dimension: 18, child: CircularProgressIndicator(value: r!.progress, strokeWidth: 2)),
        label: Text('Downloading${_percent(r)}: delete'),
      ),
    };
  }
}

String _percent(DownloadRecord r) => r.progress == null ? '' : ' ${(r.progress! * 100).round()}%';

/// A small download button for one episode in a list.
class EpisodeDownloadButton extends ConsumerWidget {
  const EpisodeDownloadButton({super.key, required this.episode});

  final BaseItem episode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(downloadsProvider).value?[episode.id];
    final controller = ref.read(downloadsProvider.notifier);
    return switch (r?.status) {
      null => IconButton(
        tooltip: 'Download',
        icon: const Icon(Icons.download_outlined),
        onPressed: () => startDownload(context, episode),
      ),
      DownloadStatus.done => IconButton(
        tooltip: 'Downloaded (delete)',
        icon: Icon(Icons.download_done, color: Theme.of(context).colorScheme.primary),
        onPressed: () => confirmDeleteDownload(context, ref, episode),
      ),
      DownloadStatus.failed => IconButton(
        tooltip: r!.error ?? 'Download failed: retry',
        icon: const Icon(Icons.error_outline),
        onPressed: () => controller.resume(episode.id),
      ),
      DownloadStatus.paused => IconButton(
        tooltip: 'Paused: resume',
        icon: const Icon(Icons.pause_circle_outline),
        onPressed: () => controller.resume(episode.id),
      ),
      _ => IconButton(
        tooltip: 'Downloading: delete',
        onPressed: () => confirmDeleteDownload(context, ref, episode),
        icon: SizedBox.square(dimension: 20, child: CircularProgressIndicator(value: r!.progress, strokeWidth: 2.5)),
      ),
    };
  }
}

Future<void> confirmDeleteDownload(BuildContext context, WidgetRef ref, BaseItem item) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text('Delete the download of ${item.name}?'),
      content: const Text('It stays on the server; only the copy on this device goes.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
      ],
    ),
  );
  if (ok == true) await ref.read(downloadsProvider.notifier).remove(item.id);
}
