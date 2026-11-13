import 'dart:io';

import 'package:dio/dio.dart';

import 'client_info.dart';
import 'models.dart';
import '../log/app_log.dart';
import '../log/log_interceptor.dart';
import 'dart:convert';
import '../net/reach_error.dart';

/// Thrown for any failed Jellyfin request, with a user-presentable [message].
class JellyfinException implements Exception {
  const JellyfinException(this.message, {this.statusCode, this.untrustedCertificate = false});

  final String message;
  final int? statusCode;

  /// The server's HTTPS certificate isn't trusted on this device, typically
  /// a self-hosted server signed by a private CA (e.g. Caddy's local CA).
  final bool untrustedCertificate;

  @override
  String toString() => 'JellyfinException($statusCode): $message';
}

/// Thin wrapper over the Jellyfin REST API for one server.
///
/// Holds the access token once signed in and attaches the
/// `Authorization: MediaBrowser ...` header to every request. Feature areas
/// (library, playback, ...) build on [getJson] / [postJson] / [delete].
class JellyfinApi {
  JellyfinApi({
    required this.baseUrl,
    required this.clientInfo,
    this._accessToken,
    this.onUnauthorized,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = baseUrl.toString()
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30);
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Authorization'] = authorizationHeader;
          handler.next(options);
        },
        onError: (error, handler) {
          // A 401 on an authenticated request means the token was revoked
          // (signed out elsewhere, user deleted, ...).
          if (error.response?.statusCode == 401 && _accessToken != null) {
            onUnauthorized?.call();
          }
          handler.next(error);
        },
      ),
    );
    _dio.interceptors.add(AppLogInterceptor(LogArea.network));
  }

  final Uri baseUrl;
  final ClientInfo clientInfo;

  /// Called when the server rejects the stored access token.
  final void Function()? onUnauthorized;

  final Dio _dio;
  String? _accessToken;

  String? get accessToken => _accessToken;
  bool get isAuthenticated => _accessToken != null;

  /// Value for the `Authorization` header, e.g. for media requests made
  /// outside Dio (the video player, image cache).
  String get authorizationHeader =>
      clientInfo.authorizationHeader(token: _accessToken);

  /// Absolute URL for [path] on this server, with optional [query].
  Uri resolve(String path, [Map<String, Object?> query = const {}]) {
    final params = <String, String>{
      for (final e in query.entries)
        if (e.value != null) e.key: '${e.value}',
    };
    final base = baseUrl.path.endsWith('/') ? baseUrl.path : '${baseUrl.path}/';
    final relative = path.startsWith('/') ? path.substring(1) : path;
    return baseUrl.replace(
      path: '$base$relative',
      queryParameters: params.isEmpty ? null : params,
    );
  }

  /// URL of an item image, e.g. `imageUrl(id, 'Primary', tag: tag)`.
  ///
  /// Image endpoints are public, so no token is attached. [maxWidth] lets
  /// the server resize, which matters a lot for poster grids.
  Uri imageUrl(
    String itemId,
    String imageType, {
    String? tag,
    int? maxWidth,
    int? maxHeight,
    int quality = 90,
    int? blur,
  }) {
    return resolve('/Items/$itemId/Images/$imageType', {
      'tag': tag,
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
      'quality': quality,
      // Blurred by the server (backgrounds: no blurring on the device).
      'blur': blur,
    });
  }

  /// A user's profile picture (Jellyfin 10.9+ `/UserImage`); public.
  Uri userImageUrl(String userId, {String? tag, int maxWidth = 200}) {
    return resolve('/UserImage', {
      'userId': userId,
      'tag': tag,
      'maxWidth': maxWidth,
    });
  }

  /// Sets [userId]'s profile picture: the image's bytes, base64 encoded as
  /// Jellyfin expects, with its type (e.g. image/jpeg). Servers before 10.9
  /// only know the older address.
  Future<void> setUserImage(String userId, List<int> bytes, String mimeType) async {
    final body = base64Encode(bytes);
    final options = Options(contentType: mimeType);
    try {
      await _dio.post<void>('/UserImage', queryParameters: {'userId': userId}, data: body, options: options);
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) throw _wrap(e);
      try {
        await _dio.post<void>('/Users/$userId/Images/Primary', data: body, options: options);
      } on DioException catch (e) {
        throw _wrap(e);
      }
    }
  }

  /// Removes [userId]'s profile picture.
  Future<void> deleteUserImage(String userId) async {
    try {
      await _dio.delete<void>('/UserImage', queryParameters: {'userId': userId});
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) throw _wrap(e);
      try {
        await _dio.delete<void>('/Users/$userId/Images/Primary');
      } on DioException catch (e) {
        throw _wrap(e);
      }
    }
  }

  /// Checks that the address points at a Jellyfin server. No auth needed.
  Future<PublicSystemInfo> getPublicSystemInfo() async {
    final data = await getJson('/System/Info/Public');
    return PublicSystemInfo.fromJson(data);
  }

  /// Users shown on the login screen (those not hidden by the admin).
  Future<List<JellyfinUser>> getPublicUsers() async {
    final data = await getList('/Users/Public');
    return data
        .map((e) => JellyfinUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<AuthResult> authenticateByName(String username, String password) async {
    final data = await postJson(
      '/Users/AuthenticateByName',
      body: {'Username': username, 'Pw': password},
    );
    final result = AuthResult.fromJson(data);
    _accessToken = result.accessToken;
    return result;
  }

  Future<bool> isQuickConnectEnabled() async {
    try {
      final response = await _dio.get<bool>('/QuickConnect/Enabled');
      return response.data ?? false;
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  Future<QuickConnectState> initiateQuickConnect() async {
    final data = await postJson('/QuickConnect/Initiate');
    return QuickConnectState.fromJson(data);
  }

  Future<QuickConnectState> getQuickConnectState(String secret) async {
    final data = await getJson(
      '/QuickConnect/Connect',
      query: {'secret': secret},
    );
    return QuickConnectState.fromJson(data);
  }

  /// Exchanges an approved Quick Connect secret for an access token.
  /// Approves another device's Quick Connect [code], signing it in as the
  /// current user. Throws [JellyfinException] (404: no device is waiting
  /// with that code).
  Future<void> authorizeQuickConnect(String code) async {
    await postJson('/QuickConnect/Authorize', query: {'code': code.trim()});
  }

  Future<AuthResult> authenticateWithQuickConnect(String secret) async {
    final data = await postJson(
      '/Users/AuthenticateWithQuickConnect',
      body: {'Secret': secret},
    );
    final result = AuthResult.fromJson(data);
    _accessToken = result.accessToken;
    return result;
  }

  Future<JellyfinUser> getCurrentUser() async {
    final data = await getJson('/Users/Me');
    return JellyfinUser.fromJson(data);
  }

  /// Ends the session on the server and forgets the token locally.
  /// Ends this session on the server. False when the server couldn't be
  /// reached (any answer, even "that token is no longer valid", counts).
  Future<bool> logout() async {
    try {
      await _dio.post<void>('/Sessions/Logout');
      return true;
    } on DioException catch (e) {
      // Token may already be invalid; signing out locally is what matters.
      return e.response != null;
    } finally {
      _accessToken = null;
    }
  }

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: _clean(query),
      );
      return response.data ?? const {};
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  Future<List<dynamic>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final response = await _dio.get<List<dynamic>>(
        path,
        queryParameters: _clean(query),
      );
      return response.data ?? const [];
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// POSTs [body] as JSON. Returns the decoded object, or an empty map for
  /// endpoints that answer 204 No Content.
  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    try {
      final response = await _dio.post<Object?>(
        path,
        data: body,
        queryParameters: _clean(query),
      );
      final data = response.data;
      return data is Map<String, dynamic> ? data : const {};
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    try {
      await _dio.delete<void>(path, queryParameters: _clean(query));
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// Drops null values so optional filters can be passed inline.
  Map<String, dynamic>? _clean(Map<String, dynamic>? query) {
    if (query == null) return null;
    return {
      for (final e in query.entries)
        if (e.value != null) e.key: e.value,
    };
  }

  JellyfinException _wrap(DioException e) {
    final status = e.response?.statusCode;
    // TLS failures arrive as "unknown" (or connectionError) with the
    // HandshakeException inside.
    if (e.type == DioExceptionType.badCertificate ||
        e.error is HandshakeException ||
        e.error is TlsException ||
        '${e.error}'.contains('CERTIFICATE_VERIFY_FAILED')) {
      return const JellyfinException(
        'The server\'s HTTPS certificate isn\'t trusted on this device.',
        untrustedCertificate: true,
      );
    }
    final message = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        'The server took too long to respond.',
      DioExceptionType.connectionError =>
        unreachableReason(e) ?? 'Could not reach the server. Check the address and your network.',
      _ => switch (status) {
          401 => 'Wrong username or password, or your session has expired.',
          403 => 'You don\'t have permission to do that.',
          404 => 'Not found. Is this a Jellyfin server address?',
          _ => 'Request failed${status != null ? ' ($status)' : ''}.',
        },
    };
    return JellyfinException(message, statusCode: status);
  }
}
