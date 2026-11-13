import 'dart:io';

import 'package:dio/dio.dart';

/// Why a request to a server got no answer at all, for the user: the name
/// isn't known, the connection was refused, it timed out, or the
/// certificate isn't trusted. Null when the server did answer (an HTTP
/// status) or the cause isn't one of these.
String? unreachableReason(DioException e) {
  if (e.response != null) return null;
  final host = e.requestOptions.uri.host;
  final error = e.error;
  final text = '$error';
  if (e.type == DioExceptionType.badCertificate ||
      error is HandshakeException ||
      error is TlsException ||
      text.contains('CERTIFICATE_VERIFY_FAILED')) {
    return "$host's HTTPS certificate isn't trusted on this device.";
  }
  if (e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.sendTimeout) {
    return "$host didn't answer in time.";
  }
  if (error is SocketException || e.type == DioExceptionType.connectionError) {
    final code = error is SocketException ? error.osError?.errorCode : null;
    // Linux / Android: 7 = no address, -2 / -3 = name unknown; Windows 11001.
    if (text.contains('Failed host lookup') || code == 11001) {
      return "Can't find $host: this network doesn't know the name "
          '(away from home, or a VPN or Tailscale changing DNS?).';
    }
    // 111 (Linux / Android), 10061 (Windows).
    if (text.contains('Connection refused') || code == 111 || code == 10061) {
      return '$host refused the connection: nothing is answering on that port.';
    }
    if (text.contains('Network is unreachable') || code == 101 || code == 10051) {
      return 'No network connection.';
    }
  }
  return null;
}
