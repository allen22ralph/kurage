import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/layout.dart';
import '../../core/jellyfin/items.dart';
import '../library/library_providers.dart';
import '../seerr/seerr_providers.dart';
import '../seerr/widgets/seerr_widgets.dart';
import '../library/navigation.dart';
import '../library/widgets/media_card.dart';
import '../library/widgets/media_row.dart';

final _searchProvider =
    FutureProvider.autoDispose.family<List<BaseItem>, String>(
  (ref, term) => ref.watch(libraryApiProvider).search(term),
);

/// Search the library; results grouped into shows, movies and episodes.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _term = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _term = text.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final layout = context.layout;
    final results = _term.length < 2 ? null : ref.watch(_searchProvider(_term));

    // One spinner for the whole page, not one per row.
    AsyncValue<List<BaseItem>> only(Set<ItemType> types) => switch (results) {
          AsyncData(:final value) =>
            AsyncData(value.where((i) => types.contains(i.type)).toList()),
          AsyncError(:final error, :final stackTrace) =>
            AsyncError(error, stackTrace),
          _ => const AsyncData([]),
        };

    final isEmpty = results is AsyncData<List<BaseItem>> && results.value.isEmpty;
    // Jellyfin ids look like 32 hex digits; Seerr's may carry dashes.
    String norm(String id) => id.replaceAll('-', '').toLowerCase();
    final shown = {for (final i in results?.value ?? const <BaseItem>[]) norm(i.id)};

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          onSubmitted: (text) => setState(() => _term = text.trim()),
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search movies, shows, episodes',
            border: InputBorder.none,
          ),
        ),
      ),
      body: ListView(
        children: [
          if (results != null && results.isLoading && !results.hasValue)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (isEmpty)
            Padding(
              padding: EdgeInsets.all(layout.gutter),
              child: Text('No results for "$_term".'),
            ),
          MediaRow(
            title: 'Shows',
            items: only({ItemType.series}),
            onItemPressed: (i) => openItem(context, i),
          ),
          MediaRow(
            title: 'Movies',
            items: only({ItemType.movie}),
            onItemPressed: (i) => openItem(context, i),
          ),
          MediaRow(
            title: 'Collections',
            items: only({ItemType.boxSet}),
            onItemPressed: (i) => openItem(context, i),
          ),
          MediaRow(
            title: 'Episodes',
            items: only({ItemType.episode}),
            shape: CardShape.landscape,
            onItemPressed: (i) => openItem(context, i),
          ),
          // Seerr's matches, minus those already listed above. Seerr also
          // knows English titles for shows named in romaji on the server.
          SeerrMediaRow(
            title: 'From Seerr',
            items: switch (ref.watch(seerrSearchProvider(_term))) {
              AsyncData(:final value) => AsyncData([
                  for (final m in value)
                    if (m.jellyfinId == null || !shown.contains(norm(m.jellyfinId!))) m,
                ]),
              final other => other,
            },
          ),
        ],
      ),
    );
  }
}
