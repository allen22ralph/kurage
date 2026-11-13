import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../core/seerr/suggestion_filters.dart';

/// The user's suggestion filter sets and which one is the default.
class SuggestionFilters {
  const SuggestionFilters({this.sets = defaultSuggestionFilterSets, this.defaultId = 'anime'});

  factory SuggestionFilters.fromJson(Map<String, dynamic> j) => SuggestionFilters(
        sets: [for (final s in (j['sets'] as List?) ?? const []) SuggestionFilterSet.fromJson((s as Map).cast<String, dynamic>())],
        defaultId: j['defaultId'] as String? ?? 'anime',
      );

  final List<SuggestionFilterSet> sets;
  final String defaultId;

  SuggestionFilterSet? get defaultSet => sets.where((s) => s.id == defaultId).firstOrNull ?? sets.firstOrNull;

  /// The set a row uses: [filterSetDefault] (or an id that's gone) = the
  /// default set, [filterSetNone] = no filters.
  SuggestionFilterSet? resolve(String id) => switch (id) {
        filterSetNone => null,
        filterSetDefault => defaultSet,
        _ => sets.where((s) => s.id == id).firstOrNull ?? defaultSet,
      };

  SuggestionFilters copyWith({List<SuggestionFilterSet>? sets, String? defaultId}) =>
      SuggestionFilters(sets: sets ?? this.sets, defaultId: defaultId ?? this.defaultId);

  Map<String, dynamic> toJson() => {'sets': [for (final s in sets) s.toJson()], 'defaultId': defaultId};
}

final suggestionFiltersProvider =
    AsyncNotifierProvider<SuggestionFiltersController, SuggestionFilters>(SuggestionFiltersController.new);

class SuggestionFiltersController extends AsyncNotifier<SuggestionFilters> {
  String get _key {
    final s = ref.read(currentSessionProvider);
    return 'home.filters.${s.serverId}.${s.userId}';
  }

  @override
  Future<SuggestionFilters> build() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return const SuggestionFilters();
    try {
      final f = SuggestionFilters.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
      return f.sets.isEmpty ? const SuggestionFilters() : f;
    } on Object {
      return const SuggestionFilters();
    }
  }

  Future<void> save(SuggestionFilters filters) async {
    await future;
    state = AsyncData(filters);
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(filters.toJson()));
  }

  static String newId() => 'set-${DateTime.now().microsecondsSinceEpoch}';
}

/// The filter set for [id] (see [SuggestionFilters.resolve]).
final suggestionFilterSetProvider = FutureProvider.family<SuggestionFilterSet?, String>(
  (ref, id) async => (await ref.watch(suggestionFiltersProvider.future)).resolve(id),
  retry: (_, _) => null,
);
