import 'package:dio/dio.dart';

import 'app_log.dart';

/// Logs each request to the app log: method, path, status and time taken.
/// Successes at debug level, failures as warnings with the server's reason.
/// Only the path is logged: no server address, no query (tokens, API keys).
class AppLogInterceptor extends Interceptor {
  AppLogInterceptor(this.area);

  final LogArea area;

  static const _started = 'appLog.started';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_started] = DateTime.now();
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final o = response.requestOptions;
    AppLog.debug(area, '${o.method} ${o.uri.path} → ${response.statusCode} (${_took(o)})');
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final o = err.requestOptions;
    final status = err.response?.statusCode;
    final what = status != null ? '$status' : _type(err.type);
    AppLog.add(
      area,
      LogLevel.warning,
      '${o.method} ${o.uri.path} → $what (${_took(o)})',
      details: _reason(err),
    );
    handler.next(err);
  }

  static String _took(RequestOptions o) {
    final started = o.extra[_started];
    return started is DateTime ? '${DateTime.now().difference(started).inMilliseconds} ms' : '?';
  }

  static String _type(DioExceptionType type) => switch (type) {
        DioExceptionType.connectionTimeout => 'connect timeout',
        DioExceptionType.receiveTimeout => 'receive timeout',
        DioExceptionType.sendTimeout => 'send timeout',
        DioExceptionType.connectionError => 'unreachable',
        DioExceptionType.badCertificate => 'untrusted certificate',
        DioExceptionType.cancel => 'cancelled',
        _ => 'failed',
      };

  /// What the server or the connection said, shortened.
  static String? _reason(DioException err) {
    final data = err.response?.data;
    final text = switch (data) {
      null => err.error?.toString() ?? err.message,
      final String s => s,
      final Map<dynamic, dynamic> m => (m['message'] ?? m['Message'] ?? m['title'] ?? m).toString(),
      _ => data.toString(),
    };
    if (text == null || text.trim().isEmpty) return null;
    final one = text.trim();
    return one.length > 300 ? '${one.substring(0, 300)}…' : one;
  }
}
