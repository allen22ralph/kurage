import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

/// The app's MyAnimeList API client ID (myanimelist.net/apiconfig, app type
/// "other", redirect [MalAuth.redirectUri]). Public by design: PKCE, no
/// secret. Set with `--dart-define=MAL_CLIENT_ID=...` or in Settings.
const builtInMalClientId = String.fromEnvironment('MAL_CLIENT_ID');

/// Access and refresh tokens for the user's MyAnimeList account.
class MalTokens {
  const MalTokens({required this.accessToken, required this.refreshToken, required this.expiresAt});

  factory MalTokens.fromTokenResponse(Map<String, dynamic> json, DateTime now) => MalTokens(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        expiresAt: now.add(Duration(seconds: (json['expires_in'] as num).toInt())),
      );

  factory MalTokens.fromJson(Map<String, dynamic> json) => MalTokens(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
      );

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  /// Refresh a little early so a request never races the expiry.
  bool expiredAt(DateTime now) => now.isAfter(expiresAt.subtract(const Duration(minutes: 5)));

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt.toIso8601String(),
      };
}

class MalAuthException implements Exception {
  const MalAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// MyAnimeList OAuth 2.0 with PKCE. MAL only supports the "plain" method,
/// so the challenge is the verifier itself. The browser redirects to a
/// one-shot server on [redirectUri] on this device.
class MalAuth {
  MalAuth({required this.clientId, Dio? dio, DateTime Function()? now, Random? random})
      : _dio = dio ?? Dio(),
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  static const port = 53682;
  static final redirectUri = Uri.parse('http://localhost:$port/callback');
  static const _authorizeUrl = 'https://myanimelist.net/v1/oauth2/authorize';
  static const _tokenUrl = 'https://myanimelist.net/v1/oauth2/token';

  final String clientId;
  final Dio _dio;
  final DateTime Function() _now;
  final Random _random;

  /// 43–128 characters from the unreserved set, as PKCE requires.
  String newVerifier([int length = 96]) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return List.generate(length, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  Uri authorizeUri({required String verifier, required String state}) =>
      Uri.parse(_authorizeUrl).replace(queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'code_challenge': verifier,
        'code_challenge_method': 'plain',
        'state': state,
        'redirect_uri': redirectUri.toString(),
      });

  /// Runs the whole sign-in: listens on [redirectUri], has [openBrowser]
  /// show MAL's consent page, waits for the redirect, swaps the code for
  /// tokens. Times out after [timeout].
  Future<MalTokens> signIn(
    Future<void> Function(Uri url) openBrowser, {
    Duration timeout = const Duration(minutes: 5),
    int listenPort = port,
  }) async {
    final verifier = newVerifier();
    final state = newVerifier(24);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, listenPort);
    try {
      await openBrowser(authorizeUri(verifier: verifier, state: state));
      final code = await waitForCode(server, state).timeout(
        timeout,
        onTimeout: () => throw const MalAuthException('MyAnimeList sign-in timed out.'),
      );
      return await exchangeCode(code, verifier);
    } finally {
      await server.close(force: true);
    }
  }

  /// The authorization code from MAL's redirect to [server]. Ignores
  /// unrelated requests (favicon); fails if MAL reports an error or the
  /// state doesn't match (a forged redirect).
  static Future<String> waitForCode(HttpServer server, String state) async {
    await for (final request in server) {
      if (request.uri.path != redirectUri.path) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      final params = request.uri.queryParameters;
      final ok = params['state'] == state && params['code'] != null;
      request.response
        ..statusCode = ok ? HttpStatus.ok : HttpStatus.badRequest
        ..headers.contentType = ContentType.html
        ..write(ok
            ? '<h2>Linked to MyAnimeList.</h2><p>You can close this tab and return to the app.</p>'
            : '<h2>MyAnimeList sign-in failed.</h2><p>Please try again from the app.</p>');
      await request.response.close();
      if (params['error'] case final error?) {
        throw MalAuthException(error == 'access_denied' ? 'Sign-in was cancelled.' : 'MyAnimeList: $error');
      }
      if (!ok) throw const MalAuthException('MyAnimeList sign-in failed (bad state).');
      return params['code']!;
    }
    throw const MalAuthException('MyAnimeList sign-in was interrupted.');
  }

  Future<MalTokens> exchangeCode(String code, String verifier) => _token({
        'client_id': clientId,
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri.toString(),
        'code_verifier': verifier,
      });

  Future<MalTokens> refresh(MalTokens tokens) => _token({
        'client_id': clientId,
        'grant_type': 'refresh_token',
        'refresh_token': tokens.refreshToken,
      });

  Future<MalTokens> _token(Map<String, String> form) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        _tokenUrl,
        data: form,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return MalTokens.fromTokenResponse(r.data!, _now());
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      throw MalAuthException(status == 400 || status == 401
          ? 'MyAnimeList rejected the sign-in; link the account again.'
          : "Couldn't reach MyAnimeList.");
    }
  }

  static String encode(MalTokens t) => jsonEncode(t.toJson());
  static MalTokens decode(String s) => MalTokens.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
