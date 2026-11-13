import 'package:dio/dio.dart';
import '../log/app_log.dart';
import '../log/log_interceptor.dart';
import '../net/reach_error.dart';

/// Seerr user permissions (bit flags, as in Overseerr/Jellyseerr/Seerr).
abstract final class SeerrPermission {
  static const admin = 2;
  static const manageRequests = 16;
  static const request = 32;
  static const autoApprove = 128;
  static const request4k = 1024;
  static const request4kMovie = 2048;
  static const request4kTv = 4096;
  static const requestAdvanced = 8192;
  static const requestMovie = 262144;
  static const requestTv = 524288;
}

/// Availability of a title on the media server (Seerr's MediaStatus).
enum SeerrMediaStatus {
  unknown(1, 'Not requested'),
  pending(2, 'Requested'),
  processing(3, 'Processing'),
  partiallyAvailable(4, 'Partly available'),
  available(5, 'Available'),
  // Seerr 3's numbering: blocklisted titles are 6, deleted 7.
  blocklisted(6, 'Blocklisted'),
  deleted(7, 'Deleted');

  const SeerrMediaStatus(this.code, this.label);

  final int code;
  final String label;

  static SeerrMediaStatus of(Object? code) =>
      values.where((s) => s.code == code).firstOrNull ?? unknown;

  /// Already on the server (or on its way) — no new request needed.
  bool get requestable => this == unknown || this == deleted || this == partiallyAvailable;
}

/// A request's approval state (Seerr's MediaRequestStatus).
enum SeerrRequestStatus {
  pending(1, 'Pending approval'),
  approved(2, 'Approved'),
  declined(3, 'Declined'),
  failed(4, 'Failed'),
  completed(5, 'Completed');

  const SeerrRequestStatus(this.code, this.label);

  final int code;
  final String label;

  static SeerrRequestStatus of(Object? code) =>
      values.where((s) => s.code == code).firstOrNull ?? pending;
}

enum SeerrMediaType {
  movie,
  tv;

  static SeerrMediaType? of(Object? s) => switch (s) {
        'movie' => movie,
        'tv' => tv,
        _ => null,
      };
}

class SeerrUser {
  const SeerrUser({required this.id, required this.displayName, required this.permissions});

  factory SeerrUser.fromJson(Map<String, dynamic> j) => SeerrUser(
        id: j['id'] as int,
        displayName: (j['displayName'] ?? j['jellyfinUsername'] ?? j['username'] ?? j['email'] ?? '') as String,
        permissions: (j['permissions'] as num?)?.toInt() ?? 0,
      );

  final int id;
  final String displayName;
  final int permissions;

  /// Admins have every permission.
  bool can(int permission) =>
      permissions & SeerrPermission.admin != 0 || permissions & permission != 0;

  bool canRequest(SeerrMediaType type) =>
      can(SeerrPermission.request) ||
      can(type == SeerrMediaType.movie ? SeerrPermission.requestMovie : SeerrPermission.requestTv);

  bool canRequest4k(SeerrMediaType type) =>
      can(SeerrPermission.request4k) ||
      can(type == SeerrMediaType.movie ? SeerrPermission.request4kMovie : SeerrPermission.request4kTv);

  bool get canManageRequests => can(SeerrPermission.manageRequests);
  bool get canRequestAdvanced => can(SeerrPermission.requestAdvanced);

  /// What this account may do, in a word (Settings > Seerr). Seerr's first
  /// user (id 1) is its owner.
  String get role => switch (this) {
        _ when id == 1 => 'Owner',
        _ when permissions & SeerrPermission.admin != 0 => 'Admin',
        _ when canRequest(SeerrMediaType.movie) && canRequest(SeerrMediaType.tv) => 'Can request',
        _ when canRequest(SeerrMediaType.tv) => 'Can request shows',
        _ when canRequest(SeerrMediaType.movie) => 'Can request movies',
        _ => "Can't request",
      };
}

/// A movie or show from TMDB, as Seerr lists it, with its availability.
class SeerrMedia {
  const SeerrMedia({
    required this.tmdbId,
    required this.type,
    required this.title,
    this.year,
    this.posterPath,
    this.backdropPath,
    this.overview,
    this.status = SeerrMediaStatus.unknown,
    this.voteAverage,
    this.jellyfinId,
    this.note,
    this.genreIds,
    this.originalLanguage,
  });

  /// From a search/discover result (`mediaType` + `title`/`name`).
  static SeerrMedia? fromResult(Map<String, dynamic> j, {SeerrMediaType? type}) {
    final mediaType = type ?? SeerrMediaType.of(j['mediaType']);
    if (mediaType == null) return null; // people
    final date = (j['releaseDate'] ?? j['firstAirDate']) as String?;
    return SeerrMedia(
      tmdbId: j['id'] as int,
      type: mediaType,
      title: (j['title'] ?? j['name'] ?? '') as String,
      year: date != null && date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
      posterPath: j['posterPath'] as String?,
      backdropPath: j['backdropPath'] as String?,
      overview: j['overview'] as String?,
      status: SeerrMediaStatus.of((j['mediaInfo'] as Map?)?['status']),
      voteAverage: (j['voteAverage'] as num?)?.toDouble(),
      jellyfinId: (j['mediaInfo'] as Map?)?['jellyfinMediaId'] as String?,
      genreIds: switch (j['genreIds'] ?? j['genres']) {
        final List l => [for (final g in l) if ((g is Map ? g['id'] : g) case final num id) id.toInt()],
        _ => null,
      },
      originalLanguage: j['originalLanguage'] as String?,
    );
  }

  final int tmdbId;
  final SeerrMediaType type;
  final String title;
  final int? year;
  final String? posterPath;
  final String? backdropPath;
  final String? overview;
  final SeerrMediaStatus status;
  final double? voteAverage;

  /// The Jellyfin item, once Seerr has seen it on the server.
  final String? jellyfinId;

  /// Why it's shown, e.g. "Recommended by 4 of your shows" (shown on the
  /// card instead of year · type).
  final String? note;

  /// For suggestion filters; null when the result didn't say.
  final List<int>? genreIds;
  final String? originalLanguage;

  SeerrMedia withNote(String? note) => SeerrMedia(
        tmdbId: tmdbId,
        type: type,
        title: title,
        year: year,
        posterPath: posterPath,
        backdropPath: backdropPath,
        overview: overview,
        status: status,
        voteAverage: voteAverage,
        jellyfinId: jellyfinId,
        note: note,
        genreIds: genreIds,
        originalLanguage: originalLanguage,
      );

  /// "tv:1234" / "movie:5678".
  String get key => '${type.name}:$tmdbId';

  Uri? poster([String size = 'w342']) =>
      posterPath == null ? null : Uri.parse('https://image.tmdb.org/t/p/$size$posterPath');
  Uri? backdrop([String size = 'w1280']) =>
      backdropPath == null ? null : Uri.parse('https://image.tmdb.org/t/p/$size$backdropPath');
}

class SeerrSeason {
  const SeerrSeason({required this.number, required this.name, this.episodeCount, this.status = SeerrMediaStatus.unknown});

  final int number;
  final String name;
  final int? episodeCount;

  /// This season's availability on the server.
  final SeerrMediaStatus status;
}

/// Details for the request screen: seasons (TV) and their availability.
class SeerrDetails {
  const SeerrDetails({
    required this.media,
    this.seasons = const [],
    this.genres = const [],
    this.keywords = const [],
    this.originalLanguage,
    this.companies = const [],
  });

  /// TMDB's "anime" keyword: how Seerr decides a show is anime (and uses
  /// Sonarr's anime profile and folder).
  static const animeKeywordId = 210024;

  bool get isAnime => media.type == SeerrMediaType.tv && keywords.any((k) => k.id == animeKeywordId);

  factory SeerrDetails.fromJson(Map<String, dynamic> j, SeerrMediaType type) {
    final media = SeerrMedia.fromResult(j, type: type)!;
    final seasonStatus = <int, SeerrMediaStatus>{
      for (final s in ((j['mediaInfo'] as Map?)?['seasons'] as List?) ?? const [])
        (s as Map)['seasonNumber'] as int: SeerrMediaStatus.of(s['status']),
    };
    List<({int id, String name})> named(Object? list) => [
          for (final e in (list as List?) ?? const [])
            if ((e as Map)['id'] case final num id) (id: id.toInt(), name: (e['name'] as String?) ?? '$id'),
        ];
    return SeerrDetails(
      media: media,
      genres: named(j['genres']),
      // TV: keywords is a list; movies: {keywords: [...]} in some versions.
      keywords: named(j['keywords'] is Map ? (j['keywords'] as Map)['keywords'] : j['keywords']),
      originalLanguage: j['originalLanguage'] as String?,
      companies: named(type == SeerrMediaType.tv ? j['networks'] : j['productionCompanies']),
      seasons: [
        for (final s in (j['seasons'] as List?) ?? const [])
          if ((s as Map)['seasonNumber'] case final int n when n > 0) // specials aren't requestable
            SeerrSeason(
              number: n,
              name: s['name'] as String? ?? 'Season $n',
              episodeCount: s['episodeCount'] as int?,
              status: seasonStatus[n] ?? SeerrMediaStatus.unknown,
            ),
      ],
    );
  }

  final SeerrMedia media;
  final List<SeerrSeason> seasons;

  /// For recommendations (taste profile).
  final List<({int id, String name})> genres;
  final List<({int id, String name})> keywords;
  final String? originalLanguage;

  /// Networks (TV) or studios (movies).
  final List<({int id, String name})> companies;
}

/// A request, with what's needed to show it.
class SeerrRequest {
  const SeerrRequest({
    required this.id,
    required this.status,
    required this.type,
    required this.tmdbId,
    required this.mediaStatus,
    required this.requestedBy,
    required this.createdAt,
    this.seasons = const [],
    this.is4k = false,
  });

  factory SeerrRequest.fromJson(Map<String, dynamic> j) {
    final media = j['media'] as Map<String, dynamic>? ?? const {};
    return SeerrRequest(
      id: j['id'] as int,
      status: SeerrRequestStatus.of(j['status']),
      type: SeerrMediaType.of(j['type'] ?? media['mediaType']) ?? SeerrMediaType.tv,
      tmdbId: media['tmdbId'] as int? ?? 0,
      mediaStatus: SeerrMediaStatus.of(media[j['is4k'] == true ? 'status4k' : 'status']),
      requestedBy: SeerrUser.fromJson(j['requestedBy'] as Map<String, dynamic>? ?? const {'id': 0}),
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      seasons: [for (final s in (j['seasons'] as List?) ?? const []) (s as Map)['seasonNumber'] as int],
      is4k: j['is4k'] as bool? ?? false,
    );
  }

  final int id;
  final SeerrRequestStatus status;
  final SeerrMediaType type;
  final int tmdbId;

  /// Where the title is now: requested → processing → available.
  final SeerrMediaStatus mediaStatus;
  final SeerrUser requestedBy;
  final DateTime createdAt;
  final List<int> seasons;
  final bool is4k;
}

/// A Sonarr/Radarr server Seerr can send requests to.
class SeerrService {
  const SeerrService({
    required this.id,
    required this.name,
    this.is4k = false,
    this.isDefault = false,
    this.profiles = const [],
    this.rootFolders = const [],
    this.activeProfileId,
    this.activeDirectory,
    this.activeAnimeProfileId,
    this.activeAnimeDirectory,
    this.freeSpace = const {},
  });

  factory SeerrService.fromJson(Map<String, dynamic> j) => SeerrService(
        id: j['id'] as int,
        name: j['name'] as String? ?? 'Server',
        is4k: j['is4k'] as bool? ?? false,
        isDefault: j['isDefault'] as bool? ?? false,
        activeProfileId: j['activeProfileId'] as int?,
        activeDirectory: j['activeDirectory'] as String?,
        activeAnimeProfileId: j['activeAnimeProfileId'] as int?,
        activeAnimeDirectory: j['activeAnimeDirectory'] as String?,
      );

  /// From `/service/{sonarr|radarr}/{id}`: server plus its profiles and folders.
  factory SeerrService.fromDetails(Map<String, dynamic> j) {
    final base = SeerrService.fromJson(j['server'] as Map<String, dynamic>);
    return SeerrService(
      id: base.id,
      name: base.name,
      is4k: base.is4k,
      isDefault: base.isDefault,
      activeProfileId: base.activeProfileId,
      activeDirectory: base.activeDirectory,
      activeAnimeProfileId: base.activeAnimeProfileId,
      activeAnimeDirectory: base.activeAnimeDirectory,
      freeSpace: {
        for (final f in (j['rootFolders'] as List?) ?? const [])
          if ((f as Map)['freeSpace'] case final num free) f['path'] as String: free.toInt(),
      },
      profiles: [
        for (final p in (j['profiles'] as List?) ?? const [])
          (id: (p as Map)['id'] as int, name: p['name'] as String),
      ],
      rootFolders: [for (final f in (j['rootFolders'] as List?) ?? const []) (f as Map)['path'] as String],
    );
  }

  final int id;
  final String name;
  final bool is4k;
  final bool isDefault;
  final List<({int id, String name})> profiles;
  final List<String> rootFolders;
  final int? activeProfileId;
  final String? activeDirectory;

  /// Sonarr's anime defaults (Seerr uses them for anime when a request
  /// names no profile / folder).
  final int? activeAnimeProfileId;
  final String? activeAnimeDirectory;

  /// Free bytes per root folder.
  final Map<String, int> freeSpace;

  /// The profile and folder Seerr uses when a request leaves them out.
  int? defaultProfileFor({required bool anime}) => anime ? activeAnimeProfileId ?? activeProfileId : activeProfileId;
  String? defaultFolderFor({required bool anime}) => anime ? activeAnimeDirectory ?? activeDirectory : activeDirectory;
}

class SeerrException implements Exception {
  const SeerrException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Seerr REST API v1. Authenticated by the session cookie from a Jellyfin
/// sign-in, or by an API key.
class SeerrApi {
  SeerrApi({required Uri baseUrl, required Dio dio, this.cookie, this.apiKey})
      : _dio = dio
          ..options.baseUrl = '${baseUrl.toString().replaceAll(RegExp(r'/+$'), '')}/api/v1'
          // Time limits (as for Jellyfin): Seerr gone (its VPN reconnecting)
          // fails a request in seconds, so rows retry and come back, rather
          // than hanging on it.
          ..options.connectTimeout ??= const Duration(seconds: 10)
          ..options.receiveTimeout ??= const Duration(seconds: 30)
          ..options.sendTimeout ??= const Duration(seconds: 30)
          ..interceptors.add(AppLogInterceptor(LogArea.seerr));

  final Dio _dio;
  final String? cookie;
  final String? apiKey;

  Options get _auth => Options(headers: {
        if (cookie != null) 'Cookie': cookie,
        if (apiKey != null) 'X-Api-Key': apiKey,
      });

  Future<T> _call<T>(Future<Response<T>> Function() send) async {
    try {
      return (await send()).data as T;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final serverMessage = (e.response?.data is Map) ? (e.response!.data as Map)['message'] as String? : null;
      throw SeerrException(
        switch (status) {
          null => unreachableReason(e) ?? "Couldn't reach Seerr. Check the address.",
          401 || 403 => serverMessage ?? 'Not allowed — sign in to Seerr again.',
          _ => serverMessage ?? 'Seerr error ($status).',
        },
        statusCode: status,
      );
    }
  }

  /// Seerr's version, to check an address is a Seerr server (no sign-in).
  Future<String> version() async =>
      (await _call(() => _dio.get<Map<String, dynamic>>('/status')))['version'] as String? ?? '?';

  /// Signs in with Jellyfin credentials; returns the session cookie.
  Future<({String cookie, SeerrUser user})> signInWithJellyfin(String username, String password) =>
      _signIn('/auth/jellyfin', {'username': username, 'password': password}, 'Jellyfin username or password');

  /// Signs in with a Seerr (local) account's email and password.
  Future<({String cookie, SeerrUser user})> signInWithEmail(String email, String password) =>
      _signIn('/auth/local', {'email': email, 'password': password}, 'email or password');

  Future<({String cookie, SeerrUser user})> _signIn(String path, Map<String, String> body, String what) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(path, data: body);
      final session = (r.headers['set-cookie'] ?? const [])
          .map((c) => c.split(';').first)
          .where((c) => c.startsWith('connect.sid='))
          .firstOrNull;
      if (session == null) throw const SeerrException('Seerr did not start a session.');
      return (cookie: session, user: SeerrUser.fromJson(r.data!));
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      throw SeerrException(
        status == 401 || status == 403
            ? 'Wrong $what (or no Seerr access).'
            : status == null
                ? unreachableReason(e) ?? "Couldn't reach Seerr. Check the address."
                : 'Seerr sign-in failed ($status).',
        statusCode: status,
      );
    }
  }

  Future<SeerrUser> me() async =>
      SeerrUser.fromJson(await _call(() => _dio.get<Map<String, dynamic>>('/auth/me', options: _auth)));

  Future<void> signOut() => _call(() => _dio.post<void>('/auth/logout', options: _auth));

  Future<({List<SeerrMedia> results, int totalPages})> _page(String path, Map<String, Object?> query,
      {SeerrMediaType? type}) async {
    final data = await _call(() => _dio.get<Map<String, dynamic>>(path, queryParameters: query, options: _auth));
    return (
      // Blocklisted titles never show (as on Seerr's own Discover).
      results: [
        for (final r in (data['results'] as List?) ?? const [])
          if (SeerrMedia.fromResult(r as Map<String, dynamic>, type: type) case final m?
              when m.status != SeerrMediaStatus.blocklisted)
            m,
      ],
      totalPages: (data['totalPages'] as num?)?.toInt() ?? 1,
    );
  }

  /// Seerr rejects reserved characters in `query`, including the `+` Dio
  /// uses for spaces, so it's percent-encoded by hand (`%20`).
  Future<List<SeerrMedia>> search(String query, {int page = 1}) async =>
      (await _page('/search?query=${Uri.encodeComponent(query)}', {'page': page})).results;

  Future<List<SeerrMedia>> trending({int page = 1}) async =>
      (await _page('/discover/trending', {'page': page})).results;

  /// Trending [mediaType] (all / movie / tv) over [timeWindow] (day / week).
  Future<List<SeerrMedia>> trendingOf({String mediaType = 'all', String timeWindow = 'week'}) async =>
      (await _page('/discover/trending', {'mediaType': mediaType, 'timeWindow': timeWindow})).results;

  /// TMDB's recommendations for a title.
  Future<List<SeerrMedia>> recommendations(SeerrMediaType type, int tmdbId, {int page = 1}) async => (await _page(
        type == SeerrMediaType.tv ? '/tv/$tmdbId/recommendations' : '/movie/$tmdbId/recommendations',
        {'page': page},
        type: type,
      ))
          .results;

  Future<List<SeerrMedia>> upcoming(SeerrMediaType type) async => (await _page(
        type == SeerrMediaType.tv ? '/discover/tv/upcoming' : '/discover/movies/upcoming',
        const {},
        type: type,
      ))
          .results;

  /// The user's Seerr watchlist. Its entries carry only ids, so each one's
  /// details (poster, availability) are looked up.
  Future<List<SeerrMedia>> watchlist({int limit = 20}) async {
    final data = await getMap('/discover/watchlist');
    final entries = [
      for (final e in ((data['results'] as List?) ?? const []).take(limit))
        if (SeerrMediaType.of((e as Map)['mediaType']) case final type?)
          if ((e['tmdbId'] as num?)?.toInt() case final id?) (type, id),
    ];
    return [
      for (final (type, id) in entries)
        if ((await details(type, id)).media case final m when m.status != SeerrMediaStatus.blocklisted) m,
    ];
  }

  /// GET helpers for the lookup lists (see seerr_discover.dart).
  Future<Map<String, dynamic>> getMap(String path, {Map<String, Object?>? query}) =>
      _call(() => _dio.get<Map<String, dynamic>>(path, queryParameters: query, options: _auth));

  Future<List<Map<String, dynamic>>> getList(String path, {Map<String, Object?>? query}) async => [
        for (final e in await _call(() => _dio.get<List<dynamic>>(path, queryParameters: query, options: _auth)))
          (e as Map).cast<String, dynamic>(),
      ];

  /// `results` of a paged search. Seerr wants `query` percent-encoded by
  /// hand (see [search]).
  Future<List<Map<String, dynamic>>> getResults(String path, Map<String, String> query) async {
    final q = query.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    final data = await getMap('$path?$q');
    return [for (final r in (data['results'] as List?) ?? const []) (r as Map).cast<String, dynamic>()];
  }

  Future<List<SeerrMedia>> discoverTv(Map<String, Object?> filters, {int page = 1}) async =>
      (await _page('/discover/tv', {'page': page, ...filters}, type: SeerrMediaType.tv)).results;

  Future<List<SeerrMedia>> discoverMovies(Map<String, Object?> filters, {int page = 1}) async =>
      (await _page('/discover/movies', {'page': page, ...filters}, type: SeerrMediaType.movie)).results;

  Future<SeerrDetails> details(SeerrMediaType type, int tmdbId) async {
    final path = type == SeerrMediaType.movie ? '/movie/$tmdbId' : '/tv/$tmdbId';
    return SeerrDetails.fromJson(
      await _call(() => _dio.get<Map<String, dynamic>>(path, options: _auth)),
      type,
    );
  }

  /// Requests a title. [seasons] null = all seasons (TV). Server, profile
  /// and folder only when the user may choose them (advanced requests).
  Future<SeerrRequest> request(
    SeerrMediaType type,
    int tmdbId, {
    List<int>? seasons,
    bool is4k = false,
    int? serverId,
    int? profileId,
    String? rootFolder,
  }) async {
    final data = await _call(() => _dio.post<Map<String, dynamic>>(
          '/request',
          data: {
            'mediaType': type.name,
            'mediaId': tmdbId,
            if (type == SeerrMediaType.tv) 'seasons': seasons ?? 'all',
            'is4k': is4k,
            'serverId': ?serverId,
            'profileId': ?profileId,
            'rootFolder': ?rootFolder,
          },
          options: _auth,
        ));
    return SeerrRequest.fromJson(data);
  }

  /// Requests, newest first; [requestedBy] limits to one user's.
  Future<List<SeerrRequest>> requests({int take = 50, int skip = 0, String filter = 'all', int? requestedBy}) async {
    final data = await _call(() => _dio.get<Map<String, dynamic>>(
          '/request',
          queryParameters: {
            'take': take,
            'skip': skip,
            'filter': filter,
            'sort': 'added',
            'requestedBy': ?requestedBy,
          },
          options: _auth,
        ));
    return [for (final r in (data['results'] as List?) ?? const []) SeerrRequest.fromJson(r as Map<String, dynamic>)];
  }

  Future<void> approve(int requestId) =>
      _call(() => _dio.post<void>('/request/$requestId/approve', options: _auth));
  Future<void> decline(int requestId) =>
      _call(() => _dio.post<void>('/request/$requestId/decline', options: _auth));
  Future<void> cancel(int requestId) => _call(() => _dio.delete<void>('/request/$requestId', options: _auth));

  /// Sonarr (TV) or Radarr (movie) servers, with profiles and folders.
  Future<List<SeerrService>> services(SeerrMediaType type) async {
    final kind = type == SeerrMediaType.movie ? 'radarr' : 'sonarr';
    final list = await _call(() => _dio.get<List<dynamic>>('/service/$kind', options: _auth));
    return [
      for (final s in list)
        SeerrService.fromDetails(await _call(() => _dio.get<Map<String, dynamic>>(
              '/service/$kind/${(s as Map)['id']}',
              options: _auth,
            ))),
    ];
  }
}
