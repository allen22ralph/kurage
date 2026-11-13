import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';

/// Audio/subtitle language picked for one show; used before the general
/// defaults for its other episodes.
class SeriesTrackChoice {
  const SeriesTrackChoice({this.audio, this.subtitle, this.subtitlesOff = false});

  factory SeriesTrackChoice.fromJson(Map<String, dynamic> j) => SeriesTrackChoice(
        audio: j['audio'] as String?,
        subtitle: j['subtitle'] as String?,
        subtitlesOff: j['subtitlesOff'] as bool? ?? false,
      );

  /// mpv language codes as the file reports them (e.g. "jpn", "eng").
  final String? audio;
  final String? subtitle;
  final bool subtitlesOff;

  /// [base] with this show's choice in front (duplicates dropped).
  static String prefer(String? choice, String base) {
    if (choice == null || choice.isEmpty) return base;
    final rest = base.split(',').where((l) => l.isNotEmpty && l != choice);
    return [choice, ...rest].join(',');
  }

  Map<String, dynamic> toJson() => {'audio': audio, 'subtitle': subtitle, 'subtitlesOff': subtitlesOff};
}

final seriesTracksProvider =
    AsyncNotifierProvider<SeriesTracksController, Map<String, SeriesTrackChoice>>(SeriesTracksController.new);

/// Kept on this device and on the Jellyfin account (its display
/// preferences for this app), so every device signed in as the user picks
/// the same tracks for a show; the account's win when both have one.
class SeriesTracksController extends AsyncNotifier<Map<String, SeriesTrackChoice>> {
  static const _key = 'playback.seriesTracks';

  /// The account's display preferences that hold the choices.
  static const preferencesId = 'jellyfin-client-series-tracks';
  static const client = 'jellyfin-client';

  @override
  Future<Map<String, SeriesTrackChoice>> build() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    final local = raw == null
        ? <String, SeriesTrackChoice>{}
        : {
            for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries)
              e.key: SeriesTrackChoice.fromJson(e.value as Map<String, dynamic>),
          };
    return {...local, ...await _fromAccount()};
  }

  Map<String, String> get _query => {'userId': ref.read(currentSessionProvider).userId, 'client': client};

  /// The account's choices; none when offline or signed out.
  Future<Map<String, SeriesTrackChoice>> _fromAccount() async {
    try {
      final prefs = await ref.read(signedInApiProvider).getJson('/DisplayPreferences/$preferencesId', query: _query);
      // One entry at a time: a value that isn't a choice (the server's own,
      // or another app's) is skipped rather than losing all of them.
      return {
        for (final e in ((prefs['CustomPrefs'] as Map?) ?? const {}).entries)
          '${e.key}': ?_choice(e.value),
      };
    } on Object catch (e) {
      debugPrint('Track choices from the account: $e');
      return {};
    }
  }

  static SeriesTrackChoice? _choice(Object? value) {
    if (value is! String || !value.startsWith('{')) return null;
    try {
      return SeriesTrackChoice.fromJson(jsonDecode(value) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<void> _toAccount(Map<String, SeriesTrackChoice> choices) async {
    try {
      await ref.read(signedInApiProvider).postJson('/DisplayPreferences/$preferencesId', query: _query, body: {
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
        'CustomPrefs': {for (final e in choices.entries) e.key: jsonEncode(e.value.toJson())},
      });
    } on Object catch (e) {
      // Kept on the device anyway; the next change tries again.
      debugPrint('Track choices to the account: $e');
    }
  }

  Future<void> setAudio(String seriesId, String? language) => _update(
        seriesId,
        (c) => SeriesTrackChoice(audio: language, subtitle: c.subtitle, subtitlesOff: c.subtitlesOff),
      );

  /// A null [language] with [off] means "subtitles off".
  Future<void> setSubtitle(String seriesId, String? language, {bool off = false}) => _update(
        seriesId,
        (c) => SeriesTrackChoice(audio: c.audio, subtitle: off ? null : language, subtitlesOff: off),
      );

  Future<void> _update(String seriesId, SeriesTrackChoice Function(SeriesTrackChoice) change) async {
    final current = await future; // wait for the stored map before changing it
    final next = {...current, seriesId: change(current[seriesId] ?? const SeriesTrackChoice())};
    state = AsyncData(next);
    await (await SharedPreferences.getInstance())
        .setString(_key, jsonEncode({for (final e in next.entries) e.key: e.value.toJson()}));
    await _toAccount(next);
  }
}
