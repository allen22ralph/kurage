import '../log/app_log.dart';
import 'items.dart';
import 'jellyfin_api.dart';
import 'library_api.dart';

/// Where a week's schedule came from.
enum WeekSource {
  /// The Jellyfin Enhanced plugin's calendar: what Sonarr and Radarr expect
  /// (the server talks to them; the app never does).
  arr('Sonarr / Radarr'),

  /// Jellyfin alone: episodes aired this week, and upcoming ones its
  /// metadata already lists.
  jellyfin('Jellyfin');

  const WeekSource(this.label);

  final String label;
}

/// Where This week should come from (Settings > Home).
enum WeekSourceChoice {
  automatic('Automatic', "Sonarr and Radarr through the server when they have something; otherwise Jellyfin's"),
  arr('Sonarr / Radarr', "Only the server's Sonarr and Radarr calendar, through the Jellyfin Enhanced plugin"),
  jellyfin('Jellyfin only', 'What aired this week and what Jellyfin knows is coming');

  const WeekSourceChoice(this.label, this.description);

  final String label;
  final String description;

  static WeekSourceChoice fromName(String? name) => values.where((c) => c.name == name).firstOrNull ?? automatic;
}

/// One episode or film on a day of the week.
class WeekEntry {
  const WeekEntry({
    required this.id,
    required this.title,
    required this.at,
    this.episodeTitle,
    this.season,
    this.episode,
    this.movie = false,
    this.release,
    this.inLibrary = false,
    this.item,
    this.imageUrl,
    this.overview,
  });

  final String id;

  /// The show's name, or the film's.
  final String title;
  final String? episodeTitle;
  final int? season;
  final int? episode;

  /// When it airs or is released, in local time.
  final DateTime at;
  final bool movie;

  /// A film's kind of release: "In cinemas", "Digital", "On disc".
  final String? release;

  /// The episode or film is in the library, ready to play.
  final bool inLibrary;

  /// In Jellyfin: the episode or film, else (not in yet) its show.
  final BaseItem? item;

  /// Artwork from Sonarr/Radarr (an internet address), for what Jellyfin
  /// has no picture of.
  final String? imageUrl;
  final String? overview;

  /// "S1:E5", as the app writes episodes elsewhere.
  String? get code => season == null || episode == null ? null : 'S$season:E$episode';

  WeekEntry withItem(BaseItem? found) => WeekEntry(
    id: id,
    title: title,
    at: at,
    episodeTitle: episodeTitle,
    season: season,
    episode: episode,
    movie: movie,
    release: release,
    inLibrary: inLibrary,
    item: found,
    imageUrl: imageUrl,
    overview: overview,
  );
}

/// A week (from [start], local midnight, for 7 days) of [entries], in order.
class WeekSchedule {
  const WeekSchedule({
    required this.start,
    required this.entries,
    required this.source,
    this.problems = const [],
    this.note,
    this.failed = false,
    this.unreachable = false,
  });

  final DateTime start;
  final List<WeekEntry> entries;
  final WeekSource source;

  /// Sonarr/Radarr instances the server couldn't ask, as it reported them.
  final List<String> problems;

  /// Why Sonarr and Radarr aren't what this shows ("the server doesn't have
  /// the Jellyfin Enhanced calendar").
  final String? note;

  /// Sonarr/Radarr were asked for alone and couldn't answer: this isn't an
  /// empty week, and the row says so rather than disappearing.
  final bool failed;

  /// The server has the calendar but couldn't get an answer through it: worth
  /// trying again. (Without the plugin at all, there's nothing to retry.)
  final bool unreachable;

  /// All or part of Sonarr and Radarr should be here and isn't.
  bool get troubled => unreachable || problems.isNotEmpty;

  /// A line on the row itself, when it isn't showing all it should.
  String? get rowNote => switch (source) {
    _ when failed => null,
    WeekSource.jellyfin when unreachable => 'Sonarr and Radarr unavailable, showing Jellyfin',
    WeekSource.arr when problems.isNotEmpty => "Some of Sonarr and Radarr couldn't be reached, so this may be incomplete",
    _ => null,
  };

  /// The entries on day [i] (0: [start]'s day).
  List<WeekEntry> day(int i) {
    final from = DateTime(start.year, start.month, start.day + i);
    final to = DateTime(start.year, start.month, start.day + i + 1);
    return [
      for (final e in entries)
        if (!e.at.isBefore(from) && e.at.isBefore(to)) e,
    ];
  }
}

/// The local Monday, at midnight, of [now]'s week.
DateTime weekStart(DateTime now) => DateTime(now.year, now.month, now.day - (now.weekday - DateTime.monday));

/// This week's episodes and films: the Jellyfin Enhanced plugin's calendar
/// (Sonarr and Radarr, through the server) when the server has it, else
/// Jellyfin's own.
class WeekApi {
  WeekApi(this._api, {required this.userId});

  final JellyfinApi _api;
  final String userId;

  Future<WeekSchedule> week(DateTime start, {WeekSourceChoice choice = WeekSourceChoice.automatic}) async {
    final end = DateTime(start.year, start.month, start.day + 7);
    if (choice == WeekSourceChoice.jellyfin) return _fromJellyfin(start, end);

    final String note;
    var failed = true;
    var problems = const <String>[];
    var unreachable = false;
    try {
      final arr = await _fromArr(start, end);
      if (arr != null && arr.entries.isNotEmpty) return arr;
      problems = arr?.problems ?? const [];
      if (arr == null) {
        note = "the server doesn't have the Jellyfin Enhanced calendar";
      } else if (problems.isNotEmpty) {
        unreachable = true;
        note = "the server couldn't reach Sonarr or Radarr";
      } else {
        // (Asked, and answered: an empty week is no failure.)
        failed = false;
        note = 'Sonarr and Radarr have nothing this week';
      }
    } on Object catch (e) {
      AppLog.warning(LogArea.network, "This week: couldn't read the Sonarr/Radarr calendar", error: e);
      return _instead(
        choice,
        start,
        end,
        note: "the server couldn't read its Sonarr/Radarr calendar",
        failed: true,
        unreachable: true,
      );
    }
    return _instead(choice, start, end, note: note, problems: problems, failed: failed, unreachable: unreachable);
  }

  /// Sonarr and Radarr have nothing to show: Jellyfin's, unless they were
  /// asked for alone.
  Future<WeekSchedule> _instead(
    WeekSourceChoice choice,
    DateTime start,
    DateTime end, {
    required String note,
    required bool failed,
    required bool unreachable,
    List<String> problems = const [],
  }) async {
    final alone = choice == WeekSourceChoice.arr;
    AppLog.info(LogArea.network, 'This week: $note${alone ? '' : '; using Jellyfin'}');
    if (!alone) return _fromJellyfin(start, end, note: note, problems: problems, unreachable: unreachable);
    return WeekSchedule(
      start: start,
      entries: const [],
      source: WeekSource.arr,
      problems: problems,
      note: note,
      failed: failed,
      unreachable: unreachable,
    );
  }

  /// Null when the server has no such calendar (no plugin, or an older one).
  Future<WeekSchedule?> _fromArr(DateTime start, DateTime end) async {
    final Map<String, dynamic> data;
    try {
      data = await _api.getJson(
        '/JellyfinEnhanced/arr/calendar',
        query: {'start': start.toUtc().toIso8601String(), 'end': end.toUtc().toIso8601String()},
      );
    } on JellyfinException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
    final problems = [
      for (final p in (data['errors'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>())
        '${p['source'] ?? 'Arr'} "${p['instanceName'] ?? '?'}": ${p['reason'] ?? 'failed'}',
    ];
    for (final p in problems) {
      AppLog.warning(LogArea.network, 'This week: $p');
    }
    // What Sonarr and Radarr aren't tracking is left out (as on the plugin's
    // own calendar), unless it's already in the library.
    final events = [
      for (final e in (data['events'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>())
        if (e['monitored'] != false || e['hasFile'] == true) e,
    ];
    var entries = [for (final e in events) ?_arrEntry(e)]..sort((a, b) => a.at.compareTo(b.at));
    entries = await _withItems(entries, events);
    return WeekSchedule(start: start, entries: entries, source: WeekSource.arr, problems: problems);
  }

  static WeekEntry? _arrEntry(Map<String, dynamic> e) {
    final at = DateTime.tryParse(e['releaseDate'] as String? ?? '')?.toLocal();
    if (at == null) return null;
    final movie = e['type'] == 'Movie' || e['source'] == 'Radarr';
    final image = [e['backdropUrl'], e['posterUrl']].whereType<String>().where((u) => u.startsWith('http')).firstOrNull;
    return WeekEntry(
      id: '${e['source']}:${e['id']}',
      title: e['title'] as String? ?? '?',
      at: at,
      episodeTitle: movie ? null : e['episodeTitle'] as String?,
      season: movie ? null : (e['seasonNumber'] as num?)?.toInt(),
      episode: movie ? null : (e['episodeNumber'] as num?)?.toInt(),
      movie: movie,
      release: switch (e['releaseType']) {
        'CinemaRelease' => 'In cinemas',
        'DigitalRelease' => 'Digital',
        'PhysicalRelease' => 'On disc',
        _ => null,
      },
      inLibrary: e['hasFile'] == true,
      imageUrl: image,
      overview: e['overview'] as String?,
    );
  }

  /// Each entry's Jellyfin item, as the plugin matched it (the episode,
  /// else the show or film), fetched in one go for its pictures and pages.
  Future<List<WeekEntry>> _withItems(List<WeekEntry> entries, List<Map<String, dynamic>> events) async {
    String? id(Object? v) => v is String && v.isNotEmpty && !v.startsWith('00000000') ? v.replaceAll('-', '') : null;
    final wanted = <String, String>{}; // entry → item
    for (final e in events) {
      final match = id(e['itemEpisodeId']) ?? id(e['itemId']);
      if (match != null) wanted['${e['source']}:${e['id']}'] = match;
    }
    if (wanted.isEmpty) return entries;
    final Map<String, BaseItem> items;
    try {
      final data = await _api.getJson(
        '/Items',
        query: {
          'userId': userId,
          'ids': wanted.values.toSet().join(','),
          'fields': listFields,
          'enableImageTypes': 'Primary,Backdrop,Thumb',
          'imageTypeLimit': 1,
          'enableUserData': true,
        },
      );
      items = {for (final i in ItemPage.fromJson(data).items) i.id.replaceAll('-', ''): i};
    } on Object catch (e) {
      AppLog.warning(LogArea.network, "This week: couldn't fetch the library's items for the calendar", error: e);
      return entries;
    }
    return [for (final e in entries) e.withItem(items[wanted[e.id]])];
  }

  /// Jellyfin alone: this week's episodes in the library (by air date), and
  /// the upcoming ones its metadata lists.
  Future<WeekSchedule> _fromJellyfin(
    DateTime start,
    DateTime end, {
    String? note,
    List<String> problems = const [],
    bool unreachable = false,
  }) async {
    final common = {
      'userId': userId,
      'fields': '$listFields,Overview',
      'enableImageTypes': 'Primary,Backdrop,Thumb',
      'imageTypeLimit': 1,
      'enableUserData': true,
    };
    final results = await Future.wait([
      _api.getJson(
        '/Items',
        query: {
          ...common,
          'includeItemTypes': 'Episode,Movie',
          'recursive': true,
          'minPremiereDate': start.toUtc().toIso8601String(),
          'maxPremiereDate': end.toUtc().toIso8601String(),
          'sortBy': 'PremiereDate',
          'limit': 200,
        },
      ),
      _api.getJson('/Shows/Upcoming', query: {...common, 'limit': 100}).catchError((Object e) {
        AppLog.warning(LogArea.network, "This week: couldn't read Jellyfin's upcoming episodes", error: e);
        return <String, dynamic>{};
      }),
    ]);
    final seen = <String>{};
    final entries = <WeekEntry>[
      for (final i in [...ItemPage.fromJson(results[0]).items, ...ItemPage.fromJson(results[1]).items])
        if (i.premiereDate case final at? when seen.add(i.id))
          // (Jellyfin's air dates are midnight UTC: the day, not the time.)
          if (_dayOf(at) case final day when !day.isBefore(start) && day.isBefore(end))
            WeekEntry(
              id: i.id,
              title: i.type == ItemType.episode ? i.seriesName ?? i.name : i.name,
              at: day,
              episodeTitle: i.type == ItemType.episode ? i.name : null,
              season: i.parentIndexNumber,
              episode: i.indexNumber,
              movie: i.type == ItemType.movie,
              inLibrary: !i.isVirtual,
              item: i,
              overview: i.overview,
            ),
    ]..sort((a, b) => a.at.compareTo(b.at));
    return WeekSchedule(
      start: start,
      entries: entries,
      source: WeekSource.jellyfin,
      note: note,
      problems: problems,
      unreachable: unreachable,
    );
  }

  /// A date-only air date (midnight UTC) as that local day.
  static DateTime _dayOf(DateTime at) {
    final u = at.toUtc();
    return DateTime(u.year, u.month, u.day);
  }
}
