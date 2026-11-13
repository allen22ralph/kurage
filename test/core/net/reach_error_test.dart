import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/net/reach_error.dart';

void main() {
  final request = RequestOptions(path: 'https://seerr.home.arpa/api/v1/status');

  DioException failed(Object error, [DioExceptionType type = DioExceptionType.connectionError]) =>
      DioException(requestOptions: request, error: error, type: type);

  test('says why there was no answer', () {
    // As on the phone away from home (Android's errno 7).
    expect(
      unreachableReason(failed(const SocketException(
        "Failed host lookup: 'seerr.home.arpa'",
        osError: OSError('No address associated with hostname', 7),
      ))),
      allOf(startsWith("Can't find seerr.home.arpa"), contains('Tailscale')),
    );
    expect(
      unreachableReason(failed(const SocketException('Connection failed', osError: OSError('Connection refused', 111)))),
      'seerr.home.arpa refused the connection: nothing is answering on that port.',
    );
    expect(
      unreachableReason(failed('timeout', DioExceptionType.connectionTimeout)),
      "seerr.home.arpa didn't answer in time.",
    );
    expect(
      unreachableReason(failed(const HandshakeException('CERTIFICATE_VERIFY_FAILED'), DioExceptionType.unknown)),
      "seerr.home.arpa's HTTPS certificate isn't trusted on this device.",
    );
  });

  test('nothing to add when the server answered, or the cause is unknown', () {
    expect(
      unreachableReason(DioException(
        requestOptions: request,
        response: Response(requestOptions: request, statusCode: 500),
        type: DioExceptionType.badResponse,
      )),
      isNull,
    );
    expect(unreachableReason(failed('something else')), isNull);
  });
}
