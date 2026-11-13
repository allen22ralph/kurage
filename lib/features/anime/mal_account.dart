import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/anime/mal_api.dart';
import '../../core/anime/mal_auth.dart';
import '../../core/anime/mal_sync.dart';
import '../../core/jellyfin/items.dart';
import '../library/library_providers.dart';
import 'anime_providers.dart';
import 'anime_settings.dart';
import '../../core/log/app_log.dart';
import '../../core/net/reach_error.dart';
import '../../core/storage/session_store.dart';

/// The MAL client ID: one entered in Settings, else the one built in
/// (`--dart-define=MAL_CLIENT_ID`, from CI's secret). It names the app to
/// MAL, not a person: everyone shares it and links their own account.
final malClientIdProvider = AsyncNotifierProvider<MalClientIdController, String>(MalClientIdController.new);

class MalClientIdController extends AsyncNotifier<String> {
  static const _key = 'anime.malClientId';

  /// The one entered in Settings ('' when using the built-in one).
  static Future<String> entered() async => (await SharedPreferences.getInstance()).getString(_key) ?? '';

  @override
  Future<String> build() async {
    final own = await entered();
    return own.isNotEmpty ? own : builtInMalClientId;
  }

  /// Empty goes back to the built-in one.
  Future<void> save(String id) async {
    final own = id.trim();
    state = AsyncData(own.isNotEmpty ? own : builtInMalClientId);
    await (await SharedPreferences.getInstance()).setString(_key, own);
  }
}

/// How the browser is opened for MAL sign-in. Overridden in tests.
final openBrowserProvider = Provider<Future<void> Function(Uri)>(
  (_) => (url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw const MalAuthException("Couldn't open a browser for MyAnimeList sign-in.");
    }
  },
);

/// A linked MyAnimeList account.
class MalAccount {
  const MalAccount({required this.username, required this.tokens});

  final String username;
  final MalTokens tokens;
}

/// The MyAnimeList account linked to the signed-in Jellyfin user: each user
/// has their own (switching users switches it). Kept on the Jellyfin
/// server in the user's settings for this app, so it follows them to every
/// device; and on the device, for when the server can't be asked.
final malAccountProvider = AsyncNotifierProvider<MalAccountController, MalAccount?>(MalAccountController.new);

class MalAccountController extends AsyncNotifier<MalAccount?> {
  /// Before links were per user: the device's one link.
  static const _legacyKey = 'mal.account';
  static const _storage = FlutterSecureStorage();

  /// The user's settings on the server that hold the link.
  static const preferencesId = 'jellyfin-client-mal';
  static const _client = 'jellyfin-client';

  /// In those settings: the account (JSON); '' once unlinked.
  static const _pref = 'account';

  StoredSession? _session;

  String get _localKey => '$_legacyKey.${_session!.key}';

  @override
  Future<MalAccount?> build() async {
    final session = _session = await ref.watch(sessionControllerProvider.future);
    if (session == null) return null;
    var raw = await _storage.read(key: _localKey);
    if (raw == null) {
      // The device's link from before goes to the user signed in now.
      raw = await _storage.read(key: _legacyKey);
      if (raw != null) {
        await _storage.write(key: _localKey, value: raw);
        await _storage.delete(key: _legacyKey);
      }
    }
    final local = _decode(raw);
    final (:reached, :value) = await _fromServer();
    if (!reached) return local;
    switch (value) {
      case null:
        // Not on the server yet (linked before links were kept there).
        if (local != null) unawaited(_toServer(local));
        return local;
      case '':
        // Unlinked on another device.
        await _storage.delete(key: _localKey);
        return null;
      default:
        final account = _decode(value);
        if (account != null && value != raw) await _storage.write(key: _localKey, value: value);
        return account ?? local;
    }
  }

  static MalAccount? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return MalAccount(username: j['username'] as String, tokens: MalAuth.decode(j['tokens'] as String));
    } on Object {
      return null;
    }
  }

  static String _encode(MalAccount account) =>
      jsonEncode({'username': account.username, 'tokens': MalAuth.encode(account.tokens)});

  Map<String, dynamic> get _query => {'userId': _session!.userId, 'client': _client};

  /// The stored link: null when there's none yet; [reached] false when the
  /// server couldn't be asked.
  Future<({bool reached, String? value})> _fromServer() async {
    try {
      final prefs = await ref.read(signedInApiProvider).getJson('/DisplayPreferences/$preferencesId', query: _query);
      return (reached: true, value: (prefs['CustomPrefs'] as Map?)?[_pref] as String?);
    } on Object catch (e) {
      AppLog.warning(LogArea.anime, "MyAnimeList link: couldn't read it from the server", error: e);
      return (reached: false, value: null);
    }
  }

  /// Null: unlinked.
  Future<void> _toServer(MalAccount? account) async {
    try {
      await ref.read(signedInApiProvider).postJson('/DisplayPreferences/$preferencesId', query: _query, body: {
        'Id': preferencesId,
        'Client': _client,
        'SortOrder': 'Ascending',
        'RememberIndexing': false,
        'RememberSorting': false,
        'ScrollDirection': 'Horizontal',
        'ShowBackdrop': true,
        'ShowSidebar': false,
        'PrimaryImageHeight': 250,
        'PrimaryImageWidth': 250,
        'CustomPrefs': {_pref: account == null ? '' : _encode(account)},
      });
    } on Object catch (e) {
      // Kept on the device anyway; the next start tries again.
      AppLog.warning(LogArea.anime, "MyAnimeList link: couldn't save it on the server", error: e);
    }
  }

  MalAuth _auth(String clientId) => MalAuth(clientId: clientId, dio: ref.read(dioFactoryProvider)());

  /// Signs in through the browser. Throws [MalAuthException] with a
  /// user-facing message on failure.
  Future<void> link() async {
    final clientId = await ref.read(malClientIdProvider.future);
    if (clientId.isEmpty) {
      throw const MalAuthException('Add a MyAnimeList client ID first (Settings > MyAnimeList).');
    }
    await _checkClientId(clientId);
    final tokens = await _auth(clientId).signIn(ref.read(openBrowserProvider));
    final username = await _api(() async => tokens.accessToken).username();
    await _save(MalAccount(username: username, tokens: tokens));
  }

  /// Before the browser: MAL answers sign-in with a client ID it doesn't
  /// know with a bare username / password box that no login gets past.
  Future<void> _checkClientId(String clientId) async {
    try {
      await ref.read(dioFactoryProvider)().get<Object?>(
            'https://api.myanimelist.net/v2/anime',
            queryParameters: {'q': 'frieren', 'limit': 1},
            options: Options(headers: {'X-MAL-CLIENT-ID': clientId}),
          );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400 || status == 401 || status == 403) {
        throw const MalAuthException(
          "MyAnimeList doesn't recognise this client ID. Check the client ID in Settings > MyAnimeList.",
        );
      }
      if (status == null) {
        throw MalAuthException("Couldn't reach MyAnimeList: ${unreachableReason(e) ?? 'check your network.'}");
      }
      // Any other answer: MAL is up; let the sign-in say what's wrong.
    }
  }

  /// For this Jellyfin user, on every device.
  Future<void> unlink() async {
    await future.catchError((Object _) => null);
    if (_session == null) return;
    state = const AsyncData(null);
    await _storage.delete(key: _localKey);
    await _toServer(null);
  }

  /// A valid access token, refreshing (and saving) it when expired.
  Future<String> accessToken() async {
    var account = state.value ?? await future;
    if (account == null) throw const MalAuthException('MyAnimeList is not linked.');
    if (!account.tokens.expiredAt(DateTime.now())) return account.tokens.accessToken;
    // Another device may have renewed it already.
    final (:reached, :value) = await _fromServer();
    final stored = reached ? _decode(value) : null;
    if (stored != null && !stored.tokens.expiredAt(DateTime.now())) {
      state = AsyncData(stored);
      await _storage.write(key: _localKey, value: value!);
      return stored.tokens.accessToken;
    }
    account = stored ?? account;
    final tokens = await _auth(await ref.read(malClientIdProvider.future)).refresh(account.tokens);
    await _save(MalAccount(username: account.username, tokens: tokens));
    return tokens.accessToken;
  }

  Future<void> _save(MalAccount account) async {
    await future.catchError((Object _) => null);
    if (_session == null) throw const MalAuthException('Sign in to Jellyfin first.');
    state = AsyncData(account);
    await _storage.write(key: _localKey, value: _encode(account));
    await _toServer(account);
  }

  MalApi _api(Future<String> Function() token) {
    final dio = ref.read(dioFactoryProvider)()..options.baseUrl = 'https://api.myanimelist.net/v2';
    return MalApi(accessToken: token, dio: dio);
  }

  /// The API for the linked account.
  MalApi api() => _api(accessToken);
}

/// Shows the user opted out of MAL updates (series IDs).
final malSyncOptOutProvider = AsyncNotifierProvider<MalSyncOptOutController, Set<String>>(MalSyncOptOutController.new);

class MalSyncOptOutController extends AsyncNotifier<Set<String>> {
  static const _key = 'anime.syncOptOut';

  @override
  Future<Set<String>> build() async =>
      ((await SharedPreferences.getInstance()).getStringList(_key) ?? const []).toSet();

  Future<void> setSynced(String seriesId, bool synced) async {
    // Wait for the stored set, or the initial load would overwrite this.
    final next = {...await future};
    synced ? next.remove(seriesId) : next.add(seriesId);
    state = AsyncData(next);
    await (await SharedPreferences.getInstance()).setStringList(_key, next.toList());
  }
}

/// Recent MAL updates (newest first) and the pending queue, for Settings.
final malSyncLogProvider = AsyncNotifierProvider<MalSyncLogController, List<MalSyncLogEntry>>(MalSyncLogController.new);

class MalSyncLogController extends AsyncNotifier<List<MalSyncLogEntry>> {
  static const _key = 'anime.syncLog';
  static const keep = 50;

  @override
  Future<List<MalSyncLogEntry>> build() async =>
      MalSyncLogEntry.decodeAll((await SharedPreferences.getInstance()).getString(_key));

  Future<void> add(MalSyncLogEntry entry) async {
    // Wait for the stored log, or the initial load would overwrite this.
    final next = [entry, ...await future].take(keep).toList();
    state = AsyncData(next);
    await (await SharedPreferences.getInstance()).setString(_key, MalSyncLogEntry.encodeAll(next));
  }
}

final malSyncServiceProvider = Provider<MalSyncService>((ref) => MalSyncService(ref));

/// Updates the user's MyAnimeList as episodes get watched. Jobs are queued
/// on disk first, so updates made offline are sent later.
class MalSyncService {
  MalSyncService(this._ref);

  final Ref _ref;
  static const _queueKey = 'anime.syncQueue';
  bool _processing = false;

  /// Pending updates, e.g. made offline.
  Future<List<MalSyncJob>> queue() async {
    final raw = (await SharedPreferences.getInstance()).getString(_queueKey);
    if (raw == null) return [];
    return [for (final j in jsonDecode(raw) as List) MalSyncJob.fromJson(j as Map<String, dynamic>)];
  }

  Future<void> _saveQueue(List<MalSyncJob> q) async => (await SharedPreferences.getInstance())
      .setString(_queueKey, jsonEncode([for (final j in q) j.toJson()]));

  Future<bool> _active() async {
    // Signed in to Jellyfin first: matching looks items up on the server.
    if (await _ref.read(sessionControllerProvider.future) == null) return false;
    final settings = await _ref.read(animeSettingsProvider.future);
    return settings.syncEnabled && await _ref.read(malAccountProvider.future) != null;
  }

  /// After playback: sync if the server now counts [itemId] as watched.
  Future<void> playbackEnded(String itemId) async {
    if (!await _active()) return;
    try {
      final item = await _ref.read(libraryApiProvider).getItem(itemId);
      if (item.type == ItemType.episode && item.userData.played) await markedWatched(item);
    } on Object catch (e) {
      debugPrint('MAL sync: $e');
    }
  }

  /// An episode or a whole season was marked watched (or, with
  /// [watched] false, unwatched).
  Future<void> markedWatched(BaseItem item, {bool watched = true}) async {
    if (!await _active()) return;
    final seriesId = item.seriesId;
    if (seriesId != null && (await _ref.read(malSyncOptOutProvider.future)).contains(seriesId)) return;
    final label = [?item.seriesName, item.type == ItemType.season ? item.name : item.episodeLabel ?? item.name].join(' ');

    final match = await _ref.read(malMatchProvider(animeKeyOf(item)).future);
    if (match == null) {
      await _log(label, 'Not matched on MyAnimeList — use "Fix match" on its page', ok: false);
      return;
    }
    final api = _ref.read(malAccountProvider.notifier).api();
    Future<int?> count(int id) async {
      try {
        return (await api.anime(id)).episodes;
      } on Object {
        return (await _ref.read(animeInfoProvider(id).future))?.episodes;
      }
    }

    var jobs = await queue();
    if (item.type == ItemType.season) {
      // Every MAL entry of the season: to its last episode, or back to none.
      for (final id in match.entries) {
        if (!watched) {
          jobs = enqueue(jobs, MalSyncJob(malId: id, episode: 1, title: label, unwatched: true));
          continue;
        }
        final total = await count(id);
        if (total != null) jobs = enqueue(jobs, MalSyncJob(malId: id, episode: total, title: label));
      }
    } else {
      final number = item.indexNumber;
      if (number == null) return;
      final (malId, episode) = await resolveMalEpisode(match.entries, number, count);
      jobs = enqueue(jobs, MalSyncJob(malId: malId, episode: episode, title: label, unwatched: !watched));
    }
    await _saveQueue(jobs);
    await processQueue();
  }

  /// Sends pending updates. Keeps a job when MAL can't be reached (retried
  /// next time); drops it with a log line when MAL refuses it.
  Future<void> processQueue() async {
    if (_processing || !await _active()) return;
    _processing = true;
    try {
      final api = _ref.read(malAccountProvider.notifier).api();
      var jobs = await queue();
      for (final job in [...jobs]) {
        try {
          final anime = await api.anime(job.malId);
          final fields = job.unwatched
              ? planMalUnwatch(anime, job.episode)
              : planMalUpdate(anime, job.episode, DateTime.now());
          if (fields == null) {
            await _log(job.title, 'Already up to date on MyAnimeList (${anime.listStatus.watchedEpisodes} watched)');
          } else {
            await api.updateListStatus(job.malId, fields);
            final status = MalStatus.fromApi(fields['status'])?.name ?? '';
            await _log(job.title, 'MyAnimeList: ${fields['num_watched_episodes']} watched · $status');
          }
          jobs = jobs.where((j) => j.malId != job.malId).toList();
          await _saveQueue(jobs);
        } on MalAuthException catch (e) {
          await _log(job.title, '$e (kept for later)', ok: false);
          return;
        } on DioException catch (e) {
          final status = e.response?.statusCode;
          if (status == null || status >= 500 || status == 429 || status == 401) {
            await _log(job.title, "Couldn't reach MyAnimeList; will retry", ok: false);
            return; // offline: keep the rest for later
          }
          await _log(job.title, 'MyAnimeList refused the update ($status)', ok: false);
          jobs = jobs.where((j) => j.malId != job.malId).toList();
          await _saveQueue(jobs);
        }
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _log(String title, String message, {bool ok = true}) {
    AppLog.add(LogArea.anime, ok ? LogLevel.info : LogLevel.warning, 'MAL sync: $title: $message');
    return _ref
        .read(malSyncLogProvider.notifier)
        .add(MalSyncLogEntry(at: DateTime.now(), title: title, message: message, ok: ok));
  }
}

/// Sends updates queued while offline, once per app start.
final malStartupSyncProvider = FutureProvider<void>((ref) => ref.read(malSyncServiceProvider).processQueue());
