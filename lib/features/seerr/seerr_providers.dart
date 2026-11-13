import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/library_api.dart';
import '../library/library_providers.dart';
import '../../core/seerr/seerr_api.dart';
import '../../core/seerr/seerr_discover.dart';
import 'seerr_health.dart';
import '../../core/log/app_log.dart';

/// A Seerr sign-in on this device.
class SeerrAccount {
  const SeerrAccount({required this.baseUrl, required this.user, this.cookie, this.apiKey});

  factory SeerrAccount.fromJson(Map<String, dynamic> j) => SeerrAccount(
        baseUrl: Uri.parse(j['baseUrl'] as String),
        user: SeerrUser(
          id: j['userId'] as int,
          displayName: j['displayName'] as String,
          permissions: j['permissions'] as int,
        ),
        cookie: j['cookie'] as String?,
        apiKey: j['apiKey'] as String?,
      );

  final Uri baseUrl;
  final SeerrUser user;
  final String? cookie;
  final String? apiKey;

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl.toString(),
        'userId': user.id,
        'displayName': user.displayName,
        'permissions': user.permissions,
        'cookie': cookie,
        'apiKey': apiKey,
      };
}

final seerrAccountProvider = AsyncNotifierProvider<SeerrAccountController, SeerrAccount?>(SeerrAccountController.new);

class SeerrAccountController extends AsyncNotifier<SeerrAccount?> {
  static const _key = 'seerr.account';
  static const _storage = FlutterSecureStorage();

  @override
  Future<SeerrAccount?> build() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    final SeerrAccount account;
    try {
      account = SeerrAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
    // Seerr may have changed what the account can do since: asked again
    // (quietly) once the saved account is in use.
    scheduleMicrotask(() => refresh().catchError((Object _) {}));
    return account;
  }

  /// The account as Seerr knows it now (permissions changed in Seerr, or
  /// saved wrong by an older version); saved when it differs.
  Future<void> refresh() async {
    final account = state.value;
    if (account == null) return;
    // Tells seerrReachableProvider whether Seerr answered.
    final me = await trackSeerr(
      () => ref.read(seerrReachableProvider.notifier),
      _api(account.baseUrl, cookie: account.cookie, apiKey: account.apiKey).me(),
    );
    if (state.value != account) return; // signed out or switched meanwhile
    if (me.permissions == account.user.permissions && me.displayName == account.user.displayName) return;
    AppLog.info(LogArea.seerr, 'Seerr account updated: ${me.role} (permissions ${me.permissions})');
    await _save(SeerrAccount(baseUrl: account.baseUrl, user: me, cookie: account.cookie, apiKey: account.apiKey));
  }

  /// The signed-in user as Seerr reports it (/auth/me), not the sign-in's
  /// reply: an email sign-in's reply can leave out the permissions, which
  /// left even the owner without Request buttons.
  Future<SeerrUser> _whoAmI(Uri baseUrl, {required SeerrUser fallback, String? cookie}) async {
    try {
      return await _api(baseUrl, cookie: cookie).me();
    } on Object catch (e) {
      AppLog.warning(LogArea.seerr, "Couldn't ask Seerr who signed in; using the sign-in's reply", error: e);
      return fallback;
    }
  }

  SeerrApi _api(Uri baseUrl, {String? cookie, String? apiKey}) =>
      SeerrApi(baseUrl: baseUrl, dio: ref.read(dioFactoryProvider)(), cookie: cookie, apiKey: apiKey);

  /// Signs in with Jellyfin credentials. Throws [SeerrException].
  Future<void> signIn(Uri baseUrl, String username, String password) async {
    final session = await _api(baseUrl).signInWithJellyfin(username, password);
    final user = await _whoAmI(baseUrl, fallback: session.user, cookie: session.cookie);
    _logSignIn('Jellyfin account', user);
    await _save(SeerrAccount(baseUrl: baseUrl, user: user, cookie: session.cookie));
  }

  /// Signs in with a Seerr-only account (email + password).
  Future<void> signInWithEmail(Uri baseUrl, String email, String password) async {
    final session = await _api(baseUrl).signInWithEmail(email, password);
    final user = await _whoAmI(baseUrl, fallback: session.user, cookie: session.cookie);
    _logSignIn('Seerr account', user);
    await _save(SeerrAccount(baseUrl: baseUrl, user: user, cookie: session.cookie));
  }

  /// Signs in with an API key (acts as the key's user, usually the admin).
  Future<void> signInWithApiKey(Uri baseUrl, String apiKey) async {
    final user = await _api(baseUrl, apiKey: apiKey).me();
    _logSignIn('API key', user);
    await _save(SeerrAccount(baseUrl: baseUrl, user: user, apiKey: apiKey));
  }

  /// What Seerr says the account can do (never the password or key).
  static void _logSignIn(String how, SeerrUser user) => AppLog.info(
        LogArea.seerr,
        'Signed in to Seerr (${how.toLowerCase()}): ${user.role}, permissions ${user.permissions}',
      );

  Future<void> signOut() async {
    final account = state.value;
    state = const AsyncData(null);
    await _storage.delete(key: _key);
    if (account?.cookie != null) {
      unawaited(_api(account!.baseUrl, cookie: account.cookie).signOut().catchError((Object _) {}));
    }
  }

  Future<void> _save(SeerrAccount account) async {
    state = AsyncData(account);
    await _storage.write(key: _key, value: jsonEncode(account.toJson()));
  }
}

/// Seerr for the signed-in account, or null.
final seerrApiProvider = Provider<SeerrApi?>((ref) {
  final account = ref.watch(seerrAccountProvider).value;
  if (account == null) return null;
  return SeerrApi(
    baseUrl: account.baseUrl,
    dio: ref.watch(dioFactoryProvider)(),
    cookie: account.cookie,
    apiKey: account.apiKey,
  );
});

/// Likely Seerr addresses next to the Jellyfin server
/// (jellyfin.home.arpa → seerr.home.arpa, jellyseerr…, overseerr…, requests…).
List<Uri> seerrAddressGuesses(Uri jellyfin) {
  final host = jellyfin.host;
  final dot = host.indexOf('.');
  if (dot < 0 || RegExp(r'^\d+\.').hasMatch(host)) {
    // A bare name or an IP: Seerr's default port on the same machine.
    return [jellyfin.replace(scheme: 'http', port: 5055, path: '')];
  }
  final domain = host.substring(dot + 1);
  return [
    for (final name in const ['seerr', 'jellyseerr', 'overseerr', 'requests'])
      Uri(scheme: jellyfin.scheme, host: '$name.$domain'),
  ];
}

/// The first guessed address that answers as Seerr, to pre-fill sign-in.
final seerrAddressSuggestionProvider = FutureProvider<Uri?>((ref) async {
  final session = await ref.watch(sessionControllerProvider.future);
  if (session == null) return null;
  for (final guess in seerrAddressGuesses(session.baseUrl)) {
    try {
      await SeerrApi(baseUrl: guess, dio: ref.read(dioFactoryProvider)()..options.connectTimeout = const Duration(seconds: 3))
          .version();
      return guess;
    } on Object {
      continue;
    }
  }
  return null;
}, retry: (_, _) => null);

/// Home-screen discover rows.
enum SeerrRow {
  trending('Trending'),
  popularAnime('Popular anime'),
  seasonalAnime("This season's anime"),
  upcomingAnime('Upcoming anime');

  const SeerrRow(this.title);

  final String title;
}

/// TMDB's "anime" keyword, used by Seerr's own anime discovery.
const _animeKeyword = '210024';

final seerrRowProvider = FutureProvider.family<List<SeerrMedia>, SeerrRow>((ref, row) async {
  final api = ref.watch(seerrApiProvider);
  if (api == null) return const [];
  final now = DateTime.now();
  return trackSeerr(() => ref.read(seerrReachableProvider.notifier), switch (row) {
    SeerrRow.trending => api.trending(),
    SeerrRow.popularAnime => api.discoverTv({'keywords': _animeKeyword, 'sortBy': 'popularity.desc'}),
    SeerrRow.seasonalAnime => () {
        final (from, to) = animeSeason(now);
        return api.discoverTv({
          'keywords': _animeKeyword,
          'firstAirDateGte': seerrDate(from),
          'firstAirDateLte': seerrDate(to),
          'sortBy': 'popularity.desc',
        });
      }(),
    SeerrRow.upcomingAnime => () {
        final (from, to) = animeSeason(now, offset: 1);
        return api.discoverTv({
          'keywords': _animeKeyword,
          'firstAirDateGte': seerrDate(from),
          'firstAirDateLte': seerrDate(to),
          'sortBy': 'popularity.desc',
        });
      }(),
  });
  // Seerr (or its connection) down for a moment: tries again by itself.
}, retry: seerrRetry);

final seerrSearchProvider = FutureProvider.autoDispose.family<List<SeerrMedia>, String>((ref, query) async {
  final api = ref.watch(seerrApiProvider);
  if (api == null || query.length < 2) return const [];
  return api.search(query);
}, retry: (_, _) => null);

typedef SeerrKey = ({SeerrMediaType type, int tmdbId});

final seerrDetailsProvider = FutureProvider.autoDispose.family<SeerrDetails, SeerrKey>((ref, key) async {
  final api = ref.watch(seerrApiProvider);
  if (api == null) throw const SeerrException('Sign in to Seerr in Settings.');
  return api.details(key.type, key.tmdbId);
}, retry: (_, _) => null);

/// Requests to show: the user's own, or everyone's for request managers.
final seerrRequestsProvider = FutureProvider.autoDispose.family<List<SeerrRequest>, bool>((ref, everyone) async {
  final api = ref.watch(seerrApiProvider);
  final account = ref.watch(seerrAccountProvider).value;
  if (api == null || account == null) return const [];
  return api.requests(requestedBy: everyone ? null : account.user.id);
}, retry: (_, _) => null);

final seerrServicesProvider = FutureProvider.autoDispose.family<List<SeerrService>, SeerrMediaType>((ref, type) async {
  final api = ref.watch(seerrApiProvider);
  if (api == null) return const [];
  return api.services(type);
}, retry: (_, _) => null);

/// A title that became (partly or fully) available since the last check.
class SeerrAvailable {
  const SeerrAvailable(this.media, this.requestId, {this.partly = false});

  final SeerrMedia media;
  final int requestId;

  /// Some of it arrived (e.g. the first episodes of an airing series).
  final bool partly;

  String get message => partly ? '${media.title}: first episodes are available.' : '${media.title} is now available.';
}

/// 0 = not on the server, 1 = partly available, 2 = available.
int _availability(int? status) => switch (SeerrMediaStatus.of(status)) {
      SeerrMediaStatus.available => 2,
      SeerrMediaStatus.partiallyAvailable => 1,
      _ => 0,
    };

/// How often to re-check requests for availability; null = only once
/// (tests, which must not leave timers running).
final seerrPollIntervalProvider = Provider<Duration?>((_) => const Duration(minutes: 10));

/// Watches the user's requests (every 10 minutes while the app runs) and
/// emits titles that just became available. Remembers what it announced.
final seerrAvailabilityProvider = StreamProvider<SeerrAvailable>((ref) {
  // Only while signed in to Seerr (rebuilt on sign-in / sign-out).
  if (ref.watch(seerrAccountProvider).value == null) return const Stream.empty();
  final controller = StreamController<SeerrAvailable>();
  Future<void> check() async {
    final api = ref.read(seerrApiProvider);
    final account = ref.read(seerrAccountProvider).value;
    if (api == null || account == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      const key = 'seerr.announced';
      final stored = prefs.getString(key);
      final known = (jsonDecode(stored ?? '{}') as Map<String, dynamic>).cast<String, int>();
      // Never checked before (not merely "no requests yet").
      final first = stored == null;
      final next = <String, int>{};
      for (final r in await api.requests(requestedBy: account.user.id)) {
        final status = r.mediaStatus.code;
        next['${r.id}'] = status;
        // Announce each step up: nothing -> partly (an airing series' first
        // episodes) -> fully available. On the very first check, just
        // record; don't announce old news.
        final before = _availability(known['${r.id}']);
        final now = _availability(status);
        if (!first && now > before) {
          final details = await api.details(r.type, r.tmdbId);
          controller.add(SeerrAvailable(details.media, r.id, partly: now == 1));
        }
      }
      await prefs.setString(key, jsonEncode(next));
    } on Object {
      // Offline or signed out: try again next time.
    }
  }

  unawaited(check());
  final interval = ref.watch(seerrPollIntervalProvider);
  final timer = interval == null ? null : Timer.periodic(interval, (_) => check());
  ref.onDispose(() {
    timer?.cancel();
    controller.close();
  });
  return controller.stream;
});

/// Shows and movies on the Jellyfin server by TMDB id ("tv:1234" /
/// "movie:5678") -> Jellyfin item id. Seerr's own "available" depends on
/// its library sync, which misses titles whose seasons TMDB splits
/// differently (one long TMDB season vs. several on the server); this
/// checks the server directly.
final libraryTmdbIndexProvider = FutureProvider<Map<String, String>>((ref) async {
  final api = ref.watch(libraryApiProvider);
  final index = <String, String>{};
  const pageSize = 500;
  for (var start = 0;; start += pageSize) {
    final page = await api.getItems(
      const ItemQuery(includeItemTypes: [ItemType.series, ItemType.movie]),
      startIndex: start,
      limit: pageSize,
    );
    for (final item in page.items) {
      final tmdb = item.providerIds['Tmdb'];
      if (tmdb == null || tmdb.isEmpty) continue;
      index['${item.type == ItemType.movie ? 'movie' : 'tv'}:$tmdb'] = item.id;
    }
    if (page.items.length < pageSize || start + pageSize >= page.totalCount) break;
  }
  return index;
}, retry: (_, _) => null);

/// The Jellyfin item for [media] when it's on the server: Seerr's own
/// link, else a TMDB id match in the library.
String? serverItemFor(SeerrMedia media, Map<String, String>? index) =>
    media.jellyfinId ?? index?['${media.type.name}:${media.tmdbId}'];
