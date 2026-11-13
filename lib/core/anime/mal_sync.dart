import 'dart:convert';

import 'mal_api.dart';

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The MAL list change for having watched [episode] of [anime], or null
/// when nothing should change. Rules:
/// - never lower the watched count (rewatching earlier episodes is a no-op);
/// - leave a completed entry alone (unless it's being rewatched);
/// - reaching the last episode completes it and sets the finish date;
/// - otherwise it's "watching", with a start date if it had none.
Map<String, String>? planMalUpdate(MalAnime anime, int episode, DateTime today) {
  final current = anime.listStatus;
  if (episode < 1) return null;
  if (current.status == MalStatus.completed && !current.rewatching) return null;
  if (episode <= current.watchedEpisodes) return null;

  final total = anime.episodes;
  final done = total != null && episode >= total;
  return {
    'num_watched_episodes': '${done ? total : episode}',
    'status': (done ? MalStatus.completed : MalStatus.watching).api,
    if (current.startDate == null) 'start_date': _date(today),
    if (done && current.finishDate == null) 'finish_date': _date(today),
  };
}

/// The MAL list change for marking [episode] of [anime] unwatched: the
/// watched count drops to the episode before it, and a completed entry goes
/// back to "watching". Null when MAL never counted that episode.
Map<String, String>? planMalUnwatch(MalAnime anime, int episode) {
  final current = anime.listStatus;
  if (episode < 1 || episode > current.watchedEpisodes) return null;
  return {
    'num_watched_episodes': '${episode - 1}',
    'status': (current.status == MalStatus.completed && !current.rewatching
            ? MalStatus.watching
            : current.status ?? MalStatus.watching)
        .api,
  };
}

/// Which MAL entry, and which episode of it, [episodeInSeason] is when a
/// season spans several MAL entries ([entries], airing order — a split-
/// cour season). [episodeCount] gives an entry's length (null if unknown,
/// e.g. still airing: everything from there on belongs to that entry).
///
/// With [sequelOf], an episode past the end of the last entry goes on into
/// its sequel (e.g. episode 14 of a show matched only to its 13-episode
/// first cour is episode 1 of the second), up to [maxSequels] steps.
Future<(int malId, int episode)> resolveMalEpisode(
  List<int> entries,
  int episodeInSeason,
  Future<int?> Function(int malId) episodeCount, {
  Future<int?> Function(int malId)? sequelOf,
  int maxSequels = 3,
}) async {
  var episode = episodeInSeason;
  for (var i = 0; i < entries.length - 1; i++) {
    final count = await episodeCount(entries[i]);
    if (count == null || episode <= count) return (entries[i], episode);
    episode -= count;
  }
  var entry = entries.last;
  for (var step = 0; sequelOf != null && step < maxSequels; step++) {
    final count = await episodeCount(entry);
    if (count == null || episode <= count) break;
    final next = await sequelOf(entry);
    if (next == null) break;
    episode -= count;
    entry = next;
  }
  return (entry, episode);
}

/// A pending MAL update, kept until MAL confirms it (works offline).
class MalSyncJob {
  const MalSyncJob({required this.malId, required this.episode, required this.title, this.unwatched = false});

  factory MalSyncJob.fromJson(Map<String, dynamic> j) => MalSyncJob(
        malId: j['malId'] as int,
        episode: j['episode'] as int,
        title: j['title'] as String,
        unwatched: j['unwatched'] as bool? ?? false,
      );

  final int malId;
  final int episode;

  /// [episode] was marked unwatched (MAL goes back to the one before).
  final bool unwatched;

  /// For the sync log ("Frieren S1:E5").
  final String title;

  Map<String, dynamic> toJson() =>
      {'malId': malId, 'episode': episode, 'title': title, if (unwatched) 'unwatched': true};
}

/// Adds [job] to [queue], keeping one job per anime: the latest change,
/// except that watching an earlier episode doesn't undo watching a later
/// one, and unwatching keeps the furthest-back episode.
List<MalSyncJob> enqueue(List<MalSyncJob> queue, MalSyncJob job) {
  final existing = queue.where((j) => j.malId == job.malId).firstOrNull;
  if (existing != null && existing.unwatched == job.unwatched) {
    final keep = job.unwatched ? existing.episode <= job.episode : existing.episode >= job.episode;
    if (keep) return queue;
  }
  return [...queue.where((j) => j.malId != job.malId), job];
}

/// One line of the sync log.
class MalSyncLogEntry {
  const MalSyncLogEntry({required this.at, required this.title, required this.message, this.ok = true});

  factory MalSyncLogEntry.fromJson(Map<String, dynamic> j) => MalSyncLogEntry(
        at: DateTime.parse(j['at'] as String),
        title: j['title'] as String,
        message: j['message'] as String,
        ok: j['ok'] as bool? ?? true,
      );

  final DateTime at;
  final String title;
  final String message;
  final bool ok;

  Map<String, dynamic> toJson() =>
      {'at': at.toIso8601String(), 'title': title, 'message': message, 'ok': ok};

  static String encodeAll(List<MalSyncLogEntry> e) => jsonEncode([for (final x in e) x.toJson()]);
  static List<MalSyncLogEntry> decodeAll(String? s) => s == null
      ? []
      : [for (final x in jsonDecode(s) as List) MalSyncLogEntry.fromJson(x as Map<String, dynamic>)];
}
