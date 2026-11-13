import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/seerr/seerr_api.dart';
import '../../core/seerr/seerr_discover.dart';
import '../../core/seerr/suggestion_filters.dart';
import '../seerr/seerr_providers.dart';
import 'home_editor.dart' show pickMany, searchMany;
import 'suggestion_filters_store.dart';
import '../../app/app_dropdown.dart';

/// A dropdown choosing which filter set applies ("Default (Anime)", a
/// named set, or none).
class FilterSetDropdown extends ConsumerWidget {
  const FilterSetDropdown({super.key, required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ref.watch(suggestionFiltersProvider).value ?? const SuggestionFilters();
    final known = {filterSetDefault, filterSetNone, for (final s in f.sets) s.id};
    return AppDropdown<String>(
      value: known.contains(value) ? value : filterSetDefault,
      items: [
        DropdownMenuItem(value: filterSetDefault, child: Text('Default (${f.defaultSet?.name ?? 'none'})')),
        for (final s in f.sets) DropdownMenuItem(value: s.id, child: Text(s.name)),
        const DropdownMenuItem(value: filterSetNone, child: Text('No filters')),
      ],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }
}

/// "Animation · Japanese · not Reality · TV only".
String describeFilterSet(SuggestionFilterSet s) {
  final parts = [
    ...s.requireGenres.map((g) => g.name),
    if (s.languages.isNotEmpty) s.languages.map((l) => l.name).join(' or '),
    if (s.requireKeywords.isNotEmpty) 'keyword ${s.requireKeywords.map((k) => k.name).join(' or ')}',
    for (final g in [...s.excludeGenres, ...s.excludeKeywords]) 'not ${g.name}',
    if (s.type != SuggestionType.both) s.type.label,
  ];
  return parts.isEmpty ? 'No conditions' : parts.join(' · ');
}

/// Settings > Home rows > Suggestion filters: the named sets, which one is
/// the default, add / edit / remove.
class SuggestionFiltersScreen extends ConsumerWidget {
  const SuggestionFiltersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(suggestionFiltersProvider).value ?? const SuggestionFilters();
    final controller = ref.read(suggestionFiltersProvider.notifier);
    Future<void> edit(SuggestionFilterSet set, {bool isNew = false}) async {
      final edited = await Navigator.of(context).push<SuggestionFilterSet>(
        MaterialPageRoute(builder: (_) => _FilterSetEditor(initial: set)),
      );
      if (edited == null) return;
      final f = await ref.read(suggestionFiltersProvider.future);
      await controller.save(f.copyWith(
        sets: isNew ? [...f.sets, edited] : [for (final s in f.sets) s.id == edited.id ? edited : s],
      ));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Suggestion filters')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New set'),
        onPressed: () => edit(SuggestionFilterSet(id: SuggestionFiltersController.newId(), name: 'My filters'), isNew: true),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          const ListTile(
            subtitle: Text(
              'Conditions every suggestion meets: recommendation rows and More for you. '
              'Each of those can use the default set (the marked one), another set, or none.',
            ),
          ),
          RadioGroup<String>(
            groupValue: filters.defaultId,
            onChanged: (id) => id == null ? null : controller.save(filters.copyWith(defaultId: id)),
            child: Column(
              children: [
                for (final s in filters.sets)
                  ListTile(
                    leading: Radio<String>(value: s.id),
                    title: Text(s.name),
                    subtitle: Text(describeFilterSet(s)),
                    onTap: () => edit(s),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => edit(s)),
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: filters.sets.length == 1
                              ? null
                              : () => controller.save(filters.copyWith(
                                    sets: [for (final x in filters.sets) if (x.id != s.id) x],
                                    defaultId: filters.defaultId == s.id
                                        ? filters.sets.firstWhere((x) => x.id != s.id).id
                                        : filters.defaultId,
                                  )),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final _genresProvider = FutureProvider.autoDispose<List<SeerrOption>>((ref) async {
  final api = ref.watch(seerrApiProvider);
  if (api == null) return const [];
  // TV and movie genres together (TMDB shares the ids of the common ones).
  final (tv, movie) = await (api.genres(SeerrMediaType.tv), api.genres(SeerrMediaType.movie)).wait;
  return {...tv, ...movie}.toList()..sort((a, b) => a.name.compareTo(b.name));
});

final _languagesProvider = FutureProvider.autoDispose<List<SeerrOption>>(
  (ref) async => (await ref.watch(seerrApiProvider)?.languages()) ?? const [],
);

class _FilterSetEditor extends ConsumerStatefulWidget {
  const _FilterSetEditor({required this.initial});

  final SuggestionFilterSet initial;

  @override
  ConsumerState<_FilterSetEditor> createState() => _FilterSetEditorState();
}

class _FilterSetEditorState extends ConsumerState<_FilterSetEditor> {
  late SuggestionFilterSet _set = widget.initial;
  late final _name = TextEditingController(text: widget.initial.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick(
    String title,
    FutureProvider<List<SeerrOption>> options,
    List<SeerrOption> selected,
    SuggestionFilterSet Function(List<SeerrOption>) apply,
  ) async {
    final loaded = await ref.read(options.future);
    if (!mounted) return;
    final picked = await pickMany(context, title: title, options: loaded, selected: selected);
    if (picked != null) setState(() => _set = apply(picked));
  }

  Future<void> _search(String title, List<SeerrOption> selected, SuggestionFilterSet Function(List<SeerrOption>) apply) async {
    final api = ref.read(seerrApiProvider);
    if (api == null) return;
    final picked = await searchMany(context, title: title, search: api.searchKeywords, selected: selected);
    if (picked != null) setState(() => _set = apply(picked));
  }

  @override
  Widget build(BuildContext context) {
    final seerr = ref.watch(seerrApiProvider) != null;
    final theme = Theme.of(context);
    String names(List<SeerrOption> l, [String none = 'Any']) => l.isEmpty ? none : l.map((o) => o.name).join(', ');
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Filter set'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              _set.copyWith(name: _name.text.trim().isEmpty ? 'My filters' : _name.text.trim()),
            ),
            child: const Text('Save'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
            ),
          ),
          if (!seerr) const ListTile(title: Text('Sign in to Seerr to choose genres, languages and keywords.')),
          heading('Must have'),
          ListTile(
            title: const Text('Genres (all of)'),
            subtitle: Text(names(_set.requireGenres)),
            trailing: const Icon(Icons.chevron_right),
            enabled: seerr,
            onTap: () => _pick('Must have genres', _genresProvider, _set.requireGenres, (p) => _set.copyWith(requireGenres: p)),
          ),
          ListTile(
            title: const Text('Original language (any of)'),
            subtitle: Text(names(_set.languages)),
            trailing: const Icon(Icons.chevron_right),
            enabled: seerr,
            onTap: () => _pick('Original language', _languagesProvider, _set.languages, (p) => _set.copyWith(languages: p)),
          ),
          ListTile(
            title: const Text('Keywords (any of)'),
            subtitle: Text(names(_set.requireKeywords)),
            trailing: const Icon(Icons.chevron_right),
            enabled: seerr,
            onTap: () => _search('Must have keywords', _set.requireKeywords, (p) => _set.copyWith(requireKeywords: p)),
          ),
          ListTile(
            title: const Text('Type'),
            trailing: AppDropdown<SuggestionType>(
              value: _set.type,
              items: [for (final t in SuggestionType.values) DropdownMenuItem(value: t, child: Text(t.label))],
              onChanged: (t) => t == null ? null : setState(() => _set = _set.copyWith(type: t)),
            ),
          ),
          heading('Never show'),
          ListTile(
            title: const Text('Genres'),
            subtitle: Text(names(_set.excludeGenres, 'None')),
            trailing: const Icon(Icons.chevron_right),
            enabled: seerr,
            onTap: () => _pick('Never show genres', _genresProvider, _set.excludeGenres, (p) => _set.copyWith(excludeGenres: p)),
          ),
          ListTile(
            title: const Text('Keywords'),
            subtitle: Text(names(_set.excludeKeywords, 'None')),
            trailing: const Icon(Icons.chevron_right),
            enabled: seerr,
            onTap: () => _search('Never show keywords', _set.excludeKeywords, (p) => _set.copyWith(excludeKeywords: p)),
          ),
          const ListTile(
            dense: true,
            subtitle: Text(
              "Keywords apply to discover-based suggestions (Picked for you, More …, Hidden gems); "
              "Seerr's recommendation lists only give each title's genres and language.",
            ),
          ),
        ],
      ),
    );
  }
}
