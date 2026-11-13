import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which title to show for anime matched on MyAnimeList.
enum TitleLanguage {
  server('Server names'),
  romaji('Romaji'),
  english('English'),
  japanese('Japanese');

  const TitleLanguage(this.label);

  final String label;
}

/// MyAnimeList preferences, stored on this device.
class AnimeSettings {
  const AnimeSettings({
    this.showScores = true,
    this.titleLanguage = TitleLanguage.server,
    this.syncEnabled = true,
    this.useAniSkip = true,
    this.episodeScoresOutOf10 = true,
    this.preferAniSkip = false,
  });

  /// MAL scores on posters and detail pages.
  final bool showScores;
  final TitleLanguage titleLanguage;

  /// Update the linked MAL list as episodes are watched.
  final bool syncEnabled;

  /// Skip openings/endings with AniSkip when the server has no segments.
  final bool useAniSkip;

  /// Use AniSkip's timings even when the server has its own (e.g. when
  /// Intro Skipper gets a show wrong); the server's fill in where AniSkip
  /// has none.
  final bool preferAniSkip;

  /// MAL rates episodes 1–5; doubled to match the 10-point show scores.
  final bool episodeScoresOutOf10;

  /// An episode's MAL rating as shown (out of 10 or 5).
  double episodeScore(double outOf5) => episodeScoresOutOf10 ? outOf5 * 2 : outOf5;

  AnimeSettings copyWith({
    bool? showScores,
    TitleLanguage? titleLanguage,
    bool? syncEnabled,
    bool? useAniSkip,
    bool? episodeScoresOutOf10,
    bool? preferAniSkip,
  }) =>
      AnimeSettings(
        showScores: showScores ?? this.showScores,
        titleLanguage: titleLanguage ?? this.titleLanguage,
        syncEnabled: syncEnabled ?? this.syncEnabled,
        useAniSkip: useAniSkip ?? this.useAniSkip,
        episodeScoresOutOf10: episodeScoresOutOf10 ?? this.episodeScoresOutOf10,
        preferAniSkip: preferAniSkip ?? this.preferAniSkip,
      );
}

final animeSettingsProvider =
    AsyncNotifierProvider<AnimeSettingsController, AnimeSettings>(AnimeSettingsController.new);

class AnimeSettingsController extends AsyncNotifier<AnimeSettings> {
  static const _prefix = 'anime.';

  @override
  Future<AnimeSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    const d = AnimeSettings();
    return AnimeSettings(
      showScores: prefs.getBool('${_prefix}showScores') ?? d.showScores,
      titleLanguage: TitleLanguage.values.asNameMap()[prefs.getString('${_prefix}titleLanguage')] ??
          d.titleLanguage,
      syncEnabled: prefs.getBool('${_prefix}syncEnabled') ?? d.syncEnabled,
      useAniSkip: prefs.getBool('${_prefix}useAniSkip') ?? d.useAniSkip,
      episodeScoresOutOf10: prefs.getBool('${_prefix}episodeScoresOutOf10') ?? d.episodeScoresOutOf10,
      preferAniSkip: prefs.getBool('${_prefix}preferAniSkip') ?? d.preferAniSkip,
    );
  }

  Future<void> save(AnimeSettings settings) async {
    state = AsyncData(settings);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}showScores', settings.showScores);
    await prefs.setString('${_prefix}titleLanguage', settings.titleLanguage.name);
    await prefs.setBool('${_prefix}syncEnabled', settings.syncEnabled);
    await prefs.setBool('${_prefix}useAniSkip', settings.useAniSkip);
    await prefs.setBool('${_prefix}episodeScoresOutOf10', settings.episodeScoresOutOf10);
    await prefs.setBool('${_prefix}preferAniSkip', settings.preferAniSkip);
  }
}
