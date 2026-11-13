import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/toast.dart';
import '../../app/layout.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/library_api.dart';
import '../../core/jellyfin/week_api.dart';
import '../../core/seerr/seerr_api.dart';
import '../../core/seerr/seerr_discover.dart';
import '../library/library_providers.dart';
import '../library/widgets/media_card.dart';
import '../seerr/seerr_providers.dart';
import '../seerr/widgets/seerr_widgets.dart';
import '../../theme/components.dart';
import 'home_components.dart';
import 'home_layout.dart';
import 'more_for_you.dart';
import 'recommendations.dart';
import 'suggestion_filters_screen.dart';
import 'this_week.dart';
import '../../app/app_dropdown.dart';

/// Settings > Home: reorder, hide, add, edit and remove home rows.
class HomeEditorScreen extends ConsumerWidget {
  const HomeEditorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = ref.watch(homeLayoutProvider);
    final controller = ref.read(homeLayoutProvider.notifier);
    final isTv = ref.watch(isTvProvider);
    final seerr = ref.watch(seerrAccountProvider).value != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Home rows'),
        actions: [
          TextButton(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Reset the home page?'),
                  content: const Text('Puts back the default rows and removes your own rows.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reset')),
                  ],
                ),
              );
              if (ok ?? false) await controller.reset();
            },
            child: const Text('Reset'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add row'),
        onPressed: () => _addRow(context, ref, seerr: seerr),
      ),
      body: switch (layout) {
        AsyncData(value: final rows) => ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            // TV remotes can't drag: up / down buttons instead.
            buildDefaultDragHandles: !isTv,
            header: const Column(children: [_MoreForYouSettings(), _ThisWeekSettings()]),
            itemCount: rows.length,
            onReorderItem: (from, to) {
              final next = [...rows];
              next.insert(to, next.removeAt(from));
              controller.save(next);
            },
            itemBuilder: (context, i) {
              final row = rows[i];
              void move(int by) {
                final next = [...rows]..removeAt(i);
                next.insert((i + by).clamp(0, next.length), row);
                controller.save(next);
              }

              final (title, kind) = switch (row) {
                BuiltInRow() => (row.title, row.kind.isSeerr ? 'Seerr' : 'Built-in'),
                JellyfinHomeRow() => (row.title, 'Jellyfin'),
                SeerrHomeRow() => (row.title, 'Seerr · ${row.spec.source.label}'),
              };
              final custom = row is! BuiltInRow;
              return ListTile(
                key: ValueKey(row.id),
                title: Text(title, style: row.visible ? null : TextStyle(color: Theme.of(context).disabledColor)),
                subtitle: Text(kind),
                leading: Switch(
                  value: row.visible,
                  onChanged: (v) => controller.save([for (final r in rows) r.id == row.id ? r.withVisible(v) : r]),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isTv) ...[
                      IconButton(tooltip: 'Move up', icon: const Icon(Icons.arrow_upward), onPressed: i == 0 ? null : () => move(-1)),
                      IconButton(
                        tooltip: 'Move down',
                        icon: const Icon(Icons.arrow_downward),
                        onPressed: i == rows.length - 1 ? null : () => move(1),
                      ),
                    ],
                    if (custom) ...[
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _edit(context, ref, row),
                      ),
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => controller.save([for (final r in rows) if (r.id != row.id) r]),
                      ),
                    ],
                    if (!isTv) const SizedBox(width: 32), // room for the drag handle
                  ],
                ),
              );
            },
          ),
        AsyncError(:final error) => Center(child: Text("Couldn't load the home layout: $error")),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Future<void> _addRow(BuildContext context, WidgetRef ref, {required bool seerr}) async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('From your Jellyfin libraries'),
              onTap: () => Navigator.pop(context, 'jellyfin'),
            ),
            ListTile(
              leading: const Icon(Icons.explore_outlined),
              title: const Text('From Seerr'),
              subtitle: seerr ? null : const Text('Sign in to Seerr in Settings first'),
              enabled: seerr,
              onTap: () => Navigator.pop(context, 'seerr'),
            ),
          ],
        ),
      ),
    );
    if (kind == null || !context.mounted) return;
    final id = HomeLayoutController.newId();
    await _edit(
      context,
      ref,
      kind == 'jellyfin'
          ? JellyfinHomeRow(id: id, title: 'My row')
          : SeerrHomeRow(id: id, title: 'My Seerr row', spec: const SeerrRowSpec()),
      isNew: true,
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, HomeRow row, {bool isNew = false}) async {
    final edited = await Navigator.of(context).push<HomeRow>(MaterialPageRoute(
      builder: (_) => switch (row) {
        JellyfinHomeRow() => _JellyfinRowEditor(initial: row),
        SeerrHomeRow() => _SeerrRowEditor(initial: row),
        BuiltInRow() => throw StateError('Built-in rows are not edited'),
      },
    ));
    if (edited == null) return;
    final rows = await ref.read(homeLayoutProvider.future);
    await ref.read(homeLayoutProvider.notifier).save(
          isNew ? [...rows, edited] : [for (final r in rows) r.id == edited.id ? edited : r],
        );
  }
}

/// The "More for you" switches, above the row list.
/// Where This week comes from, and what it's showing right now.
class _ThisWeekSettings extends ConsumerWidget {
  const _ThisWeekSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(weekSourceChoiceProvider).value ?? WeekSourceChoice.automatic;
    final week = ref.watch(thisWeekProvider);
    return ListTile(
      leading: const Icon(Icons.event_note_outlined),
      title: const Text('This week comes from'),
      subtitle: Text(switch (week) {
        AsyncData(:final value) => weekSourceStatus(value),
        AsyncError() => "Couldn't load it from your server",
        _ => choice.description,
      }),
      trailing: AppDropdown<WeekSourceChoice>(
        value: choice,
        underline: const SizedBox.shrink(),
        items: [for (final c in WeekSourceChoice.values) DropdownMenuItem(value: c, child: Text(c.label))],
        onChanged: (c) {
          if (c != null) ref.read(weekSourceChoiceProvider.notifier).save(c);
        },
      ),
    );
  }
}

class _MoreForYouSettings extends ConsumerWidget {
  const _MoreForYouSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(moreForYouSettingsProvider).value ?? const MoreForYouSettings();
    final controller = ref.read(moreForYouSettingsProvider.notifier);
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.all_inclusive),
          title: const Text('More for you (endless)'),
          subtitle: const Text('Under your rows, keep suggesting rows from what you watch, as you scroll'),
          value: s.enabled,
          onChanged: (v) => controller.save(s.copyWith(enabled: v)),
        ),
        if (s.enabled) ...[
          ListTile(
            leading: const SizedBox(width: 24),
            title: const Text('Filters'),
            trailing: FilterSetDropdown(
              value: s.filterSetId,
              onChanged: (id) => controller.save(s.copyWith(filterSetId: id)),
            ),
          ),
          SwitchListTile(
            secondary: const SizedBox(width: 24),
            title: const Text('Include unwatched titles from your library'),
            subtitle: const Text('Otherwise only suggestions from Seerr'),
            value: s.fromLibrary,
            onChanged: (v) => controller.save(s.copyWith(fromLibrary: v)),
          ),
          if (s.notInterested.isNotEmpty)
            ListTile(
              leading: const SizedBox(width: 24),
              title: Text('Rows marked "Not interested": ${s.notInterested.length}'),
              trailing: TextButton(
                onPressed: () => controller.save(s.copyWith(notInterested: const {})),
                child: const Text('Show them again'),
              ),
            ),
        ],
        ListTile(
          leading: const Icon(Icons.filter_alt_outlined),
          title: const Text('Suggestion filters'),
          subtitle: const Text('Conditions for recommendations and More for you (e.g. Anime: Animation + Japanese)'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SuggestionFiltersScreen())),
        ),
        const Divider(),
      ],
    );
  }
}

/// Editor page frame: the form, a live preview of the row, and Save.
class _EditorScaffold extends StatelessWidget {
  const _EditorScaffold({required this.title, required this.preview, required this.onSave, required this.children});

  final String title;
  final Widget preview;
  final VoidCallback onSave;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [FilledButton(onPressed: onSave, child: const Text('Save')), const SizedBox(width: 12)],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          // Live preview: the row as it will look on Home.
          preview,
          const Divider(height: 32),
          ...children,
        ],
      ),
    );
  }
}

class _JellyfinRowEditor extends ConsumerStatefulWidget {
  const _JellyfinRowEditor({required this.initial});

  final JellyfinHomeRow initial;

  @override
  ConsumerState<_JellyfinRowEditor> createState() => _JellyfinRowEditorState();
}

class _JellyfinRowEditorState extends ConsumerState<_JellyfinRowEditor> {
  late JellyfinHomeRow _row = widget.initial;
  late final _name = TextEditingController(text: widget.initial.title);

  static const _types = {
    ItemType.series: 'Shows',
    ItemType.movie: 'Movies',
    ItemType.episode: 'Episodes',
    ItemType.boxSet: 'Collections',
  };

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _set(JellyfinHomeRow row) => setState(() => _row = row);

  @override
  Widget build(BuildContext context) {
    final views = ref.watch(viewsProvider).value ?? const <BaseItem>[];
    final genres = ref.watch(genresProvider(_row.libraryId)).value ?? const <String>[];
    return _EditorScaffold(
      title: 'Jellyfin row',
      onSave: () => Navigator.pop(context, _row.copyWith(title: _name.text.trim().isEmpty ? 'My row' : _name.text.trim())),
      // In the active theme's style for such a row, with the chosen look.
      preview: libraryRow(
        context,
        ref,
        Slots.libraryRow,
        LibraryRowData(
          title: _name.text.isEmpty ? 'Preview' : _name.text,
          items: ref.watch(jellyfinRowProvider(_row)),
          shape: _row.landscape ? CardShape.landscape : CardShape.poster,
          onItemPressed: (_) {},
          look: _row.look.name,
        ),
      ),
      children: [
        _Field(
          child: TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Row name', border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
        ),
        ListTile(
          title: const Text('Library'),
          trailing: AppDropdown<String?>(
            value: _row.libraryId,
            items: [
              const DropdownMenuItem(value: null, child: Text('All libraries')),
              for (final v in views) DropdownMenuItem(value: v.id, child: Text(v.name)),
            ],
            onChanged: (id) => _set(_row.copyWith(
              libraryId: () => id,
              libraryName: () => views.where((v) => v.id == id).firstOrNull?.name,
              genres: const [],
            )),
          ),
        ),
        _Chips(
          label: 'Types',
          children: [
            for (final e in _types.entries)
              FilterChip(
                label: Text(e.value),
                selected: _row.types.contains(e.key),
                onSelected: (on) {
                  final types = on ? [..._row.types, e.key] : [..._row.types.where((t) => t != e.key)];
                  if (types.isNotEmpty) _set(_row.copyWith(types: types));
                },
              ),
          ],
        ),
        ListTile(
          title: const Text('Genres'),
          subtitle: Text(_row.genres.isEmpty ? 'Any' : _row.genres.join(', ')),
          trailing: const Icon(Icons.chevron_right),
          enabled: genres.isNotEmpty,
          onTap: () async {
            final picked = await pickMany(
              context,
              title: 'Genres',
              options: [for (final g in genres) SeerrOption(g, g)],
              selected: [for (final g in _row.genres) SeerrOption(g, g)],
            );
            if (picked != null) _set(_row.copyWith(genres: [for (final o in picked) o.id]));
          },
        ),
        ListTile(
          title: const Text('Show'),
          trailing: AppDropdown<JellyfinRowFilter>(
            value: _row.filter,
            items: [for (final f in JellyfinRowFilter.values) DropdownMenuItem(value: f, child: Text(f.label))],
            onChanged: (f) => f == null ? null : _set(_row.copyWith(filter: f)),
          ),
        ),
        ListTile(
          title: const Text('Sort by'),
          trailing: AppDropdown<SortField>(
            value: _row.sort,
            items: [for (final s in SortField.values) DropdownMenuItem(value: s, child: Text(s.label))],
            onChanged: (s) => s == null ? null : _set(_row.copyWith(sort: s)),
          ),
        ),
        SwitchListTile(
          title: const Text('Newest / highest first'),
          value: _row.descending,
          onChanged: (v) => _set(_row.copyWith(descending: v)),
        ),
        _LimitTile(value: _row.limit, onChanged: (v) => _set(_row.copyWith(limit: v))),
        SwitchListTile(
          title: const Text('Wide cards'),
          subtitle: const Text('Episode stills instead of posters'),
          value: _row.landscape,
          onChanged: (v) => _set(_row.copyWith(landscape: v)),
        ),
        ListTile(
          title: const Text('Look'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('In themes with their own rows (Depth): ${_row.look.description.toLowerCase()}'),
              const SizedBox(height: 8),
              SegmentedButton<RowLook>(
                segments: [for (final l in RowLook.values) ButtonSegment(value: l, label: Text(l.label))],
                selected: {_row.look},
                showSelectedIcon: false,
                onSelectionChanged: (s) => _set(_row.copyWith(look: s.first)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// --- Seerr lookups for the pickers (kept while the editor is open) ---

final _seerrGenresProvider = FutureProvider.autoDispose.family<List<SeerrOption>, SeerrMediaType>(
  (ref, type) async => (await ref.watch(seerrApiProvider)?.genres(type)) ?? const [],
);
final _seerrLanguagesProvider = FutureProvider.autoDispose<List<SeerrOption>>(
  (ref) async => (await ref.watch(seerrApiProvider)?.languages()) ?? const [],
);
final _seerrRegionsProvider = FutureProvider.autoDispose<List<SeerrOption>>(
  (ref) async => (await ref.watch(seerrApiProvider)?.watchRegions()) ?? const [],
);
final _seerrProvidersProvider = FutureProvider.autoDispose.family<List<SeerrOption>, (SeerrMediaType, String)>(
  (ref, key) async => (await ref.watch(seerrApiProvider)?.watchProviders(key.$1, key.$2)) ?? const [],
);
final _seerrCertificationsProvider = FutureProvider.autoDispose.family<Map<String, List<String>>, SeerrMediaType>(
  (ref, type) async => (await ref.watch(seerrApiProvider)?.certifications(type)) ?? const {},
);

class _SeerrRowEditor extends ConsumerStatefulWidget {
  const _SeerrRowEditor({required this.initial});

  final SeerrHomeRow initial;

  @override
  ConsumerState<_SeerrRowEditor> createState() => _SeerrRowEditorState();
}

class _SeerrRowEditorState extends ConsumerState<_SeerrRowEditor> {
  late SeerrHomeRow _row = widget.initial;
  late final _name = TextEditingController(text: widget.initial.title);

  SeerrRowSpec get _spec => _row.spec;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _setSpec(SeerrRowSpec spec) => setState(() => _row = _row.copyWith(spec: spec));

  /// [SeerrRowSpec] has no copyWith; rebuild it from JSON with changes.
  SeerrRowSpec _with(Map<String, dynamic> changes) => SeerrRowSpec.fromJson({..._spec.toJson(), ...changes});

  List<Map<String, dynamic>> _json(List<SeerrOption> options) => [for (final o in options) o.toJson()];

  Future<void> _pick(
      String key, String title, Future<List<SeerrOption>> Function() options, List<SeerrOption> selected) async {
    final loaded = await options();
    if (!mounted) return;
    final picked = await pickMany(context, title: title, options: loaded, selected: selected);
    if (picked != null) _setSpec(_with({key: _json(picked)}));
  }

  Future<void> _search(String key, String title, Future<List<SeerrOption>> Function(String) search,
      List<SeerrOption> selected) async {
    final picked = await searchMany(context, title: title, search: search, selected: selected);
    if (picked != null) _setSpec(_with({key: _json(picked)}));
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(seerrApiProvider);
    final type = _spec.mediaType;
    final discover = _spec.source.isDiscover;
    final region = _spec.watchRegion ?? 'US';
    final certs = ref.watch(_seerrCertificationsProvider(type)).value ?? const {};
    final certCountry = _spec.certificationCountry ?? 'US';
    String names(List<SeerrOption> list, [String none = 'Any']) =>
        list.isEmpty ? none : list.map((o) => o.name).join(', ');

    return _EditorScaffold(
      title: 'Seerr row',
      // Recommendation rows may stay unnamed: Home names them
      // ("Because you watched Frieren").
      onSave: () => Navigator.pop(
        context,
        _row.copyWith(
          title: _name.text.trim().isNotEmpty || _spec.source.isRecommendation ? _name.text.trim() : 'My Seerr row',
        ),
      ),
      preview: SeerrMediaRow(
        title: seerrRowTitle(ref, _row.copyWith(title: _name.text)),
        subtitle: seerrRowSubtitle(ref, _row),
        items: ref.watch(seerrHomeRowProvider(_row)),
      ),
      children: [
        _Field(
          child: TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: 'Row name',
              helperText: _spec.source.isRecommendation ? 'Leave empty for an automatic name' : null,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        ListTile(
          title: const Text('Source'),
          trailing: AppDropdown<SeerrSource>(
            value: _spec.source,
            items: [for (final s in SeerrSource.values) DropdownMenuItem(value: s, child: Text(s.label))],
            // Genres etc. differ between TV and movies: start them over.
            onChanged: (s) => s == null
                ? null
                : _setSpec(s.isRecommendation
                    // New things to watch: leave out what's on the server.
                    ? SeerrRowSpec(source: s, hideAvailable: true)
                    : s.isTv == _spec.source.isTv && !_spec.source.isRecommendation
                        ? _with({'source': s.name})
                        : SeerrRowSpec(source: s, hideAvailable: _spec.hideAvailable)),
          ),
        ),
        if (_spec.source == SeerrSource.becauseYouWatched) _seedTile(),
        if (_spec.source.isRecommendation)
          ListTile(
            title: const Text('Filters'),
            subtitle: const Text('Suggestion filters this row follows'),
            trailing: FilterSetDropdown(
              value: _spec.filterSetId,
              onChanged: (id) => _setSpec(_with({'filterSetId': id})),
            ),
          ),
        if (_spec.source == SeerrSource.recommendedForYou)
          const ListTile(
            title: Text('From your library'),
            subtitle: Text('What your favourite, finished and current shows recommend, most recommended first'),
          ),
        if (_spec.source == SeerrSource.pickedForYou)
          ListTile(
            title: const Text('Picked from'),
            subtitle: const Text('Your most-watched genres, keywords and language'),
            trailing: AppDropdown<SeerrTrendingType>(
              value: _spec.trendingType,
              items: const [
                DropdownMenuItem(value: SeerrTrendingType.all, child: Text('Automatic')),
                DropdownMenuItem(value: SeerrTrendingType.tv, child: Text('TV')),
                DropdownMenuItem(value: SeerrTrendingType.movie, child: Text('Movies')),
              ],
              onChanged: (t) => t == null ? null : _setSpec(_with({'trendingType': t.name})),
            ),
          ),
        if (_spec.source == SeerrSource.trending) ...[
          ListTile(
            title: const Text('Trending'),
            trailing: AppDropdown<SeerrTrendingType>(
              value: _spec.trendingType,
              items: [for (final t in SeerrTrendingType.values) DropdownMenuItem(value: t, child: Text(t.label))],
              onChanged: (t) => t == null ? null : _setSpec(_with({'trendingType': t.name})),
            ),
          ),
          SwitchListTile(
            title: const Text('This week (off: today)'),
            value: _spec.trendingWeek,
            onChanged: (v) => _setSpec(_with({'trendingWeek': v})),
          ),
        ],
        if (discover) ...[
          const _Heading('What'),
          ListTile(
            title: const Text('Genres'),
            subtitle: Text(names(_spec.genres)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pick(
              'genres',
              'Genres (all of)',
              () => ref.read(_seerrGenresProvider(type).future),
              _spec.genres,
            ),
          ),
          ListTile(
            title: const Text('Keywords'),
            subtitle: Text(names(_spec.keywords)),
            trailing: const Icon(Icons.chevron_right),
            onTap: api == null ? null : () => _search('keywords', 'Keywords (all of)', api.searchKeywords, _spec.keywords),
          ),
          ListTile(
            title: const Text('Leave out keywords'),
            subtitle: Text(names(_spec.excludeKeywords, 'None')),
            trailing: const Icon(Icons.chevron_right),
            onTap: api == null
                ? null
                : () => _search('excludeKeywords', 'Leave out keywords', api.searchKeywords, _spec.excludeKeywords),
          ),
          ListTile(
            title: const Text('Original language'),
            subtitle: Text(names(_spec.originalLanguages)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pick(
              'originalLanguages',
              'Original language (any of)',
              () => ref.read(_seerrLanguagesProvider.future),
              _spec.originalLanguages,
            ),
          ),
          if (type == SeerrMediaType.movie)
            ListTile(
              title: const Text('Studio'),
              subtitle: Text(_spec.company?.name ?? 'Any'),
              trailing: const Icon(Icons.chevron_right),
              onTap: api == null
                  ? null
                  : () async {
                      final picked = await searchMany(
                        context,
                        title: 'Studio',
                        search: api.searchCompanies,
                        selected: [?_spec.company],
                        single: true,
                      );
                      if (picked != null) _setSpec(_with({'company': picked.firstOrNull?.toJson()}));
                    },
            )
          else
            ListTile(
              title: const Text('Network'),
              subtitle: Text(_spec.company?.name ?? 'Any'),
              trailing: const Icon(Icons.chevron_right),
              onTap: api == null ? null : () => _pickNetwork(api),
            ),
          if (type == SeerrMediaType.tv)
            _Chips(
              label: 'Status (any of)',
              children: [
                for (final e in seerrTvStatuses.entries)
                  FilterChip(
                    label: Text(e.value),
                    selected: _spec.tvStatuses.contains(e.key),
                    onSelected: (on) => _setSpec(_with({
                      'tvStatuses': on ? [..._spec.tvStatuses, e.key] : [..._spec.tvStatuses.where((s) => s != e.key)],
                    })),
                  ),
              ],
            ),
          const _Heading('When'),
          ListTile(
            title: Text(type == SeerrMediaType.tv ? 'First aired' : 'Released'),
            trailing: AppDropdown<SeerrDateRange>(
              value: _spec.dateRange,
              items: [for (final d in SeerrDateRange.values) DropdownMenuItem(value: d, child: Text(d.label))],
              onChanged: (d) => d == null ? null : _setSpec(_with({'dateRange': d.name})),
            ),
          ),
          if (_spec.dateRange == SeerrDateRange.custom)
            Row(
              children: [
                Expanded(child: _DateTile(label: 'From', value: _spec.dateFrom, onChanged: (d) => _setSpec(_with({'dateFrom': d == null ? null : seerrDate(d)})))),
                Expanded(child: _DateTile(label: 'To', value: _spec.dateTo, onChanged: (d) => _setSpec(_with({'dateTo': d == null ? null : seerrDate(d)})))),
              ],
            ),
          const _Heading('How good, how long'),
          _RangeTile(
            label: 'TMDB score',
            min: 0,
            max: 10,
            divisions: 20,
            from: _spec.ratingMin,
            to: _spec.ratingMax,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (from, to) => _setSpec(_with({'ratingMin': from, 'ratingMax': to})),
          ),
          ListTile(
            title: const Text('At least this many votes'),
            trailing: AppDropdown<int?>(
              value: _spec.votesMin,
              items: [
                const DropdownMenuItem(value: null, child: Text('Any')),
                for (final v in const [10, 50, 100, 250, 500, 1000, 5000]) DropdownMenuItem(value: v, child: Text('$v')),
              ],
              onChanged: (v) => _setSpec(_with({'votesMin': v})),
            ),
          ),
          _RangeTile(
            label: 'Runtime (minutes)',
            min: 0,
            max: 240,
            divisions: 24,
            from: _spec.runtimeMin?.toDouble(),
            to: _spec.runtimeMax?.toDouble(),
            format: (v) => '${v.round()}',
            onChanged: (from, to) => _setSpec(_with({'runtimeMin': from?.round(), 'runtimeMax': to?.round()})),
          ),
          const _Heading('Where to watch'),
          ListTile(
            title: const Text('Region'),
            subtitle: Text(region),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final regions = await ref.read(_seerrRegionsProvider.future);
              if (!context.mounted) return;
              final picked = await pickMany(
                context,
                title: 'Region',
                options: regions,
                selected: [SeerrOption(region, region)],
                single: true,
              );
              if (picked?.firstOrNull case final r?) _setSpec(_with({'watchRegion': r.id, 'watchProviders': <Object>[]}));
            },
          ),
          ListTile(
            title: const Text('Streaming services'),
            subtitle: Text(names(_spec.watchProviders)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pick(
              'watchProviders',
              'Streaming services (any of)',
              () => ref.read(_seerrProvidersProvider((type, region)).future),
              _spec.watchProviders,
            ),
          ),
          const _Heading('Age rating'),
          ListTile(
            title: const Text('Country'),
            trailing: AppDropdown<String>(
              value: certs.containsKey(certCountry) ? certCountry : null,
              hint: Text(certCountry),
              items: [for (final c in certs.keys.toList()..sort()) DropdownMenuItem(value: c, child: Text(c))],
              onChanged: (c) => c == null ? null : _setSpec(_with({'certificationCountry': c, 'certifications': <String>[]})),
            ),
          ),
          if (certs[certCountry] case final list? when list.isNotEmpty)
            _Chips(
              label: 'Ratings (any of)',
              children: [
                for (final c in list)
                  FilterChip(
                    label: Text(c),
                    selected: _spec.certifications.contains(c),
                    onSelected: (on) => _setSpec(_with({
                      'certifications': on ? [..._spec.certifications, c] : [..._spec.certifications.where((x) => x != c)],
                    })),
                  ),
              ],
            ),
          const _Heading('Order'),
          ListTile(
            title: const Text('Sort by'),
            trailing: AppDropdown<SeerrSort>(
              value: _spec.sort,
              items: [
                for (final s in SeerrSort.values)
                  if (s != SeerrSort.revenue || type == SeerrMediaType.movie) DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: (s) => s == null ? null : _setSpec(_with({'sort': s.name})),
            ),
          ),
          SwitchListTile(
            title: const Text('Highest / newest first'),
            value: _spec.descending,
            onChanged: (v) => _setSpec(_with({'descending': v})),
          ),
        ],
        const Divider(),
        SwitchListTile(
          title: const Text('Hide titles already on the server'),
          value: _spec.hideAvailable,
          onChanged: (v) => _setSpec(_with({'hideAvailable': v})),
        ),
        _LimitTile(value: _row.limit, onChanged: (v) => setState(() => _row = _row.copyWith(limit: v))),
      ],
    );
  }

  /// Because you watched: which title (default: the latest favourite /
  /// finished / current one).
  Widget _seedTile() {
    final seeds = ref.watch(tasteSeedsProvider).value ?? const [];
    final chosen = _spec.seed;
    return ListTile(
      title: const Text('Because you watched'),
      subtitle: Text(chosen?.name ?? 'Automatic (your latest show)'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final options = [for (final s in seeds) SeerrOption(s.key, s.name)]..sort((a, b) => a.name.compareTo(b.name));
        final picked = await pickMany(
          context,
          title: 'Because you watched',
          options: options,
          selected: [?chosen],
          single: true,
        );
        if (picked != null) _setSpec(_with({'seed': picked.firstOrNull?.toJson()}));
      },
    );
  }

  /// Seerr can't search networks; take a TMDB network id and look it up.
  Future<void> _pickNetwork(SeerrApi api) async {
    final input = TextEditingController(text: _spec.company?.id ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Network'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("TMDB network id, e.g. 213 for Netflix: it's the number in the "
                "network's address on themoviedb.org. Empty for any network."),
            const SizedBox(height: 12),
            TextField(controller: input, keyboardType: TextInputType.number, autofocus: true),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, input.text.trim()), child: const Text('OK')),
        ],
      ),
    );
    input.dispose();
    if (result == null) return;
    if (result.isEmpty) return _setSpec(_with({'company': null}));
    final id = int.tryParse(result);
    if (id == null) return;
    try {
      _setSpec(_with({'company': (await api.network(id)).toJson()}));
    } on Object {
      if (mounted) {
        showToast('No network with id $id.');
      }
    }
  }
}

// --- small form pieces ---

class _Field extends StatelessWidget {
  const _Field({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: child);
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

class _Chips extends StatelessWidget {
  const _Chips({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: children),
          ],
        ),
      );
}

class _LimitTile extends StatelessWidget {
  const _LimitTile({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        title: const Text('How many to show'),
        trailing: AppDropdown<int>(
          value: value,
          items: [
            for (final n in {12, 15, 20, 24, 36, 50, value}.toList()..sort()) DropdownMenuItem(value: n, child: Text('$n')),
          ],
          onChanged: (n) => n == null ? null : onChanged(n),
        ),
      );
}

/// A min–max range where either end may be "any".
class _RangeTile extends StatelessWidget {
  const _RangeTile({
    required this.label,
    required this.min,
    required this.max,
    required this.divisions,
    required this.from,
    required this.to,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double min;
  final double max;
  final int divisions;
  final double? from;
  final double? to;
  final String Function(double) format;
  final void Function(double? from, double? to) onChanged;

  @override
  Widget build(BuildContext context) {
    final values = RangeValues(from ?? min, to ?? max);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ${from == null ? 'any' : format(from!)} – ${to == null ? 'any' : format(to!)}',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          RangeSlider(
            values: values,
            min: min,
            max: max,
            divisions: divisions,
            labels: RangeLabels(format(values.start), format(values.end)),
            // The ends of the track mean "no limit".
            onChanged: (v) => onChanged(v.start <= min ? null : v.start, v.end >= max ? null : v.end),
          ),
        ],
      ),
    );
  }
}

class _DateTile extends StatelessWidget {
  const _DateTile({required this.label, required this.value, required this.onChanged});

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(label),
        subtitle: Text(value == null ? 'Any' : seerrDate(value!)),
        trailing: value == null ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () => onChanged(null)),
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: value ?? DateTime.now(),
            firstDate: DateTime(1900),
            lastDate: DateTime(DateTime.now().year + 5),
          );
          if (d != null) onChanged(d);
        },
      );
}

/// Pick some of [options] (a filterable checklist); null when cancelled.
Future<List<SeerrOption>?> pickMany(
  BuildContext context, {
  required String title,
  required List<SeerrOption> options,
  required List<SeerrOption> selected,
  bool single = false,
}) =>
    showDialog<List<SeerrOption>>(
      context: context,
      builder: (_) => _PickDialog(
        title: title,
        load: (q) async => [for (final o in options) if (o.name.toLowerCase().contains(q.toLowerCase())) o],
        selected: selected,
        single: single,
        hint: 'Filter',
      ),
    );

/// Search Seerr ([search]) and pick results; null when cancelled.
Future<List<SeerrOption>?> searchMany(
  BuildContext context, {
  required String title,
  required Future<List<SeerrOption>> Function(String) search,
  required List<SeerrOption> selected,
  bool single = false,
}) =>
    showDialog<List<SeerrOption>>(
      context: context,
      builder: (_) => _PickDialog(
        title: title,
        load: (q) async => q.trim().length < 2 ? const [] : search(q.trim()),
        selected: selected,
        single: single,
        hint: 'Search',
      ),
    );

class _PickDialog extends StatefulWidget {
  const _PickDialog({
    required this.title,
    required this.load,
    required this.selected,
    required this.single,
    required this.hint,
  });

  final String title;
  final Future<List<SeerrOption>> Function(String query) load;
  final List<SeerrOption> selected;
  final bool single;
  final String hint;

  @override
  State<_PickDialog> createState() => _PickDialogState();
}

class _PickDialogState extends State<_PickDialog> {
  late final List<SeerrOption> _picked = [...widget.selected];
  List<SeerrOption> _results = const [];
  String _query = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String q) async {
    _query = q;
    setState(() => _loading = true);
    try {
      final r = await widget.load(q);
      if (mounted && q == _query) setState(() => _results = r);
    } on Object {
      if (mounted) setState(() => _results = const []);
    } finally {
      if (mounted && q == _query) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Picked items first, so they can be unticked even when not in results.
    final shown = [..._picked, ..._results.where((r) => !_picked.contains(r))];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(hintText: widget.hint, prefixIcon: const Icon(Icons.search)),
              onChanged: _load,
            ),
            if (_loading) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                children: [
                  for (final o in shown)
                    CheckboxListTile(
                      dense: true,
                      title: Text(o.name),
                      value: _picked.contains(o),
                      onChanged: (on) => setState(() {
                        if (widget.single) _picked.clear();
                        if (on ?? false) {
                          _picked.add(o);
                        } else {
                          _picked.remove(o);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, const <SeerrOption>[]), child: const Text('Clear')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _picked), child: const Text('Done')),
      ],
    );
  }
}
