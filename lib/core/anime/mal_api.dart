import 'package:dio/dio.dart';
import '../log/app_log.dart';
import '../log/log_interceptor.dart';

/// A MyAnimeList list status (my_list_status).
enum MalStatus {
  watching('watching'),
  completed('completed'),
  onHold('on_hold'),
  dropped('dropped'),
  planToWatch('plan_to_watch');

  const MalStatus(this.api);

  final String api;

  static MalStatus? fromApi(String? s) => values.where((v) => v.api == s).firstOrNull;
}

/// The user's entry for one anime.
class MalListStatus {
  const MalListStatus({this.status, this.watchedEpisodes = 0, this.startDate, this.finishDate, this.rewatching = false});

  factory MalListStatus.fromJson(Map<String, dynamic>? j) => j == null
      ? const MalListStatus()
      : MalListStatus(
          status: MalStatus.fromApi(j['status'] as String?),
          watchedEpisodes: (j['num_episodes_watched'] as num?)?.toInt() ?? 0,
          startDate: j['start_date'] as String?,
          finishDate: j['finish_date'] as String?,
          rewatching: j['is_rewatching'] as bool? ?? false,
        );

  /// Null when the anime isn't on the user's list.
  final MalStatus? status;
  final int watchedEpisodes;
  final String? startDate;
  final String? finishDate;
  final bool rewatching;
}

class MalAnime {
  const MalAnime({required this.id, required this.title, this.episodes, this.listStatus = const MalListStatus()});

  final int id;
  final String title;

  /// Null/0 while the total isn't known (airing).
  final int? episodes;
  final MalListStatus listStatus;
}

/// MyAnimeList API v2 with the user's access token.
class MalApi {
  MalApi({required Future<String> Function() accessToken, Dio? dio})
      : _token = accessToken,
        _dio = (dio ?? Dio(BaseOptions(baseUrl: 'https://api.myanimelist.net/v2')))
          ..interceptors.add(AppLogInterceptor(LogArea.anime));

  final Future<String> Function() _token;
  final Dio _dio;

  Future<Options> _auth([Options? o]) async =>
      (o ?? Options()).copyWith(headers: {'Authorization': 'Bearer ${await _token()}'});

  Future<String> username() async {
    final r = await _dio.get<Map<String, dynamic>>('/users/@me', options: await _auth());
    return r.data!['name'] as String;
  }

  Future<MalAnime> anime(int id) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/anime/$id',
      queryParameters: {'fields': 'num_episodes,my_list_status'},
      options: await _auth(),
    );
    final d = r.data!;
    final episodes = (d['num_episodes'] as num?)?.toInt();
    return MalAnime(
      id: d['id'] as int,
      title: d['title'] as String? ?? '',
      episodes: episodes == 0 ? null : episodes,
      listStatus: MalListStatus.fromJson(d['my_list_status'] as Map<String, dynamic>?),
    );
  }

  Future<void> updateListStatus(int id, Map<String, String> fields) async {
    await _dio.patch<void>(
      '/anime/$id/my_list_status',
      data: fields,
      options: await _auth(Options(contentType: Headers.formUrlEncodedContentType)),
    );
  }
}
