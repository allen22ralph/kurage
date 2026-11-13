import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/anime/anime_ids.dart';
import 'package:jellyfin_client/core/anime/anime_info.dart';
import 'package:jellyfin_client/core/jellyfin/client_info.dart';
import 'package:jellyfin_client/core/jellyfin/server_discovery.dart';
import 'package:jellyfin_client/features/seerr/seerr_providers.dart';
import 'package:jellyfin_client/features/anime/anime_providers.dart';
import 'package:jellyfin_client/features/home/home_header.dart';
import 'package:jellyfin_client/features/home/home_header_settings.dart';
import 'package:jellyfin_client/features/library/widgets/item_image.dart';
import 'package:flutter/widgets.dart';

/// A canned response: status code and JSON body (null for no body).
typedef FakeResponse = (int, Object?);

/// Answers Dio requests from a route table instead of the network.
///
/// Routes are matched by full URL first (`https://host/path`), then by
/// `METHOD /path`, then by `/path`. Unmatched requests get a 404.
/// A route value may also be a function of the request, for dynamic replies.
class FakeServer implements HttpClientAdapter {
  FakeServer(this.routes);

  final Map<String, Object> routes;

  /// Extra response headers by path (e.g. Set-Cookie on a sign-in).
  final Map<String, Map<String, List<String>>> responseHeaders = {};
  final requests = <RequestOptions>[];

  /// Requests made to [path], in order.
  List<RequestOptions> requestsTo(String path) =>
      requests.where((r) => r.uri.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final uri = options.uri;
    final route = routes['${uri.origin}${uri.path}'] ??
        routes['${options.method} ${uri.path}'] ??
        routes[uri.path];

    final FakeResponse response = switch (route) {
      null => (404, null),
      final FakeResponse r => r,
      final FakeResponse Function(RequestOptions) f => f(options),
      _ => throw ArgumentError('Bad route for ${uri.path}: $route'),
    };
    if (response.$1 == -1) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'unreachable',
      );
    }
    if (response.$1 == -2) {
      // What dart:io raises for a certificate from an unknown (private) CA.
      throw DioException(
        requestOptions: options,
        error: const HandshakeException(
          'Handshake error in client',
          OSError('CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate'),
        ),
      );
    }
    // A String body is sent as-is (HTML pages); anything else as JSON.
    final body = response.$2;
    return ResponseBody.fromString(
      body == null ? '' : body is String ? body : jsonEncode(body),
      response.$1,
      headers: {
        Headers.contentTypeHeader: [body is String ? 'text/html; charset=utf-8' : Headers.jsonContentType],
        ...?responseHeaders[uri.path],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Simulates a host that refuses connections.
const FakeResponse unreachable = (-1, null);

/// Simulates HTTPS signed by a CA this device doesn't trust.
const FakeResponse untrustedCertificate = (-2, null);

const testClientInfo = ClientInfo(
  clientName: 'Test',
  deviceName: 'Test Device',
  deviceId: 'test-device',
  version: '0.0.1',
);

/// Provider overrides that route all API traffic to [server].
/// Provider overrides that route all API traffic to [server]. Anime data
/// stays in memory; pass [animeIds] to match items (default: none match).
///
/// Home's header is off unless [header] (it adds names and requests that
/// other tests don't expect).
List<Override> fakeServerOverrides(
  FakeServer server, {
  AnimeIdMapping animeIds = const AnimeIdMapping(),
  bool header = false,
  Stream<DiscoveredServer> Function()? discover,
}) =>
    [
      if (!header) homeHeaderSettingsProvider.overrideWith(_HeaderOff.new),
      featuredShuffleProvider.overrideWithValue((_) {}),
      clientInfoProvider.overrideWithValue(testClientInfo),
      dioFactoryProvider.overrideWithValue(
        () => Dio()..httpClientAdapter = server,
      ),
      seerrPollIntervalProvider.overrideWithValue(null),
      serverDiscoveryProvider.overrideWithValue(discover ?? () => const Stream.empty()),
      networkChangesProvider.overrideWithValue(const Stream.empty()),
      animeIdMappingProvider.overrideWith((ref) async => animeIds),
      animeInfoCacheProvider.overrideWith((ref) async => AnimeInfoCache()),
      jikanApiProvider.overrideWith(
        (ref) => JikanApi(
          dio: Dio(BaseOptions(baseUrl: 'https://api.jikan.moe/v4'))..httpClientAdapter = server,
          spacing: Duration.zero,
        ),
      ),
      networkImageBuilderProvider.overrideWithValue(
        (url, {required fit, required alignment, required fallback}) =>
            const SizedBox.expand(),
      ),
    ];

const testServerInfo = {
  'Id': 'srv1',
  'ServerName': 'sam',
  'Version': '10.11.11',
};

Map<String, Object?> authResponse({String token = 'tok', String user = 'sam'}) => {
      'AccessToken': token,
      'ServerId': 'srv1',
      'User': {'Id': 'u-$user', 'Name': user},
    };

/// Secure-storage contents for an already signed-in user, so tests can
/// start on the home screen. Pass to `FlutterSecureStorage.setMockInitialValues`.
Map<String, String> signedInStorage({
  String baseUrl = 'https://jellyfin.home.arpa',
  String userId = 'u1',
}) {
  final session = {
    'serverId': 'srv1',
    'serverName': 'sam',
    'baseUrl': baseUrl,
    'userId': userId,
    'userName': 'sam',
    'accessToken': 'tok',
  };
  return {
    'sessions': jsonEncode([session]),
    'active_session': 'srv1:$userId',
  };
}

/// Minimal item JSON for fake responses.
Map<String, Object?> itemJson(
  String id,
  String name, {
  String type = 'Movie',
  Map<String, Object?> extra = const {},
}) =>
    {
      'Id': id,
      'Name': name,
      'Type': type,
      'ImageTags': {'Primary': 'tag-$id'},
      'UserData': {'Played': false, 'PlaybackPositionTicks': 0},
      ...extra,
    };

Map<String, Object?> pageJson(List<Map<String, Object?>> items, {int? total, int start = 0}) => {
      'Items': items,
      'TotalRecordCount': total ?? items.length,
      'StartIndex': start,
    };

class _HeaderOff extends HomeHeaderSettingsController {
  @override
  Future<HomeHeaderSettings> build() async => const HomeHeaderSettings(style: HeaderStyle.off);
}
